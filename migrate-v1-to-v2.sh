#!/usr/bin/env bash
#
# Migrate the k3s-stack repo from v1 (curl-bootstrap) to v2 (Terraform + cloud-init).
#
# Run from the repo root in a clean working tree (commit or stash any in-progress
# changes first; this script writes lots of files). The script:
#
#   - Creates terraform/ with the Proxmox VM definitions and cloud-init template.
#   - Adds workstation/00b-install-terraform.sh.
#   - Rewrites workstation/00-install-tools.sh, 01-cluster-up.sh, 97-rebuild.sh,
#     and 98-teardown.sh to use Terraform.
#   - Replaces vm-bootstrap/bootstrap.sh with a stub that points at cloud-init,
#     then removes the vm-bootstrap/ directory.
#   - Rewrites README.md and docs/ARCHITECTURE.md to reflect the new procedure.
#   - Adds docs/TERRAFORM.md.
#   - Updates docs/SECRETS.md and docs/REPO-HOSTING.md.
#   - Re-encrypts ansible/secrets/vault.yml with new Proxmox API token keys
#     added (preserving the existing values).
#   - Updates .gitignore.
#
# After running, review with `git diff`, then commit.

set -euo pipefail

# ---------- safety checks ----------

if [[ ! -f README.md || ! -d ansible || ! -d workstation ]]; then
  echo "ERROR: run this from the k3s-stack repo root."
  echo "Expected README.md, ansible/, workstation/ in the current directory."
  exit 1
fi

if [[ -d .git ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree has uncommitted changes."
    echo "Commit or stash them before running this migration, so the diff is reviewable."
    exit 1
  fi
fi

if ! command -v ansible-vault >/dev/null 2>&1; then
  echo "ERROR: ansible-vault not found. Run ./workstation/00-install-tools.sh first."
  exit 1
fi

if [[ ! -f .k3s-stack-vault-pass ]]; then
  echo "ERROR: .k3s-stack-vault-pass is missing. The vault step needs it."
  exit 1
fi

echo "[migrate] Pre-flight passed. Beginning migration."
echo

# ==================================================================
# 1. terraform/
# ==================================================================

echo "[migrate] Creating terraform/ directory and files"
mkdir -p terraform

cat > terraform/versions.tf <<'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }

  # Local state is fine for the POC phase. When moving to multi-operator use
  # or production, migrate to an Azure Storage backend — see docs/TERRAFORM.md.
}
EOF

cat > terraform/providers.tf <<'EOF'
# The Proxmox API token is supplied via the PROXMOX_VE_API_TOKEN environment
# variable, which workstation/01-cluster-up.sh exports from Ansible Vault before
# calling Terraform. This keeps the token out of HCL and out of `terraform show`.
#
# Format: PROXMOX_VE_API_TOKEN="<token-id>=<token-secret>"
# Example: PROXMOX_VE_API_TOKEN="terraform@pve!k3s-stack=00000000-0000-0000-0000-000000000000"

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = var.proxmox_insecure
}
EOF

cat > terraform/variables.tf <<'EOF'
variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint URL"
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS verification on the Proxmox API. True is acceptable for an internal cluster using a self-signed cert."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node name (the hypervisor host) to provision VMs on"
  type        = string
}

variable "template_id" {
  description = "VMID of the Ubuntu Server 26.04 template to clone from"
  type        = number
}

variable "template_node" {
  description = "Proxmox node the template lives on (usually the same as proxmox_node)"
  type        = string
}

variable "vms" {
  description = "VM definitions. Keys are hostnames; values define VMID, IP, role, resources."
  type = map(object({
    vmid     = number
    ip       = string                # e.g. "10.0.40.100/24"
    gateway  = string                # e.g. "10.0.40.1"
    memory   = number                # MiB
    cpu      = number                # vCPU count
    disk_gb  = number                # primary disk size in GiB
  }))
}

variable "ssh_authorized_keys_file" {
  description = "Path (relative to this directory) to the file containing operator SSH public keys"
  type        = string
  default     = "../keys/authorized_keys"
}

variable "vm_user" {
  description = "Cloud-init user account name on each VM"
  type        = string
  default     = "mark"
}
EOF

cat > terraform/main.tf <<'EOF'
# Read operator SSH public keys from the in-repo keys file. The bootstrap.sh
# fetched this at runtime; we now bake it in at VM creation time via cloud-init.
locals {
  ssh_keys = [
    for line in split("\n", file(var.ssh_authorized_keys_file)) :
    line if length(trimspace(line)) > 0 && !startswith(trimspace(line), "#")
  ]
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.vms

  name        = each.key
  vm_id       = each.value.vmid
  node_name   = var.proxmox_node
  description = "k3s-stack node: ${each.key}. Managed by Terraform."
  tags        = ["k3s-stack", "terraform"]

  # Clone from the Ubuntu Server 26.04 template.
  clone {
    vm_id     = var.template_id
    node_name = var.template_node
    full      = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cpu
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk_gb
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # Cloud-init: structured fields here; arbitrary YAML in the user_data_file.
  initialization {
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = each.value.gateway
      }
    }

    dns {
      servers = ["10.0.40.1"]
    }

    user_account {
      username = var.vm_user
      keys     = local.ssh_keys
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data[each.key].id
  }

  operating_system {
    type = "l26"   # Linux 2.6+ (covers 5.x and 6.x kernels)
  }

  lifecycle {
    # Re-cloning the disk every time the template is rebuilt is rarely what we
    # want. Once the VM exists, treat the disk as durable.
    ignore_changes = [
      clone,
    ]
  }
}

