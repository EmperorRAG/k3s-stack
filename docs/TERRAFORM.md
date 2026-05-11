# Terraform

Terraform owns the VM lifecycle on Proxmox. Ansible owns what runs inside the VMs. The handoff happens via cloud-init: Terraform creates a VM with cloud-init data (hostname, IP, SSH keys, base packages) and Ansible takes over once SSH is up.

This split is the standard "Terraform for infra, Ansible for config" pattern. Each tool does what it does best.

## The Proxmox template (one-time prep)

Terraform clones VMs from a Proxmox template. The template must be set up correctly or `terraform apply` will fail or produce broken VMs. Checklist:

1. **Base image:** Ubuntu Server 26.04 cloud image (the `noble-server-cloudimg-amd64.img` style image, not the desktop installer). The cloud image is what cloud-init expects.
2. **`cloud-init` package installed and enabled.** Usually already present in cloud images.
3. **`cloud-init` drive attached in Proxmox.** In the Proxmox UI: select the template → Hardware → Add → CloudInit Drive. Datastore: `local-lvm` or `local`, whichever the template uses.
4. **`qemu-guest-agent` installed.** Required for Terraform to read the VM's IP back. Either install in the template (`apt install -y qemu-guest-agent`) or let cloud-init install it on first boot — the repo's `cloud-init-user-data.yaml.tftpl` lists it under `packages`.
5. **VM Options → QEMU Guest Agent → Enabled.** Proxmox-side toggle.
6. **Network device:** virtio on `vmbr0`. The cloud-init network config assumes interface name `ens18`, which is what virtio gets.
7. **Convert to template:** right-click VM in Proxmox → "Convert to Template." After this, the VM ID becomes the `template_id` in `terraform.tfvars`.

## Layout

```
terraform/
├── versions.tf                       # provider version pins
├── providers.tf                      # provider config
├── variables.tf                      # variable type definitions
├── terraform.tfvars                  # actual values (committed)
├── main.tf                           # VM resources + cloud-init snippets
├── outputs.tf                        # vm_ips, vm_ids
└── cloud-init-user-data.yaml.tftpl   # per-VM cloud-init template
```

Two files capture all the per-VM information:

- **`terraform.tfvars`** — VM definitions (vmid, IP, memory, CPU, disk).
- **`ansible/inventory/hosts.yml`** — VM Ansible-side roles (server vs agent, init flag).

Adding or removing a VM means editing both. This is a real maintenance burden, but it's two files, not twenty, and the alternative (Terraform-as-the-source-of-truth-for-Ansible-too) costs more in tooling complexity than it saves.

## Day-two operations

### Adding a VM

1. Add an entry to the `vms` map in `terraform/terraform.tfvars`.
2. Add the host to the appropriate group in `ansible/inventory/hosts.yml` (`k3s_servers` or `k3s_agents`).
3. Run `./workstation/03-add-node.sh <hostname>`.

### Removing a VM

1. Remove the entry from `ansible/inventory/hosts.yml` so future plays skip it.
2. Drain and remove the node from k3s: `ssh mark@10.0.40.111 'sudo /usr/local/bin/k3s kubectl drain <hostname> --delete-emptydir-data --ignore-daemonsets --force'` then `kubectl delete node <hostname>`.
3. Remove the entry from `terraform/terraform.tfvars`.
4. `cd terraform && terraform apply` — Terraform destroys the VM.

### Resizing a VM

Edit the entry in `terraform.tfvars` (memory, cpu). `terraform apply` updates it in place. Disk grows non-destructively; disk shrinks are not supported by Terraform — destroy and recreate.

### Replacing the template

If the template is rebuilt (new VMID), update `template_id` in `terraform.tfvars`. The `lifecycle { ignore_changes = [clone] }` block on the VM resource prevents existing VMs from being recreated when the template changes — Terraform leaves them as they are. New VMs created after the change will clone from the new template.

If you *want* an existing VM to be recreated from the new template, taint it: `terraform -chdir=terraform taint 'proxmox_virtual_environment_vm.node["k3s-node-server-3021"]'`, then `terraform apply`.

## State

The repo uses **local state** (`terraform/terraform.tfstate`, gitignored). This is fine for a single operator on a single workstation, and consistent with the rest of the POC's "simple now, hardened later" posture.

When the time comes to move to multi-operator use, the state needs to live somewhere shared. Azure DevOps is the team's choice for git hosting, but the team's broader policy keeps infrastructure services (storage, databases, secret stores) on self-hosted infrastructure. That means state lives on the cluster itself or on a small dedicated VM, not on a commercial cloud storage service.

Three self-hosted options exist, in order of preference:

| Backend | Hosts where | Notes |
|---|---|---|
| **`pg` against in-cluster PostgreSQL** | A Postgres Pod on k3s | Strongest locking semantics (row-level locks via Postgres advisory locks). Postgres is the most likely shared service to appear on the cluster regardless — once it's there for any project app, it's the natural place for Terraform state. Recommended. |
| **`http` against a small state server** | A `terraform-state-server` Pod on k3s, or any HTTP-backend-compatible service | Simple, single-purpose service. Native locking. Choose this if a Postgres dependency feels too heavy for state alone. |
| **`s3` against in-cluster MinIO** | A MinIO Pod on k3s | Works if the team already wants S3-compatible object storage on-cluster for other reasons. Locking on the s3 backend requires a separate DynamoDB-compatible service or a tolerance for unlocked state — more moving parts than the alternatives. |

The migration to remote state is a single configuration block change in `versions.tf` plus one `terraform init -migrate-state` invocation. It does not require rewriting anything else. The choice between the three backends can be deferred until the migration is actually scheduled.

### Example: `pg` backend block

```hcl
terraform {
  backend "pg" {
    conn_str    = "postgres://terraform@postgres.k3s.lan/terraform_state?sslmode=verify-full"
    schema_name = "k3s_stack"
  }
}
```

The password is supplied at runtime via `PGPASSWORD`, set by `workstation/01-cluster-up.sh` from Ansible Vault — the same pattern already used for the Proxmox API token. State is encrypted at rest by whatever encryption Postgres is configured for; TLS in transit comes from the cluster's internal CA.

### Why not Azure Storage / Blob backend

The Azure DevOps repo hosting is the only commercial cloud service in scope. Storage, databases, KMS, and other infrastructure services remain self-hosted. The Terraform Azure backends (`azurerm` storage account, etc.) are not used.

## Secrets

Terraform never sees the Proxmox token in HCL. It reads it from the `PROXMOX_VE_API_TOKEN` environment variable, which `workstation/01-cluster-up.sh` exports from Ansible Vault before calling `terraform`. The token is unset immediately after Terraform exits.

There are no other secrets in `terraform/`.

## Drift detection

```bash
cd terraform
terraform plan
```

If anything has changed in Proxmox since the last apply (someone resized a VM through the UI, etc.), the plan output will show it. Re-apply to restore the declared state, or update the HCL to match reality if the change is intentional.

## Why bpg/proxmox over Telmate/proxmox

`bpg/proxmox` is the more actively developed of the two community providers. Its surface is broader (more resource types, better cloud-init integration), the docs are more complete, and it uses pure API for almost everything (no SSH-to-Proxmox-host needed). `Telmate/proxmox` is still maintained but has a smaller surface — fine for simple cases, not the right choice for a new project.
