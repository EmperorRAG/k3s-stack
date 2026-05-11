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