# Per-VM cloud-init user-data snippet. Sets hostname, installs base packages,
# enables SSH. Replaces what vm-bootstrap/bootstrap.sh did in v1.
resource "proxmox_virtual_environment_file" "cloud_init_user_data" {
  for_each = var.vms

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    file_name = "${each.key}-user-data.yaml"
    data = templatefile("${path.module}/cloud-init-user-data.yaml.tftpl", {
      hostname = each.key
    })
  }
}
EOF

cat > terraform/outputs.tf <<'EOF'
output "vm_ips" {
  description = "Map of hostname to IPv4 address for each provisioned VM"
  value = {
    for name, vm in var.vms : name => split("/", vm.ip)[0]
  }
}

output "vm_ids" {
  description = "Map of hostname to Proxmox VMID"
  value = {
    for name, vm in var.vms : name => vm.vmid
  }
}
EOF

cat > terraform/terraform.tfvars <<'EOF'
# Proxmox endpoint and node. Adjust to your environment.
proxmox_endpoint = "https://proxmox.k3s.lan:8006/"
proxmox_node     = "pve"

# Template the VMs are cloned from. Must be configured with:
#   - cloud-init drive attached
#   - qemu-guest-agent installed and enabled
#   - virtio network device on vmbr0
# See docs/TERRAFORM.md for the template prep checklist.
template_id   = 9000
template_node = "pve"

vms = {
  "k3s-orchestrator" = {
    vmid    = 3000
    ip      = "10.0.40.100/24"
    gateway = "10.0.40.1"
    memory  = 4096
    cpu     = 2
    disk_gb = 40
  }
  "k3s-node-3001" = {
    vmid    = 3001
    ip      = "10.0.40.101/24"
    gateway = "10.0.40.1"
    memory  = 4096
    cpu     = 2
    disk_gb = 40
  }
  "k3s-node-3002" = {
    vmid    = 3002
    ip      = "10.0.40.102/24"
    gateway = "10.0.40.1"
    memory  = 4096
    cpu     = 2
    disk_gb = 40
  }
}
EOF

cat > terraform/cloud-init-user-data.yaml.tftpl <<'EOF'
#cloud-config
# Cloud-init user-data for k3s-stack VMs. Rendered per-VM by Terraform.
# Hostname, IP, DNS, and SSH keys are set by the bpg/proxmox provider's
# initialization{} block — this file handles only what doesn't fit there.

hostname: ${hostname}
fqdn: ${hostname}
preserve_hostname: false

package_update: true
package_upgrade: false   # done idempotently by Ansible's 01-common.yml later

packages:
  - openssh-server
  - wget
  - ca-certificates
  - curl
  - qemu-guest-agent

runcmd:
  - systemctl enable --now ssh
  - systemctl enable --now qemu-guest-agent
  # Ensure /etc/hosts has a sensible 127.0.1.1 entry so sudo doesn't complain.
  - |
    if ! grep -qE "^127\.0\.1\.1\s+${hostname}" /etc/hosts; then
      echo "127.0.1.1 ${hostname}" >> /etc/hosts
    fi

# Signal completion so `cloud-init status --wait` returns cleanly.
final_message: "k3s-stack cloud-init complete after $UPTIME seconds"
EOF

# ==================================================================
# 2. .gitignore additions
# ==================================================================

echo "[migrate] Updating .gitignore"

# Append Terraform-related ignores if not already present.
if ! grep -q "^terraform/\.terraform/$" .gitignore 2>/dev/null; then
  cat >> .gitignore <<'EOF'

