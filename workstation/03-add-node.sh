#!/usr/bin/env bash
#
# Add a new node to the cluster.
#
# Prerequisites:
#   1. VM provisioned in Proxmox from the template.
#   2. Bootstrap run on the VM via the Proxmox console:
#        curl -fsSL <repo>/raw/main/vm-bootstrap/bootstrap.sh \
#          | sudo bash -s -- <hostname> <ip>
#   3. The host entry added to ansible/inventory/hosts.yml under either
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
cd "$REPO_ROOT/ansible"

# Sanity check that the host is in the inventory.
if ! ansible-inventory --list 2>/dev/null | grep -q "\"$NEW_HOST\""; then
  echo "ERROR: $NEW_HOST is not in ansible/inventory/hosts.yml"
  echo "Add it under k3s_servers.hosts or k3s_agents.hosts, then re-run."
  exit 1
fi

# Determine whether it's a server or agent based on inventory membership.
ROLE=""
if ansible-inventory --host "$NEW_HOST" 2>/dev/null | grep -q '"k3s_init_node"'; then
  ROLE="server"
elif ansible-inventory --list 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
if '$NEW_HOST' in data.get('k3s_servers', {}).get('hosts', []):
    print('server')
elif '$NEW_HOST' in data.get('k3s_agents', {}).get('hosts', []):
    print('agent')
" | grep -qE '^server|^agent'; then
  ROLE=$(ansible-inventory --list 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
if '$NEW_HOST' in data.get('k3s_servers', {}).get('hosts', []):
    print('server')
elif '$NEW_HOST' in data.get('k3s_agents', {}).get('hosts', []):
    print('agent')
")
fi

if [[ -z "$ROLE" ]]; then
  echo "ERROR: could not determine role (server vs agent) for $NEW_HOST from the inventory."
  exit 1
fi

echo "[add-node] $NEW_HOST will join as a $ROLE"

echo "[add-node] Step 1/2: Common base configuration"
ansible-playbook playbooks/01-common.yml --limit "$NEW_HOST"

echo
if [[ "$ROLE" == "server" ]]; then
  echo "[add-node] Step 2/2: Join as additional k3s server"
  ansible-playbook playbooks/03-k3s-join-servers.yml --limit "$NEW_HOST"
else
  echo "[add-node] Step 2/2: Join as k3s agent"
  ansible-playbook playbooks/05-k3s-join-agent.yml --limit "$NEW_HOST"
fi

echo
echo "[add-node] Done. Verify with: ./workstation/04-status.sh"
