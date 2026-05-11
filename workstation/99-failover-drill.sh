#!/usr/bin/env bash
#
# Guided failover drill. Walks the operator through stopping a control-plane
# server, verifying that the cluster survives, and bringing it back. Does not
# stop the VM automatically — that step is manual via the Proxmox UI so the
# operator stays in the loop.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VIP="10.0.40.100"

# Discover servers from Terraform output (hostname containing "server").
mapfile -t SERVERS < <(cd "$REPO_ROOT/terraform" && terraform output -json vm_ips 2>/dev/null \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
for name, ip in sorted(data.items()):
    if "server" in name:
        print(f"{name} {ip}")
')

if [[ ${#SERVERS[@]} -lt 3 ]]; then
  echo "ERROR: failover drill requires at least 3 servers; found ${#SERVERS[@]}."
  exit 1
fi

# Pick the first server as the one we'll stop.
read -r TARGET_NAME TARGET_IP <<<"${SERVERS[0]}"
read -r SURVIVOR_NAME SURVIVOR_IP <<<"${SERVERS[1]}"

# Pull just the VMID off the hostname (last four digits).
TARGET_VMID="${TARGET_NAME##*-}"

cat <<EOF

  ====================== Failover Drill ======================
  This guided test verifies that the cluster survives losing
  a control-plane server. You will:

    1. Confirm the cluster is healthy.
    2. Stop VM $TARGET_VMID ($TARGET_NAME) from the Proxmox UI.
    3. Watch the cluster recover.
    4. Start VM $TARGET_VMID again.
    5. Confirm it rejoins.
  ============================================================

EOF

echo "Press Enter to confirm baseline health..."
read -r

echo "----- Baseline: kubectl get nodes (via $SURVIVOR_NAME) -----"
ssh "mark@$SURVIVOR_IP" 'sudo /usr/local/bin/k3s kubectl get nodes'

echo
echo "----- Baseline: VIP location -----"
for entry in "${SERVERS[@]}"; do
  read -r name ip <<<"$entry"
  echo -n "  $name ($ip): "
  ssh "mark@$ip" "ip addr show ens18 | grep -oP '$VIP' || echo no-vip" 2>/dev/null || echo "(unreachable)"
done

cat <<EOF

  -------------------------------------------------------------
  Now: In the Proxmox UI, STOP (not shut down) VM $TARGET_VMID.
  Use 'Stop' to simulate a hard failure, not 'Shutdown'.
  -------------------------------------------------------------

EOF

echo "Press Enter once VM $TARGET_VMID is stopped..."
read -r

echo "Waiting 15 seconds for kube-vip to elect a new leader..."
sleep 15

echo
echo "----- During failure: kubectl get nodes (via $SURVIVOR_NAME) -----"
ssh "mark@$SURVIVOR_IP" 'sudo /usr/local/bin/k3s kubectl get nodes' || true

echo
echo "----- During failure: VIP location (target unreachable, expected) -----"
for entry in "${SERVERS[@]}"; do
  read -r name ip <<<"$entry"
  echo -n "  $name ($ip): "
  timeout 3 ssh -o ConnectTimeout=2 "mark@$ip" \
    "ip addr show ens18 | grep -oP '$VIP' || echo no-vip" 2>/dev/null \
    || echo "(unreachable — expected for $TARGET_NAME)"
done

echo
echo "----- During failure: Rancher and Jenkins still reachable -----"
echo -n "  https://rancher.k3s.lan/ -> "
curl -sk -o /dev/null -w "%{http_code}\n" https://rancher.k3s.lan/ || echo "FAIL"
echo -n "  https://jenkins.k3s.lan/ -> "
curl -sk -o /dev/null -w "%{http_code}\n" https://jenkins.k3s.lan/ || echo "FAIL"

cat <<EOF

  -------------------------------------------------------------
  Cluster survived. Now: START VM $TARGET_VMID again from the Proxmox UI.
  -------------------------------------------------------------

EOF

echo "Press Enter once VM $TARGET_VMID has booted (give it ~30 seconds)..."
read -r

echo "Waiting another 15 seconds for k3s to settle..."
sleep 15

echo
echo "----- After recovery: kubectl get nodes -----"
ssh "mark@$TARGET_IP" 'sudo /usr/local/bin/k3s kubectl get nodes' 2>/dev/null \
  || ssh "mark@$SURVIVOR_IP" 'sudo /usr/local/bin/k3s kubectl get nodes'

echo
echo "----- After recovery: VIP location -----"
for entry in "${SERVERS[@]}"; do
  read -r name ip <<<"$entry"
  echo -n "  $name ($ip): "
  ssh "mark@$ip" "ip addr show ens18 | grep -oP '$VIP' || echo no-vip" 2>/dev/null || echo "(unreachable)"
done

echo
echo "Failover drill complete."
