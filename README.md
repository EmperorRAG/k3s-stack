# k3s Stack

A highly-available k3s cluster on Proxmox VE / Ubuntu Server 26.04, with kube-vip for the floating API endpoint, ingress-nginx + cert-manager + an internal CA for TLS, Rancher Manager for cluster governance, and Jenkins (in-cluster) for project-application CI/CD.

This repo *is* the runbook. The scripts under `workstation/` and `vm-bootstrap/` execute the procedure end-to-end. This document is the narrative.

---

## What you get

- **Three control-plane VMs** (`k3s-orchestrator`, `k3s-node-3001`, `k3s-node-3002`) running k3s with embedded etcd.
- **Floating API endpoint at `10.0.40.99`** owned by kube-vip; survives any single VM failure.
- **Internal DNS** at `k3s-api.k3s.lan`, `rancher.k3s.lan`, `jenkins.k3s.lan` via pfSense Unbound host overrides.
- **Internal CA** issuing real TLS certs to in-cluster services; browsers trust the cluster after a one-time CA import.
- **Rancher Manager** at `https://rancher.k3s.lan/` (3 replicas, survives single-node failure).
- **Jenkins** at `https://jenkins.k3s.lan/`, scoped to project-application CI/CD only.

The cluster survives the loss of any single VM (including `k3s-orchestrator`) with no operator action.

---

## Prerequisites

**Workstation:**
- Linux, macOS, or Windows with WSL2.
- `git`, `curl`, an SSH client.
- The repo cloned locally (you are reading the README inside it).
- A public SSH key to commit to `keys/authorized_keys` (see Section 2).

**Environment:**
- Proxmox VE host with an Ubuntu Server 26.04 template that:
  - Has a user `mark` with passwordless sudo.
  - Has cloud-init network management disabled.
  - Comes up with working DHCP, DNS, and `curl` + `ca-certificates` installed.
- pfSense gateway at `10.0.40.1` with **MSS clamping configured** for the OpenVPN WAN. (If MSS clamping isn't in place, TLS will hang silently. See `docs/MTU-NOTE.md`.)
- Three VMs cloned from the template:

| Hostname | VMID | IP |
|---|---|---|
| k3s-orchestrator | 3000 | 10.0.40.100 |
| k3s-node-3001 | 3001 | 10.0.40.101 |
| k3s-node-3002 | 3002 | 10.0.40.102 |

---

## Procedure

### 1. Install workstation tooling

```bash
./workstation/00-install-tools.sh
```

Installs Ansible, kubectl, and Helm on the workstation. Idempotent. Safe to re-run.

### 2. Add your SSH public key to the repo

Open `keys/authorized_keys`, append your public key on a new line, commit, push. This file ends up in `mark`'s `~/.ssh/authorized_keys` on every VM, so any committed key gets cluster-wide SSH access. Removing access = remove the line, push, re-run the bootstrap (or just the common playbook).

```bash
cat ~/.ssh/id_ed25519.pub >> keys/authorized_keys
git add keys/authorized_keys
git commit -m "Add operator SSH key"
git push
```

### 3. Set the Ansible Vault passphrase

Edit `.k3s-stack-vault-pass` and set whatever passphrase you like. **This file is committed to the repo on purpose** — the secrets it protects are still encrypted, the passphrase being in-repo is a deliberate convenience for the early POC phase. See `docs/SECRETS.md` for the migration plan to HashiCorp Vault.

### 4. Edit the secrets

```bash
ansible-vault edit ansible/secrets/vault.yml
```

Set real values for the Rancher and Jenkins admin passwords. Save and close — the file is re-encrypted on save.

### 5. Bring up the VMs (Proxmox console, ~30 seconds each)

For each of the three VMs, open the Proxmox console, log in as `mark`, and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/EmperorRAG/k3s-stack/main/vm-bootstrap/bootstrap.sh \
  | sudo bash -s -- <hostname> <ip>
```

Substitute `<hostname>` and `<ip>` per VM (when the repo moves to Azure DevOps, swap the URL — see `docs/REPO-HOSTING.md`):

```bash
# On VM 3000:
curl -fsSL https://raw.githubusercontent.com/EmperorRAG/k3s-stack/main/vm-bootstrap/bootstrap.sh \
  | sudo bash -s -- k3s-orchestrator 10.0.40.100

# On VM 3001:
curl -fsSL https://raw.githubusercontent.com/EmperorRAG/k3s-stack/main/vm-bootstrap/bootstrap.sh \
  | sudo bash -s -- k3s-node-3001 10.0.40.101

# On VM 3002:
curl -fsSL https://raw.githubusercontent.com/EmperorRAG/k3s-stack/main/vm-bootstrap/bootstrap.sh \
  | sudo bash -s -- k3s-node-3002 10.0.40.102
```

(For a private GitHub repo, append a personal access token: `https://<TOKEN>@raw.githubusercontent.com/...`. For Azure DevOps, swap the URL to the AzDO `?api-version=...&download=true` form; see `docs/REPO-HOSTING.md`.)

Each invocation configures the static IP, installs SSH and base packages, sets the hostname, and pulls the authorized keys from the repo. Total time per VM: well under a minute.

### 6. Configure pfSense DNS (web UI, one-time)

In pfSense: **Services → DNS Resolver → General Settings → Host Overrides → Add**. Add three entries, all pointing at `10.0.40.99`:

| Host | Domain |
|---|---|
| k3s-api | k3s.lan |
| rancher | k3s.lan |
| jenkins | k3s.lan |

### 7. Bring the cluster up

From the workstation:

```bash
./workstation/01-cluster-up.sh
```

This runs Ansible playbooks against all three VMs to:
- Install k3s in HA mode (3 servers with embedded etcd).
- Deploy kube-vip, ingress-nginx, cert-manager.
- Create the internal CA ClusterIssuer.
- Install Rancher Manager (3 replicas).
- Install Jenkins.

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
| Add a new node | Edit `ansible/inventory/hosts.yml`, then `./workstation/03-add-node.sh <hostname>` |
| Re-deploy after manifest changes | `./workstation/01-cluster-up.sh` |
| Edit secrets | `ansible-vault edit ansible/secrets/vault.yml` |
| Tear it all down | `./workstation/98-teardown.sh` |
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
│   ├── 00-install-tools.sh            # ansible, kubectl, helm
│   ├── 01-cluster-up.sh               # full cluster build
│   ├── 02-extract-ca.sh               # pulls internal CA cert
│   ├── 03-add-node.sh                 # adds a new node from inventory
│   ├── 04-status.sh                   # health check
│   ├── 97-rebuild.sh                  # teardown + cluster-up
│   ├── 98-teardown.sh                 # uninstalls k3s on every node
│   └── 99-failover-drill.sh           # guided failover test
├── vm-bootstrap/
│   └── bootstrap.sh                   # the curl-and-pipe-bash target
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
│   ├── rancher-values.yaml.j2         # Jinja template (uses vault vars)
│   └── jenkins-values.yaml.j2
├── keys/
│   └── authorized_keys                # operator SSH pubkeys
└── docs/
    ├── ARCHITECTURE.md                # HA topology, design rationale
    ├── SECRETS.md                     # Ansible Vault now, HashiCorp Vault later
    ├── CA-TRUST.md                    # importing the internal CA into trust stores
    ├── REPO-HOSTING.md                # GitHub → Azure DevOps migration
    ├── MTU-NOTE.md                    # the pfSense MSS clamping prerequisite
    └── TROUBLESHOOTING.md
```
