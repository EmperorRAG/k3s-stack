#!/usr/bin/env bash
#
# Bring the k3s HA cluster up end-to-end from the operator workstation.
# Idempotent — re-running on a healthy cluster is a no-op.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/ansible"

echo "[cluster-up] Step 1/4: Common base configuration"
ansible-playbook playbooks/01-common.yml

echo
echo "[cluster-up] Step 2/4: Install k3s on the cluster-init node"
ansible-playbook playbooks/02-k3s-init.yml

echo
echo "[cluster-up] Step 3/4: Join the other servers"
ansible-playbook playbooks/03-k3s-join-servers.yml

echo
echo "[cluster-up] Step 4/4: Install cluster workloads (ingress, cert-manager, CA, Rancher, Jenkins)"
ansible-playbook playbooks/04-cluster-workloads.yml

echo
echo "[cluster-up] Done."
echo "[cluster-up] Next steps:"
echo "  - Extract the CA cert:  ./workstation/02-extract-ca.sh"
echo "  - Check status:         ./workstation/04-status.sh"
echo "  - Run failover drill:   ./workstation/99-failover-drill.sh"
