# k3s Stack

A highly-available k3s cluster on Proxmox VE / Ubuntu Server 26.04, with kube-vip for the floating API endpoint, ingress-nginx + cert-manager + an internal CA for TLS, Rancher Manager for cluster governance, and Jenkins (in-cluster) for project-application CI/CD.

This repo *is* the runbook. The scripts under `workstation/` and the HCL under `terraform/` execute the procedure end-to-end. This document is the narrative.

---

## What you get

- **Three control-plane VMs** (`k3s-node-server-3011`, `k3s-node-server-3021`, `k3s-node-server-3031`) running k3s with embedded etcd, provisioned by Terraform from a Proxmox template. Naming follows a rack/slot scheme — see `docs/ARCHITECTURE.md`.
- **Floating API endpoint at `10.0.40.100`** owned by kube-vip; survives any single VM failure.
- **Internal DNS** at `k3s-api.k3s.lan`, `rancher.k3s.lan`, `jenkins.k3s.lan` via pfSense Unbound host overrides.
- **Internal CA** issuing real TLS certs to in-cluster services; browsers trust the cluster after a one-time CA import.
- **Rancher Manager** at `https://rancher.k3s.lan/` (3 replicas, survives single-node failure).
- **Jenkins** at `https://jenkins.k3s.lan/`, scoped to project-application CI/CD only.

The cluster survives the loss of any single VM with no operator action.

---

## Prerequisites

**Workstation:**
- Linux, macOS, or Windows with WSL2.
- `git`, `curl`, an SSH client.
- The repo cloned locally (you are reading the README inside it).
- A public SSH key to commit to `keys/authorized_keys` (see step 2 below).

**Environment:**
- Proxmox VE host with an Ubuntu Server 26.04 **cloud-init-ready** template:
  - `cloud-init` package installed.
  - `cloud-init` drive attached to the template (Proxmox UI: VM → Hardware → Add → CloudInit Drive).
  - `qemu-guest-agent` installed.
  - Network device: virtio on `vmbr0`.
  - User `mark` with passwordless sudo (the cloud-init image creates this automatically).
  - See `docs/TERRAFORM.md` for a full template-prep checklist.
- A Proxmox API token (created in the Proxmox UI; see step 3 below).
- pfSense gateway at `10.0.40.1` with **MSS clamping configured** for the OpenVPN WAN. See `docs/MTU-NOTE.md`.

---

## Procedure

### 1. Install workstation tooling

```bash
./workstation/00-install-tools.sh
```

Installs Ansible, kubectl, Helm, and Terraform on the workstation. Idempotent. Safe to re-run.

### 2. Add your SSH public key to the repo

Append your public key to `keys/authorized_keys`, commit, push. Terraform reads this file at apply time and bakes the keys into each VM via cloud-init. Adding a key after a VM exists requires re-applying or recreating the VM.

```bash
cat ~/.ssh/id_ed25519.pub >> keys/authorized_keys
git add keys/authorized_keys
git commit -m "Add operator SSH key"
git push
```

### 3. Create a Proxmox API token

In the Proxmox UI: **Datacenter → Permissions → API Tokens → Add**. Suggested values:

- User: `terraform@pve` (create the user first under **Permissions → Users** if it doesn't exist).
- Token ID: `k3s-stack`.
- Privilege Separation: leave **checked** (more secure).

After saving, Proxmox displays the token secret **once** — copy it immediately.

Grant the token the necessary permissions (**Datacenter → Permissions → Add → API Token Permission**):

- Path: `/`
- API Token: the one you just created
- Role: `PVEVMAdmin` (sufficient for creating, modifying, and destroying VMs)

### 4. Set the Ansible Vault passphrase and secrets

Edit `.k3s-stack-vault-pass` and set whatever passphrase you like. **This file is committed to the repo on purpose** — see `docs/SECRETS.md` for the rationale and the migration plan to HashiCorp Vault.

Then edit the vault to set the real values:

```bash
ansible-vault edit ansible/secrets/vault.yml
```

Set:
- `rancher_bootstrap_password` — initial Rancher admin password.
- `jenkins_admin_password` — initial Jenkins admin password.
- `proxmox_api_token_id` — e.g. `terraform@pve!k3s-stack`.
- `proxmox_api_token_secret` — the UUID Proxmox showed you in step 3.

### 5. Configure Terraform for your environment

Edit `terraform/terraform.tfvars`:

- `proxmox_endpoint` — your Proxmox API URL, e.g. `https://10.0.40.5:8006/`.
- `proxmox_node` — the Proxmox node name (the hypervisor host), e.g. `pve`.
- `template_id` — VMID of your cloud-init-ready Ubuntu Server 26.04 template.
- `template_node` — Proxmox node the template lives on.

The `vms` map already contains the three initial cluster members. To add or change VMs, edit this map; see `docs/TERRAFORM.md`.

### 6. Configure pfSense DNS (web UI, one-time)

In pfSense: **Services → DNS Resolver → General Settings → Host Overrides → Add**. Add three entries, all pointing at `10.0.40.100`:

| Host | Domain |
|---|---|
| k3s-api | k3s.lan |
| rancher | k3s.lan |
| jenkins | k3s.lan |

### 7. Bring the cluster up

```bash
./workstation/01-cluster-up.sh
```

This:
1. Decrypts the Proxmox token from Ansible Vault.
2. Runs `terraform apply` to clone the three VMs from the template, with cloud-init configuring the hostname, static IP, SSH keys, and base packages.
3. Waits for SSH on every VM.
4. Runs Ansible playbooks to install k3s in HA mode (3 servers with embedded etcd), deploy kube-vip, ingress-nginx, cert-manager, the internal CA, Rancher Manager, and Jenkins.

End-to-end takes ~15-20 minutes depending on image-pull speed. Idempotent — re-runnable.

### 8. Extract the internal CA cert

```bash
./workstation/02-extract-ca.sh
```

Pulls the cluster's internal CA certificate to `./cluster-internal-ca.crt`. Distribute this to operators' workstations and import it into their OS / browser trust stores (see `docs/CA-TRUST.md`).

### 9. Verify

Open `https://rancher.k3s.lan/` and `https://jenkins.k3s.lan/` in a browser. Both should load with valid TLS certificates (once the CA is in the trust store) and show login pages.

Run the failover drill:

```bash
./workstation/99-failover-drill.sh
```

This walks you through stopping a VM, verifying cluster survival, and bringing it back.

---

## Day-two operations

| Task | Command |
|---|---|
| Add a new node | Edit `terraform/terraform.tfvars` and `ansible/inventory/hosts.yml`, then `./workstation/03-add-node.sh <hostname>` |
| Re-deploy after manifest changes | `./workstation/01-cluster-up.sh` |
| Edit secrets | `ansible-vault edit ansible/secrets/vault.yml` |
| Tear down (uninstall k3s + destroy VMs) | `./workstation/98-teardown.sh` |
| Tear down k3s only, keep VMs | `./workstation/98-teardown.sh --keep-vms` |
| Rebuild from scratch | `./workstation/97-rebuild.sh` |
| Check cluster health | `./workstation/04-status.sh` |

---

## Repo layout

```
k3s-stack/
├── README.md                          # this file
├── .k3s-stack-vault-pass              # Ansible Vault passphrase (committed; see docs/SECRETS.md)
├── .gitignore
├── workstation/
│   ├── 00-install-tools.sh            # ansible, kubectl, helm, terraform
│   ├── 00b-install-terraform.sh       # terraform only (called by 00)
│   ├── 01-cluster-up.sh               # full cluster build (terraform + ansible)
│   ├── 02-extract-ca.sh               # pulls internal CA cert
│   ├── 03-add-node.sh                 # adds a new node
│   ├── 04-status.sh                   # health check
│   ├── 97-rebuild.sh                  # teardown + cluster-up
│   ├── 98-teardown.sh                 # uninstalls k3s, destroys VMs (--keep-vms to skip the destroy)
│   └── 99-failover-drill.sh           # guided failover test
├── terraform/
│   ├── versions.tf                    # provider versions
│   ├── providers.tf                   # provider config
│   ├── variables.tf                   # variable definitions
│   ├── terraform.tfvars               # values (VM definitions, endpoint, etc.) — COMMITTED
│   ├── main.tf                        # VM resources + cloud-init snippets
│   ├── outputs.tf                     # VM IPs and IDs
│   └── cloud-init-user-data.yaml.tftpl  # per-VM cloud-init template
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.yml
│   ├── playbooks/
│   │   ├── 01-common.yml              # base config
│   │   ├── 02-k3s-init.yml            # cluster-init on orchestrator
│   │   ├── 03-k3s-join-servers.yml    # joins the other two
│   │   ├── 04-cluster-workloads.yml   # ingress, cert-manager, CA, Rancher, Jenkins
│   │   ├── 05-k3s-join-agent.yml      # for future pure workers
│   │   └── 99-k3s-uninstall.yml       # tear-down
│   └── secrets/
│       └── vault.yml                  # encrypted; ansible-vault edit
├── manifests/
│   ├── kube-vip.yaml
│   ├── cluster-ca.yaml
│   └── jenkins-tls.yaml
├── helm-values/
│   ├── ingress-nginx-values.yaml
│   ├── rancher-values.yaml.j2
│   └── jenkins-values.yaml.j2
├── keys/
│   └── authorized_keys                # operator SSH pubkeys
└── docs/
    ├── ARCHITECTURE.md                # HA topology, design rationale
    ├── TERRAFORM.md                   # template prep, state backend, day-two HCL ops
    ├── SECRETS.md                     # Ansible Vault now, HashiCorp Vault later
    ├── CA-TRUST.md                    # importing the internal CA into trust stores
    ├── REPO-HOSTING.md                # GitHub → Azure DevOps migration
    ├── MTU-NOTE.md                    # the pfSense MSS clamping prerequisite
    └── TROUBLESHOOTING.md
```
