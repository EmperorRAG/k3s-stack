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
