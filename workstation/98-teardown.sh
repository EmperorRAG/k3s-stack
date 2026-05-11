#!/usr/bin/env bash
#
# Tear the k3s cluster down completely. Leaves the VMs running and reachable
# over SSH; only the k3s install and its state are removed.
#
# Use 97-rebuild.sh to teardown-then-build in one shot.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/ansible"

cat <<'EOF'

  ============================== WARNING ==============================
  This will run /usr/local/bin/k3s-uninstall.sh on every node, deleting
  ALL Kubernetes state, etcd data, and any persistent volumes backed by
  local-path storage.

  The VMs themselves keep running, but the cluster is gone.
  =====================================================================

EOF

read -r -p "Type 'destroy' to proceed: " CONFIRM
if [[ "$CONFIRM" != "destroy" ]]; then
  echo "Aborted."
  exit 1
fi

ansible-playbook playbooks/99-k3s-uninstall.yml

echo
echo "[teardown] Done. Cluster removed; VMs still reachable over SSH."