# Terraform
terraform/.terraform/
terraform/.terraform.lock.hcl.bak
terraform/*.tfstate
terraform/*.tfstate.*
terraform/crash.log
terraform/crash.*.log
# NOTE: terraform.tfvars IS committed (VM definitions are not secret).
# NOTE: terraform/.terraform.lock.hcl IS committed (provider version lock).
EOF
fi

# ==================================================================
# 3. workstation scripts
# ==================================================================

echo "[migrate] Adding workstation/00b-install-terraform.sh"
cat > workstation/00b-install-terraform.sh <<'EOF'
#!/usr/bin/env bash
#
# Install Terraform on the operator workstation. Called by 00-install-tools.sh.
# Idempotent.

set -euo pipefail

if command -v terraform >/dev/null 2>&1; then
  echo "[install-terraform] terraform already present: $(terraform version | head -1)"
  exit 0
fi

OS="$(uname -s)"
case "$OS" in
  Linux*)
    if command -v apt-get >/dev/null 2>&1; then
      echo "[install-terraform] Installing via HashiCorp apt repo"
      sudo apt-get update -qq
      sudo apt-get install -y -qq gnupg software-properties-common
      wget -O- https://apt.releases.hashicorp.com/gpg | \
        gpg --dearmor | \
        sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
        https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
      sudo apt-get update -qq
      sudo apt-get install -y terraform
    elif command -v dnf >/dev/null 2>&1; then
      echo "[install-terraform] Installing via HashiCorp dnf repo"
      sudo dnf install -y dnf-plugins-core
      sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
      sudo dnf install -y terraform
    else
      echo "ERROR: Unsupported Linux distro (need apt or dnf)."
      exit 1
    fi
    ;;
  Darwin*)
    echo "[install-terraform] Installing via Homebrew"
    brew tap hashicorp/tap
    brew install hashicorp/tap/terraform
    ;;
  *)
    echo "ERROR: Unsupported OS: $OS. Use Linux, macOS, or WSL2."
    exit 1
    ;;
esac

terraform version | head -1
EOF
chmod +x workstation/00b-install-terraform.sh

echo "[migrate] Rewriting workstation/00-install-tools.sh"
cat > workstation/00-install-tools.sh <<'EOF'
#!/usr/bin/env bash
#
# Install all workstation tooling: Ansible, kubectl, Helm, Terraform.
# Linux/macOS only. Windows users should run this inside WSL2.
# Idempotent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- detect platform ----------

OS="$(uname -s)"
case "$OS" in
  Linux*)
    if command -v apt-get >/dev/null 2>&1; then
      PKG="apt"
    elif command -v dnf >/dev/null 2>&1; then
      PKG="dnf"
    else
      echo "ERROR: Unsupported Linux distro (need apt or dnf)."
      exit 1
    fi
    ;;
  Darwin*)
    if ! command -v brew >/dev/null 2>&1; then
      echo "ERROR: macOS requires Homebrew. Install from https://brew.sh"
      exit 1
    fi
    PKG="brew"
    ;;
  *)
    echo "ERROR: Unsupported OS: $OS. Use Linux, macOS, or WSL2."
    exit 1
    ;;
esac

echo "[install] Platform: $OS / $PKG"

# ---------- install ansible ----------

install_ansible() {
  if command -v ansible >/dev/null 2>&1; then
    echo "[install] ansible already present: $(ansible --version | head -1)"
    return
  fi
  echo "[install] Installing ansible"
  case "$PKG" in
    apt)  sudo apt-get update -qq && sudo apt-get install -y ansible python3-kubernetes ;;
    dnf)  sudo dnf install -y ansible python3-kubernetes ;;
    brew) brew install ansible ;;
  esac
}

# ---------- install kubectl ----------

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    echo "[install] kubectl already present: $(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1)"
    return
  fi
  echo "[install] Installing kubectl"
  case "$PKG" in
    apt|dnf)
      KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
      curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
      sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
      rm kubectl
      ;;
    brew)
      brew install kubectl
      ;;
  esac
}

# ---------- install helm ----------

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    echo "[install] helm already present: $(helm version --short)"
    return
  fi
  echo "[install] Installing helm"
  case "$PKG" in
    apt|dnf)
      curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      ;;
    brew)
      brew install helm
      ;;
  esac
}

# ---------- install ansible collections ----------

install_ansible_collections() {
  echo "[install] Installing Ansible collections"
  ansible-galaxy collection install --upgrade \
    community.general \
    ansible.posix \
    kubernetes.core
}

# ---------- run ----------

install_ansible
install_kubectl
install_helm
install_ansible_collections

# Terraform is installed by a sibling script so its install logic stays self-contained.
"$REPO_ROOT/workstation/00b-install-terraform.sh"

echo
echo "[install] Done."
echo "[install] Versions:"
ansible --version | head -1
kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1 || kubectl version --client 2>&1 | head -1
helm version --short
terraform version | head -1
EOF
chmod +x workstation/00-install-tools.sh

echo "[migrate] Rewriting workstation/01-cluster-up.sh"
cat > workstation/01-cluster-up.sh <<'EOF'
#!/usr/bin/env bash
#
# Bring the k3s HA cluster up end-to-end from the operator workstation.
#
# Steps:
#   1. Decrypt the Proxmox API token from Ansible Vault and export to env.
#   2. Run `terraform apply` to provision the VMs (no-op if they already exist).
#   3. Wait for SSH on every VM.
#   4. Run the existing Ansible playbooks against them.
#
# Idempotent — re-running on a healthy cluster is a no-op.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------- Step 1: Proxmox API token from vault ----------

echo "[cluster-up] Step 1/5: Decrypt Proxmox API token from Ansible Vault"

# Extract the two keys we need without writing a plaintext file to disk.
PROXMOX_TOKEN_ID=$(ansible-vault view ansible/secrets/vault.yml \
  --vault-password-file .k3s-stack-vault-pass \
  | grep -E '^proxmox_api_token_id:' | awk -F: '{print $2}' | tr -d ' "')
PROXMOX_TOKEN_SECRET=$(ansible-vault view ansible/secrets/vault.yml \
  --vault-password-file .k3s-stack-vault-pass \
  | grep -E '^proxmox_api_token_secret:' | awk -F: '{print $2}' | tr -d ' "')

if [[ -z "$PROXMOX_TOKEN_ID" || -z "$PROXMOX_TOKEN_SECRET" ]]; then
  echo "ERROR: proxmox_api_token_id / proxmox_api_token_secret missing from ansible/secrets/vault.yml"
  echo "Run: ansible-vault edit ansible/secrets/vault.yml"
  exit 1
fi

export PROXMOX_VE_API_TOKEN="${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"

# ---------- Step 2: terraform apply ----------

echo
echo "[cluster-up] Step 2/5: Provision VMs with Terraform"

cd "$REPO_ROOT/terraform"
if [[ ! -d .terraform ]]; then
  terraform init
fi
terraform apply -auto-approve
cd "$REPO_ROOT"

# Unset the token now that Terraform is done.
unset PROXMOX_VE_API_TOKEN

# ---------- Step 3: wait for SSH ----------

echo
echo "[cluster-up] Step 3/5: Wait for SSH to come up on every VM"

# Extract the IP list from Terraform outputs.
mapfile -t VM_IPS < <(cd "$REPO_ROOT/terraform" && terraform output -json vm_ips | python3 -c 'import json,sys; [print(v) for v in json.load(sys.stdin).values()]')

for ip in "${VM_IPS[@]}"; do
  echo -n "  waiting for $ip... "
  for i in {1..60}; do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 \
        "mark@$ip" 'true' 2>/dev/null; then
      echo "ready"
      break
    fi
    sleep 3
    if [[ $i -eq 60 ]]; then
      echo "FAILED"
      echo "ERROR: $ip never accepted SSH after 3 minutes. Check Proxmox console."
      exit 1
    fi
  done
done

# ---------- Step 4 & 5: Ansible ----------

echo
echo "[cluster-up] Step 4/5: Common base configuration + k3s install"
cd "$REPO_ROOT/ansible"
ansible-playbook playbooks/01-common.yml
ansible-playbook playbooks/02-k3s-init.yml
ansible-playbook playbooks/03-k3s-join-servers.yml

echo
echo "[cluster-up] Step 5/5: Install cluster workloads (ingress, cert-manager, CA, Rancher, Jenkins)"
ansible-playbook playbooks/04-cluster-workloads.yml

echo
echo "[cluster-up] Done."
echo "[cluster-up] Next steps:"
echo "  - Extract the CA cert:  ./workstation/02-extract-ca.sh"
echo "  - Check status:         ./workstation/04-status.sh"
echo "  - Run failover drill:   ./workstation/99-failover-drill.sh"
EOF
chmod +x workstation/01-cluster-up.sh

echo "[migrate] Rewriting workstation/98-teardown.sh"
cat > workstation/98-teardown.sh <<'EOF'
#!/usr/bin/env bash
#
# Tear the k3s stack down completely. Two flavours:
#
#   --keep-vms   Uninstalls k3s but leaves the VMs running and reachable.
#                Useful for clean-slate cluster experiments.
#   (default)    Uninstalls k3s AND destroys the VMs via Terraform.
#                Returns the environment to "no cluster, no VMs."
#
# Use 97-rebuild.sh to teardown-then-build in one shot.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

KEEP_VMS=false
if [[ "${1:-}" == "--keep-vms" ]]; then
  KEEP_VMS=true
fi

if $KEEP_VMS; then
  cat <<'BANNER'

  ============================== WARNING ==============================
  This will run k3s-uninstall.sh on every node, deleting ALL Kubernetes
  state, etcd data, and any persistent volumes backed by local-path
  storage.

  The VMs themselves keep running.
  =====================================================================

BANNER
else
  cat <<'BANNER'

  ============================== WARNING ==============================
  This will:
    1. Uninstall k3s from every node (deletes ALL Kubernetes state).
    2. Destroy the VMs themselves via Terraform.

  After this, there is no cluster and no VMs. To rebuild, run
  ./workstation/97-rebuild.sh or ./workstation/01-cluster-up.sh.
  =====================================================================

BANNER
fi

read -r -p "Type 'destroy' to proceed: " CONFIRM
if [[ "$CONFIRM" != "destroy" ]]; then
  echo "Aborted."
  exit 1
fi

# Step 1: k3s-uninstall on each node, while they're still reachable.
echo "[teardown] Uninstalling k3s from all nodes"
cd "$REPO_ROOT/ansible"
ansible-playbook playbooks/99-k3s-uninstall.yml || \
  echo "[teardown] (some hosts may already be down; continuing)"
cd "$REPO_ROOT"

if $KEEP_VMS; then
  echo
  echo "[teardown] Done. k3s removed; VMs still reachable over SSH."
  exit 0
fi

# Step 2: terraform destroy.
echo
echo "[teardown] Destroying VMs with Terraform"

PROXMOX_TOKEN_ID=$(ansible-vault view ansible/secrets/vault.yml \
  --vault-password-file .k3s-stack-vault-pass \
  | grep -E '^proxmox_api_token_id:' | awk -F: '{print $2}' | tr -d ' "')
PROXMOX_TOKEN_SECRET=$(ansible-vault view ansible/secrets/vault.yml \
  --vault-password-file .k3s-stack-vault-pass \
  | grep -E '^proxmox_api_token_secret:' | awk -F: '{print $2}' | tr -d ' "')
export PROXMOX_VE_API_TOKEN="${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"

cd "$REPO_ROOT/terraform"
terraform destroy -auto-approve
cd "$REPO_ROOT"

unset PROXMOX_VE_API_TOKEN

echo
echo "[teardown] Done. Cluster and VMs are gone."
EOF
chmod +x workstation/98-teardown.sh

echo "[migrate] Rewriting workstation/97-rebuild.sh"
cat > workstation/97-rebuild.sh <<'EOF'
#!/usr/bin/env bash
#
# Rebuild the cluster from scratch. Tears everything down (including the VMs)
# then runs a clean build.
#
# Equivalent to:
#   ./workstation/98-teardown.sh
#   ./workstation/01-cluster-up.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$REPO_ROOT/workstation/98-teardown.sh"
echo
echo "[rebuild] Teardown complete. Building fresh cluster..."
echo
"$REPO_ROOT/workstation/01-cluster-up.sh"
EOF
chmod +x workstation/97-rebuild.sh

# ==================================================================
# 4. workstation/03-add-node.sh
# ==================================================================

echo "[migrate] Rewriting workstation/03-add-node.sh"
cat > workstation/03-add-node.sh <<'EOF'
#!/usr/bin/env bash
#
# Add a new node to the cluster.
#
# Prerequisites:
#   1. The new VM is defined in terraform/terraform.tfvars under `vms`.
#   2. The new host is in ansible/inventory/hosts.yml under either
#      k3s_servers.hosts (additional control-plane peer) or
#      k3s_agents.hosts  (pure worker).
#
# Usage:
#   ./workstation/03-add-node.sh k3s-node-3003

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <hostname>"
  echo "Example: $0 k3s-node-3003"
  exit 1
fi

NEW_HOST="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Sanity check inventory.
if ! (cd ansible && ansible-inventory --list 2>/dev/null | grep -q "\"$NEW_HOST\""); then
  echo "ERROR: $NEW_HOST is not in ansible/inventory/hosts.yml"
  echo "Add it under k3s_servers.hosts or k3s_agents.hosts, then re-run."
  exit 1
fi

# Determine role.
ROLE=$(cd ansible && ansible-inventory --list 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
if '$NEW_HOST' in data.get('k3s_servers', {}).get('hosts', []):
    print('server')
elif '$NEW_HOST' in data.get('k3s_agents', {}).get('hosts', []):
    print('agent')
")

if [[ -z "$ROLE" ]]; then
  echo "ERROR: could not determine role (server vs agent) for $NEW_HOST from the inventory."
  exit 1
fi

echo "[add-node] $NEW_HOST will join as a $ROLE"

# Step 1: Terraform creates the VM (or no-ops if already there).
echo
echo "[add-node] Step 1/3: Provision VM with Terraform"
PROXMOX_TOKEN_ID=$(ansible-vault view ansible/secrets/vault.yml \
  --vault-password-file .k3s-stack-vault-pass \
  | grep -E '^proxmox_api_token_id:' | awk -F: '{print $2}' | tr -d ' "')
PROXMOX_TOKEN_SECRET=$(ansible-vault view ansible/secrets/vault.yml \
  --vault-password-file .k3s-stack-vault-pass \
  | grep -E '^proxmox_api_token_secret:' | awk -F: '{print $2}' | tr -d ' "')
export PROXMOX_VE_API_TOKEN="${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"

cd "$REPO_ROOT/terraform"
terraform apply -auto-approve -target="proxmox_virtual_environment_vm.node[\"$NEW_HOST\"]"
cd "$REPO_ROOT"
unset PROXMOX_VE_API_TOKEN

# Step 2: wait for SSH.
NEW_IP=$(cd terraform && terraform output -json vm_ips | python3 -c "
import json, sys
print(json.load(sys.stdin).get('$NEW_HOST', ''))
")
if [[ -z "$NEW_IP" ]]; then
  echo "ERROR: Terraform output has no IP for $NEW_HOST. Check terraform.tfvars."
  exit 1
fi

echo
echo "[add-node] Step 2/3: Wait for SSH on $NEW_IP"
for i in {1..60}; do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 \
      "mark@$NEW_IP" 'true' 2>/dev/null; then
    echo "  ready"
    break
  fi
  sleep 3
done

# Step 3: Ansible.
echo
echo "[add-node] Step 3/3: Apply base config + join cluster"
cd "$REPO_ROOT/ansible"
ansible-playbook playbooks/01-common.yml --limit "$NEW_HOST"

if [[ "$ROLE" == "server" ]]; then
  ansible-playbook playbooks/03-k3s-join-servers.yml --limit "$NEW_HOST"
else
  ansible-playbook playbooks/05-k3s-join-agent.yml --limit "$NEW_HOST"
fi

echo
echo "[add-node] Done. Verify with: ./workstation/04-status.sh"
EOF
chmod +x workstation/03-add-node.sh

# ==================================================================
# 5. Remove vm-bootstrap/
# ==================================================================

echo "[migrate] Removing vm-bootstrap/ (replaced by Terraform + cloud-init)"
if [[ -d vm-bootstrap ]]; then
  if [[ -d .git ]]; then
    git rm -rf vm-bootstrap/ 2>/dev/null || rm -rf vm-bootstrap/
  else
    rm -rf vm-bootstrap/
  fi
fi

# ==================================================================
# 6. Vault: add Proxmox API token keys, preserving existing values
# ==================================================================

echo "[migrate] Checking ansible/secrets/vault.yml for Proxmox API token keys"

# Fast path: if the keys are already present, do nothing. This avoids producing
# a no-op-but-dirty git diff (re-encryption uses a fresh nonce, so the ciphertext
# changes even though the plaintext doesn't).
if ansible-vault view ansible/secrets/vault.yml --vault-password-file .k3s-stack-vault-pass 2>/dev/null \
    | grep -q '^proxmox_api_token_id:'; then
  echo "[migrate]   (Proxmox keys already present; leaving vault unchanged)"
else
  echo "[migrate]   Adding Proxmox API token keys"
  TMP_VAULT=$(mktemp)
  trap 'rm -f "$TMP_VAULT"' EXIT

  ansible-vault decrypt --vault-password-file .k3s-stack-vault-pass \
    --output "$TMP_VAULT" ansible/secrets/vault.yml

  cat >> "$TMP_VAULT" <<'EOF'

# Proxmox API token. Create one in the Proxmox UI:
#   Datacenter -> Permissions -> API Tokens -> Add
# Grant role PVEVMAdmin on path /vms (or a more scoped role).
# Token ID format: <user>@<realm>!<tokenid>, e.g. terraform@pve!k3s-stack
proxmox_api_token_id: "terraform@pve!k3s-stack"
proxmox_api_token_secret: "CHANGE-ME-UUID-FROM-PROXMOX"
EOF

  ansible-vault encrypt --vault-password-file .k3s-stack-vault-pass \
    --output ansible/secrets/vault.yml "$TMP_VAULT"

  echo "[migrate]   (new keys appended; edit with 'ansible-vault edit ansible/secrets/vault.yml')"
fi

# ==================================================================
# 7. README.md
# ==================================================================

echo "[migrate] Rewriting README.md"
cat > README.md <<'EOF'
# k3s Stack

A highly-available k3s cluster on Proxmox VE / Ubuntu Server 26.04, with kube-vip for the floating API endpoint, ingress-nginx + cert-manager + an internal CA for TLS, Rancher Manager for cluster governance, and Jenkins (in-cluster) for project-application CI/CD.

This repo *is* the runbook. The scripts under `workstation/` and the HCL under `terraform/` execute the procedure end-to-end. This document is the narrative.

---

## What you get

- **Three control-plane VMs** (`k3s-orchestrator`, `k3s-node-3001`, `k3s-node-3002`) running k3s with embedded etcd, provisioned by Terraform from a Proxmox template.
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

In pfSense: **Services → DNS Resolver → General Settings → Host Overrides → Add**. Add three entries, all pointing at `10.0.40.99`:

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
EOF

# ==================================================================
# 8. docs/TERRAFORM.md (new)
# ==================================================================

echo "[migrate] Creating docs/TERRAFORM.md"
cat > docs/TERRAFORM.md <<'EOF'
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
2. Drain and remove the node from k3s: `ssh mark@10.0.40.100 'sudo /usr/local/bin/k3s kubectl drain <hostname> --delete-emptydir-data --ignore-daemonsets --force'` then `kubectl delete node <hostname>`.
3. Remove the entry from `terraform/terraform.tfvars`.
4. `cd terraform && terraform apply` — Terraform destroys the VM.

### Resizing a VM

Edit the entry in `terraform.tfvars` (memory, cpu). `terraform apply` updates it in place. Disk grows non-destructively; disk shrinks are not supported by Terraform — destroy and recreate.

### Replacing the template

If the template is rebuilt (new VMID), update `template_id` in `terraform.tfvars`. The `lifecycle { ignore_changes = [clone] }` block on the VM resource prevents existing VMs from being recreated when the template changes — Terraform leaves them as they are. New VMs created after the change will clone from the new template.

If you *want* an existing VM to be recreated from the new template, taint it: `terraform -chdir=terraform taint 'proxmox_virtual_environment_vm.node["k3s-node-3001"]'`, then `terraform apply`.

## State

The repo uses **local state** (`terraform/terraform.tfstate`, gitignored). This is fine for a single operator on a single workstation, and consistent with the rest of the POC's "simple now, hardened later" posture.

When the time comes to move to multi-operator use:

1. Provision an Azure Storage account + container for the state.
2. Add a `backend "azurerm"` block to `versions.tf`.
3. Run `terraform init -migrate-state` from the workstation that currently holds the state. Terraform copies local state to Azure Storage.
4. Other operators run `terraform init` and pick up the same backend.

Native state locking (via Azure blob leases) prevents two operators applying at once.

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
EOF

# ==================================================================
# 9. docs/ARCHITECTURE.md
# ==================================================================

echo "[migrate] Rewriting docs/ARCHITECTURE.md (adds Terraform layer)"
cat > docs/ARCHITECTURE.md <<'EOF'
# Architecture

## End state

```
                ┌───────────────────────────────────────────────┐
                │  Operator's workstation                       │
                │   - git clone of this repo                    │
                │   - terraform, ansible, kubectl, helm         │
                │   - web browser                               │
                │   - Trusts the cluster's internal CA          │
                └───────────────────────────────────────────────┘
                            │                       │
                            │ Terraform → Proxmox   │ SSH + Ansible
                            │ (VM lifecycle)        │ (in-VM config)
                            ▼                       ▼
        ┌────────────────────────── LAN: 10.0.40.0/24 ──────────────────────────┐
        │                                                                        │
        │   Proxmox VE host        @ <proxmox-ip>:8006                           │
        │     - REST API (token auth)                                            │
        │     - Ubuntu 26.04 cloud-init template (VMID per terraform.tfvars)     │
        │                                                                        │
        │   pfSense @ 10.0.40.1   (gateway, DNS, OpenVPN WAN, MSS clamping)      │
        │     - Unbound host overrides:                                          │
        │         k3s-api.k3s.lan → 10.0.40.99                                   │
        │         rancher.k3s.lan → 10.0.40.99                                   │
        │         jenkins.k3s.lan → 10.0.40.99                                   │
        │                                                                        │
        │   ┌──────────────── kube-vip floating VIP: 10.0.40.99 ───────────────┐ │
        │   │  Always lives on whichever control-plane server is current leader│ │
        │   └──────────────────────────────────────────────────────────────────┘ │
        │                  ▲                  ▲                  ▲                │
        │   ┌──────────────┴──┐ ┌─────────────┴───┐ ┌────────────┴────┐          │
        │   │ k3s-orchestrator│ │  k3s-node-3001  │ │  k3s-node-3002  │          │
        │   │   10.0.40.100   │ │   10.0.40.101   │ │   10.0.40.102   │          │
        │   │   VMID 3000     │ │   VMID 3001     │ │   VMID 3002     │          │
        │   │   (Terraform)   │ │   (Terraform)   │ │   (Terraform)   │          │
        │   │                 │ │                 │ │                 │          │
        │   │  k3s SERVER     │ │  k3s SERVER     │ │  k3s SERVER     │          │
        │   │  + embedded etcd│ │  + embedded etcd│ │  + embedded etcd│          │
        │   │  + workloads    │ │  + workloads    │ │  + workloads    │          │
        │   └─────────────────┘ └─────────────────┘ └─────────────────┘          │
        │                                                                        │
        │   Cluster workloads (across all three nodes):                          │
        │     ingress-nginx   cert-manager   Rancher Manager                     │
        │     Jenkins         project apps                                       │
        │                                                                        │
        └────────────────────────────────────────────────────────────────────────┘
```

## Tool layers

| Layer | Tool | Owns |
|---|---|---|
| 1. VM lifecycle | Terraform (`bpg/proxmox`) | VM existence, sizing, networking, cloud-init data |
| 2. First-boot config | cloud-init | Hostname, static IP, SSH keys, base packages |
| 3. In-VM config | Ansible | Kernel modules, sysctls, k3s install, Helm releases |
| 4. Workload orchestration | Kubernetes (k3s) | Pods, Services, Ingresses, etc. |
| 5. Workload packaging | Helm | ingress-nginx, cert-manager, Rancher, Jenkins, project apps |

Each layer assumes the one below it is in place. Terraform produces a VM that's SSH-reachable; Ansible turns it into a k3s node; Kubernetes runs workloads.

## HA design decisions

### Why three control-plane peers?

An odd number ≥3 is required for etcd quorum. A 1-server cluster is a single point of failure. A 2-server cluster cannot tolerate any failure (split brain risk; etcd refuses writes without quorum). Three is the minimum that survives losing any one VM.

### Why all three as servers, not 1 server + 2 agents?

With only three VMs in the initial topology, dedicating none to workloads would waste capacity. k3s servers happily run workloads. When the cluster grows beyond three nodes, additional `k3s-node-3xxx` VMs join as pure agents (use `workstation/03-add-node.sh` with the host in the `k3s_agents` group and the `vms` map).

### Why embedded etcd?

It's k3s's HA-native datastore — no external infrastructure, scales fine at this size, recommended by Rancher for self-hosted k3s.

### Why kube-vip?

Runs as a pod on each control-plane node. ARP-based floating VIP — no external load balancer, no pfSense rules, no extra VMs. The VIP lives on whichever node currently holds the kube-vip lease. Failover takes 5–10 seconds.

### Why pre-join all three from day one?

Promotion-on-failure is operationally fragile (operator acts under pressure, etcd reconfiguration has its own failure modes). Pre-joined peers participate in quorum continuously and need no human action when one dies.

### Why Terraform for VM lifecycle?

- **Declarative.** "These VMs should exist with these properties." Adding/removing VMs is editing a map and re-running.
- **Drift detection.** `terraform plan` shows changes since last apply.
- **Idempotent destroy.** `terraform destroy` removes the VMs cleanly.
- **Standard pattern.** "Terraform for infra, Ansible for config" is widely understood; new operators can recognize it without retraining.

The alternative — using Ansible's `community.proxmox` collection — would be simpler (one less tool) but loses drift detection and the declarative model.

## The orchestrator's two facets

`k3s-orchestrator` (VM 3000) plays two roles:

| Facet | What happens when VM 3000 is gone |
|---|---|
| **Management hub** | Each peer has `~/.kube/config` pointing at the VIP. The operator's workstation can SSH to any peer. Nothing depends on VM 3000 specifically. |
| **k3s control plane peer** | Other two servers retain etcd quorum (2 of 3). kube-vip moves the VIP to a surviving node. API stays reachable. |

The **name** `k3s-orchestrator` and the **IP** `10.0.40.100` stay bound to VM 3000 throughout. They are not floating — they identify a specific VM. The floating piece is the API endpoint `10.0.40.99`, which is owned by kube-vip.

## What runs where

- **Operator workstation:** git clone, terraform, ansible, kubectl, helm, web browser.
- **Each VM:** k3s server (with embedded etcd), kube-vip pod, ingress-nginx pod, cert-manager pods, Rancher pod, Jenkins pod (the single Jenkins pod runs on one node at a time; rescheduled on failure).
- **In the cluster:** all of the above plus project applications you deploy via Jenkins.

## Where Jenkins fits

Jenkins is **scoped to project application CI/CD only** — building project Docker images, pushing them to a registry, and deploying them to the cluster via Helm. It does **not** manage cluster infrastructure. Cluster-level changes (upgrading Rancher, installing operators, modifying ingress) are done from the workstation using Terraform (for VMs) and Ansible playbooks (for everything else).
EOF

# ==================================================================
# 10. docs/SECRETS.md (mention Proxmox token)
# ==================================================================

echo "[migrate] Updating docs/SECRETS.md (Proxmox token addition)"
cat > docs/SECRETS.md <<'EOF'
# Secrets

## Where we are: Ansible Vault, passphrase in-repo

The current setup uses **Ansible Vault** to encrypt the contents of `ansible/secrets/vault.yml`. The vault passphrase lives in `.k3s-stack-vault-pass` at the repo root, which is committed to the repo.

This is deliberate for the first version of the stack:

- **Simplicity.** No out-of-band passphrase distribution. Anyone with the repo can run the playbooks.
- **Speed to first working cluster.** No new service (HashiCorp Vault) to stand up before the cluster exists.
- **Familiar workflow.** Ansible Vault is built into Ansible. No new tooling for the team to learn while they're learning k3s.

The trade-off: **anyone with read access to the repo can decrypt the secrets.** That's acceptable because the repo is private (GitHub private, later Azure DevOps private) and the secrets it holds are bootstrap-grade — initial Rancher and Jenkins admin passwords that the operator changes on first login, the k3s join token which is only useful inside the LAN, and a Proxmox API token whose scope is limited to VM management on the lab Proxmox.

## What's in the vault

- `rancher_bootstrap_password` — initial Rancher admin password. Rancher forces a change on first login.
- `jenkins_admin_password` — initial Jenkins admin password. Operator changes after first login.
- `proxmox_api_token_id` — Proxmox API token identifier (e.g. `terraform@pve!k3s-stack`). Used by Terraform via the `PROXMOX_VE_API_TOKEN` env var; never written to HCL.
- `proxmox_api_token_secret` — the UUID Proxmox generated for the token.

The Proxmox token has whatever permissions you granted it when creating the token in the Proxmox UI — `PVEVMAdmin` on `/` is the recommended scope. The token can be rotated by creating a new one, updating both values in the vault, and revoking the old one in the Proxmox UI.

## Where we're going: HashiCorp Vault

HashiCorp Vault is a separate running service that:

- Stores secrets behind a real authentication boundary (per-user / per-service tokens).
- Supports **dynamic secrets** (e.g., generates short-lived database credentials on demand).
- Has fine-grained ACLs (per-secret read/write policies).
- Provides an audit log of who decrypted what.
- Can integrate with cloud KMS for key wrapping.
- Has both cluster-infrastructure use cases (current Ansible Vault scope) **and** project-application use cases (apps fetch DB passwords, API keys, OAuth secrets at runtime instead of baking them into images or ConfigMaps).

The reason to move to HashiCorp Vault later, rather than stay on Ansible Vault forever:

- The current setup conflates "secrets needed to build the cluster" with "secrets at rest in git." Once project applications need secrets at runtime, Ansible Vault stops being the right tool for that part — Ansible runs at deploy time, not at request time.
- HashiCorp Vault gives both layers (infra + apps) a single source of truth.

## Migration plan (sketch)

This is the rough shape, not a runbook. The runbook will be written when migration is actually next on the priority list.

1. **Stand up Vault in the cluster.** Run Vault in HA mode (3 replicas with Raft storage) as a Helm chart deployment. Initialize and unseal.
2. **Move existing secrets.** Move the contents of `ansible/secrets/vault.yml` into HashiCorp Vault. Update playbooks to read them at runtime (via the `community.hashi_vault` Ansible collection) instead of via vars_files.
3. **Wire project applications to Vault.** Use the Vault Agent Injector or External Secrets Operator to make Vault secrets available as Kubernetes Secrets or mounted files inside Pods.
4. **Decommission Ansible Vault.** Once all secrets have moved, delete `ansible/secrets/vault.yml` and `.k3s-stack-vault-pass`. The repo no longer contains any secrets at all (encrypted or otherwise).

## What this means for now

- **Do edit `ansible/secrets/vault.yml`** with `ansible-vault edit ansible/secrets/vault.yml` and set real values before running `01-cluster-up.sh`.
- **Don't put project-application secrets** (DB passwords, API keys) in Ansible Vault. Wait for HashiCorp Vault. In the meantime, Kubernetes Secrets created by `kubectl` directly are an acceptable interim measure for project apps — they aren't committed to git.
- **Do change `.k3s-stack-vault-pass`** from its placeholder value to something specific to your environment. It's still in the repo, but a unique passphrase per environment means a leaked repo from one environment doesn't compromise another.
EOF

# ==================================================================
# 11. docs/REPO-HOSTING.md — add terraform/ files to the migration list
# ==================================================================

echo "[migrate] Updating docs/REPO-HOSTING.md (terraform/ files in migration list)"
# This file already exists from v1; we update the "what needs to change" list.
# Use python to do a precise replacement that's safe to re-run.
python3 <<'PYEOF'
from pathlib import Path
import re

path = Path("docs/REPO-HOSTING.md")
content = path.read_text()

# Update the count of URLs that need changing. The v1 doc mentioned bootstrap.sh
# and README.md. Now: README.md, vm-bootstrap is gone, but the same Terraform-era
# repo still has just-a-couple-of-URLs pointing at GitHub — and the
# 03-add-node.sh URL that the in-flight Copilot edits already produced.

# We rewrite the entire "What needs to change" section so it reflects the v2 layout.
new_section = """## What needs to change to move to Azure DevOps

The only URLs in this repo that point at GitHub are documentation references in `README.md` and example URLs in scripts that need to fetch the repo at runtime. As of v2 (Terraform-based), no script fetches from the repo URL during cluster bring-up — Terraform reads the repo's `keys/authorized_keys` file from the local working copy. So the GitHub→AzDO migration is now purely a documentation update.

Files to update when moving to Azure DevOps:
1. **`README.md`** — any URLs in the Procedure or examples.
2. **`docs/REPO-HOSTING.md`** — this file (update its own examples).
3. **Anywhere the repo URL appears in a comment** (e.g., the `# Repository:` header in workstation scripts).

After updating those, push to Azure DevOps. The rest of the repo is hosting-agnostic — Terraform, Ansible, Helm, and the scripts all work with the repo files on the local filesystem only."""

# Replace from "## What needs to change" to the next "## " heading.
content = re.sub(
    r"## What needs to change to move to Azure DevOps.*?(?=^## |\Z)",
    new_section + "\n\n",
    content,
    count=1,
    flags=re.DOTALL | re.MULTILINE,
)

path.write_text(content)
print("REPO-HOSTING.md updated")
PYEOF

# ==================================================================
# 12. Validate
# ==================================================================

echo
echo "[migrate] Validating outputs"

echo "  - bash -n on workstation/*.sh"
for s in workstation/*.sh; do
  bash -n "$s" || { echo "FAIL: $s"; exit 1; }
done

echo "  - YAML parse on all *.yml and *.yaml"
python3 - <<'PY'
import yaml, glob, sys
errors = 0
for path in glob.glob('**/*.yml', recursive=True) + glob.glob('**/*.yaml', recursive=True):
    if 'secrets/vault.yml' in path or '.tftpl' in path:
        continue
    try:
        with open(path) as f:
            list(yaml.safe_load_all(f))
    except Exception as e:
        print(f"FAIL {path}: {e}")
        errors += 1
sys.exit(errors)
PY

echo "  - ansible-playbook --syntax-check on all playbooks"
cd ansible
for p in playbooks/*.yml; do
  ansible-playbook --syntax-check "$p" >/dev/null 2>&1 || { echo "FAIL: $p"; exit 1; }
done
cd ..

echo "  - terraform fmt -check on terraform/"
if command -v terraform >/dev/null 2>&1; then
  cd terraform && terraform fmt -check -recursive >/dev/null 2>&1 || {
    echo "  (terraform fmt would change files; running terraform fmt to fix)"
    terraform fmt -recursive >/dev/null
  }
  cd ..
else
  echo "  (terraform not installed; skipping fmt check — run terraform fmt later)"
fi

echo "  - vault decrypts cleanly"
ansible-vault view ansible/secrets/vault.yml --vault-password-file .k3s-stack-vault-pass >/dev/null

echo
echo "[migrate] Done."
echo
echo "Next steps:"
echo "  1. Review the changes:    git status && git diff"
echo "  2. Edit Terraform config: \$EDITOR terraform/terraform.tfvars"
echo "  3. Edit the vault:        ansible-vault edit ansible/secrets/vault.yml"
echo "  4. Commit:                git add -A && git commit -m 'v2: Terraform-based VM provisioning'"
echo "  5. Install terraform:     ./workstation/00-install-tools.sh"
echo "  6. Bring up the cluster:  ./workstation/01-cluster-up.sh"
