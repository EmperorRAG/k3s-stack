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
