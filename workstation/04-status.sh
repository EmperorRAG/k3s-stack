#!/usr/bin/env bash
#
# Cluster status / health check.
# Run from the operator workstation.

set -euo pipefail

ORCH=mark@10.0.40.100

run() {
  echo
  echo "===== $1 ====="
  shift
  ssh "$ORCH" "$@"
}

run "Nodes" \
  'sudo /usr/local/bin/k3s kubectl get nodes -o wide'

run "Pods not Running/Completed (should be empty)" \
  'sudo /usr/local/bin/k3s kubectl get pods -A | grep -vE "Running|Completed|^NAMESPACE" || true'

run "kube-vip pods (one per server)" \
  'sudo /usr/local/bin/k3s kubectl -n kube-system get pods -l name=kube-vip-ds -o wide'

run "Which node holds the VIP" \
  'for ip in 10.0.40.100 10.0.40.101 10.0.40.102; do
     echo -n "  $ip: ";
     ssh -o StrictHostKeyChecking=accept-new mark@$ip "ip addr show ens18 | grep -oP \"10\.0\.40\.99\" || echo no-vip"
   done'

run "Rancher reachable" \
  'curl -sk -o /dev/null -w "  https://rancher.k3s.lan/ -> %{http_code}\n" https://rancher.k3s.lan/'

run "Jenkins reachable" \
  'curl -sk -o /dev/null -w "  https://jenkins.k3s.lan/ -> %{http_code}\n" https://jenkins.k3s.lan/'

run "Helm releases" \
  'helm list -A'
