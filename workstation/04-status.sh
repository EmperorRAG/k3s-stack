#!/usr/bin/env bash
#
# Cluster status / health check.
# Run from the operator workstation. Reads the node list from Terraform output
# so it stays correct as nodes are added/removed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VIP="10.0.40.100"

# Build the list of node IPs from Terraform.
mapfile -t NODE_IPS < <(cd "$REPO_ROOT/terraform" && terraform output -json vm_ips 2>/dev/null \
  | python3 -c 'import json,sys; [print(v) for v in json.load(sys.stdin).values()]')

if [[ ${#NODE_IPS[@]} -eq 0 ]]; then
  echo "ERROR: no node IPs from terraform output. Has the cluster been built?"
  exit 1
fi

# The first server is "where we run kubectl from."
# Pick the lowest-VMID server (last digit '1') as the canonical entry point.
mapfile -t SERVER_IPS < <(cd "$REPO_ROOT/terraform" && terraform output -json vm_ips 2>/dev/null \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
servers = sorted([(name, ip) for name, ip in data.items() if "server" in name])
for _, ip in servers:
    print(ip)
')

if [[ ${#SERVER_IPS[@]} -eq 0 ]]; then
  echo "ERROR: no server nodes found in terraform output."
  exit 1
fi

ENTRY_IP="${SERVER_IPS[0]}"
ENTRY="mark@$ENTRY_IP"

run() {
  echo
  echo "===== $1 ====="
  shift
  ssh "$ENTRY" "$@"
}

run "Nodes" \
  'sudo /usr/local/bin/k3s kubectl get nodes -o wide'

run "Pods not Running/Completed (should be empty)" \
  'sudo /usr/local/bin/k3s kubectl get pods -A | grep -vE "Running|Completed|^NAMESPACE" || true'

run "kube-vip pods (one per server)" \
  'sudo /usr/local/bin/k3s kubectl -n kube-system get pods -l name=kube-vip-ds -o wide'

echo
echo "===== Which node holds the VIP ====="
for ip in "${NODE_IPS[@]}"; do
  echo -n "  $ip: "
  ssh -o StrictHostKeyChecking=accept-new "mark@$ip" \
    "ip addr show ens18 | grep -oP '$VIP' || echo no-vip" 2>/dev/null || echo "(unreachable)"
done

run "Rancher reachable" \
  'curl -sk -o /dev/null -w "  https://rancher.k3s.lan/ -> %{http_code}\n" https://rancher.k3s.lan/'

run "Jenkins reachable" \
  'curl -sk -o /dev/null -w "  https://jenkins.k3s.lan/ -> %{http_code}\n" https://jenkins.k3s.lan/'

run "Helm releases" \
  'helm list -A'
