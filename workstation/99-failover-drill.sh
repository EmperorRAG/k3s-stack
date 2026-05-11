#!/usr/bin/env bash
#
# Guided failover drill. Walks the operator through stopping k3s-orchestrator,
# verifying that cluster survives, and bringing it back. Does not actually
# stop the VM — that step is manual via the Proxmox UI to keep the operator
# in the loop.

set -euo pipefail

cat <<'EOF'

  ====================== Failover Drill ======================
  This guided test verifies that the cluster survives losing
  k3s-orchestrator. You will:

    1. Confirm the cluster is healthy.
    2. Stop VM 3000 (k3s-orchestrator) from the Proxmox UI.
    3. Watch the cluster recover.
    4. Start VM 3000 again.
    5. Confirm it rejoins.
  ============================================================

EOF

echo "Press Enter to confirm baseline health..."
read

echo "----- Baseline: kubectl get nodes -----"
ssh mark@10.0.40.101 'sudo /usr/local/bin/k3s kubectl get nodes'

echo
echo "----- Baseline: VIP location -----"
for ip in 10.0.40.100 10.0.40.101 10.0.40.102; do
  echo -n "  $ip: "
  ssh mark@$ip 'ip addr show ens18 | grep -oP "10\.0\.40\.99" || echo no-vip' 2>/dev/null || echo "(unreachable)"
done

cat <<'EOF'

  -------------------------------------------------------------
  Now: In the Proxmox UI, STOP (not shut down) VM 3000.
  Use 'Stop' to simulate a hard failure, not 'Shutdown'.
  -------------------------------------------------------------

EOF

echo "Press Enter once VM 3000 is stopped..."
read

# Give the cluster a moment to notice.
echo "Waiting 15 seconds for kube-vip to elect a new leader..."
sleep 15

echo
echo "----- During failure: kubectl get nodes (via k3s-node-3001) -----"
ssh mark@10.0.40.101 'sudo /usr/local/bin/k3s kubectl get nodes' || true

echo
echo "----- During failure: VIP location (orchestrator unreachable, expected) -----"
for ip in 10.0.40.100 10.0.40.101 10.0.40.102; do
  echo -n "  $ip: "
  timeout 3 ssh -o ConnectTimeout=2 mark@$ip 'ip addr show ens18 | grep -oP "10\.0\.40\.99" || echo no-vip' 2>/dev/null || echo "(unreachable — expected for 10.0.40.100)"
done

echo
echo "----- During failure: Rancher and Jenkins still reachable -----"
echo -n "  https://rancher.k3s.lan/ -> "
curl -sk -o /dev/null -w "%{http_code}\n" https://rancher.k3s.lan/ || echo "FAIL"
echo -n "  https://jenkins.k3s.lan/ -> "
curl -sk -o /dev/null -w "%{http_code}\n" https://jenkins.k3s.lan/ || echo "FAIL"

cat <<'EOF'

  -------------------------------------------------------------
  Cluster survived. Now: START VM 3000 again from the Proxmox UI.
  -------------------------------------------------------------

EOF

echo "Press Enter once VM 3000 has booted (give it ~30 seconds)..."
read

echo "Waiting another 15 seconds for k3s to settle..."
sleep 15

echo
echo "----- After recovery: kubectl get nodes -----"
ssh mark@10.0.40.100 'sudo /usr/local/bin/k3s kubectl get nodes' || \
  ssh mark@10.0.40.101 'sudo /usr/local/bin/k3s kubectl get nodes'

echo
echo "----- After recovery: VIP location -----"
for ip in 10.0.40.100 10.0.40.101 10.0.40.102; do
  echo -n "  $ip: "
  ssh mark@$ip 'ip addr show ens18 | grep -oP "10\.0\.40\.99" || echo no-vip' 2>/dev/null || echo "(unreachable)"
done

echo
echo "Failover drill complete."
