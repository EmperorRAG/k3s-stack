#!/usr/bin/env bash
#
# Refactor the k3s-stack repo to the new naming and IP scheme.
#
# OLD scheme:
#   k3s-orchestrator (VMID 3000, IP 10.0.40.100)
#   k3s-node-3001    (VMID 3001, IP 10.0.40.101)
#   k3s-node-3002    (VMID 3002, IP 10.0.40.102)
#   Floating VIP:    10.0.40.99
#
# NEW scheme (rack/slot model):
#   Rack digit x = 1..9
#   Slot 1 of each rack = control-plane server (k3s-node-server-30x1, 10.0.40.1x1)
#   Slots 2..9 of each rack = agents          (k3s-node-agent-30xy,  10.0.40.1xy)
#   Floating VIP: 10.0.40.100
#
#   Capacity: up to 9 racks × (1 server + 8 agents) = 9 servers, 72 agents.
#
# Initial cluster (the three VMs from v2, recast as 3 servers across 3 racks):
#   k3s-node-server-3011 (VMID 3011, IP 10.0.40.111)  -- cluster-init server
#   k3s-node-server-3021 (VMID 3021, IP 10.0.40.121)
#   k3s-node-server-3031 (VMID 3031, IP 10.0.40.131)
#
# This script is run from the repo root after the v2 (Terraform) migration is in
# place. It is idempotent and refuses dirty trees so the diff stays reviewable.

set -euo pipefail

# ---------- safety ----------

if [[ ! -f README.md || ! -d ansible || ! -d terraform ]]; then
  echo "ERROR: run this from the k3s-stack repo root (after the v2/Terraform migration)."
  echo "Expected README.md, ansible/, and terraform/ in the current directory."
  exit 1
fi

if [[ -d .git ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree has uncommitted changes."
    echo "Commit or stash them first so this refactor is reviewable as a single diff."
    exit 1
  fi
fi

if ! command -v ansible-vault >/dev/null 2>&1; then
  echo "ERROR: ansible-vault not on PATH. Open the dev container or install Ansible."
  exit 1
fi

echo "[refactor] Pre-flight passed. Beginning naming refactor."
echo

# ==================================================================
# 1. ansible/inventory/hosts.yml — full rewrite
# ==================================================================

echo "[refactor] Rewriting ansible/inventory/hosts.yml"

cat > ansible/inventory/hosts.yml <<'YAML'
---
# Inventory for the k3s-stack cluster.
#
# Naming scheme:
#   k3s-node-server-30x1  = control-plane server in rack x (x = 1..9)
#   k3s-node-agent-30xy   = agent in rack x, slot y (y = 2..9)
# IP scheme:
#   10.0.40.1xy  matches VMID 30xy
# Floating API VIP:
#   10.0.40.100  (owned by kube-vip, lives on whichever server is leader)
#
# Add new servers under k3s_servers; add new agents under k3s_agents.
# Exactly one server has k3s_init_node: true AND lives in the
# k3s_cluster_init group — by convention the rack-1 server.
# All other servers join the cluster initialised by that node.

all:
  children:
    k3s_cluster:
      children:
        k3s_servers:
          hosts:
            k3s-node-server-3011:
              ansible_host: 10.0.40.111
              k3s_node_ip: 10.0.40.111
              k3s_init_node: true     # cluster bootstraps from here
            k3s-node-server-3021:
              ansible_host: 10.0.40.121
              k3s_node_ip: 10.0.40.121
              k3s_init_node: false
            k3s-node-server-3031:
              ansible_host: 10.0.40.131
              k3s_node_ip: 10.0.40.131
              k3s_init_node: false
        k3s_agents:
          hosts: {}     # populated as agents are added
      vars:
        ansible_user: mark
        ansible_python_interpreter: /usr/bin/python3

        # Cluster-wide facts referenced by multiple playbooks.
        k3s_version: "v1.31.4+k3s1"
        k3s_vip: "10.0.40.100"
        k3s_api_hostname: "k3s-api.k3s.lan"
        rancher_hostname: "rancher.k3s.lan"
        jenkins_hostname: "jenkins.k3s.lan"

    # Single-member group naming the cluster-init server, so playbooks can
    # target it without hard-coding the hostname. When the init server is
    # promoted/replaced, update only this group plus the k3s_init_node flag
    # in k3s_servers — nothing in the playbooks changes.
    k3s_cluster_init:
      hosts:
        k3s-node-server-3011:
YAML

# ==================================================================
# 2. terraform/terraform.tfvars — full rewrite
# ==================================================================

echo "[refactor] Rewriting terraform/terraform.tfvars"

cat > terraform/terraform.tfvars <<'TFVARS'
# Proxmox endpoint and node. Adjust to your environment.
proxmox_endpoint = "https://proxmox.k3s.lan:8006/"
proxmox_node     = "pve"

# Template the VMs are cloned from. See docs/TERRAFORM.md for the prep checklist.
template_id   = 9000
template_node = "pve"

# VM definitions for the initial 3-server cluster.
#
# Naming and IP scheme (see ansible/inventory/hosts.yml for the full doc):
#   - Rack x (1..9) maps to /24 third-octet group 1x in 10.0.40.1xy.
#   - Slot 1 in each rack is a control-plane server: k3s-node-server-30x1.
#   - Slots 2..9 in each rack are agents:            k3s-node-agent-30xy.
#   - VMID matches the host: VMID 30xy <-> hostname *-30xy <-> IP 10.0.40.1xy.
#
# To add a 4th server in rack 4: add an entry with vmid=3041, ip="10.0.40.141/24".
# To add an agent in rack 1:     add an entry with vmid=30x2..30x9, hostname
#                                k3s-node-agent-30xy, ip="10.0.40.1xy/24".
#
# The Ansible inventory at ansible/inventory/hosts.yml must list the same VMs.

vms = {
  "k3s-node-server-3011" = {
    vmid    = 3011
    ip      = "10.0.40.111/24"
    gateway = "10.0.40.1"
    memory  = 4096
    cpu     = 2
    disk_gb = 40
  }
  "k3s-node-server-3021" = {
    vmid    = 3021
    ip      = "10.0.40.121/24"
    gateway = "10.0.40.1"
    memory  = 4096
    cpu     = 2
    disk_gb = 40
  }
  "k3s-node-server-3031" = {
    vmid    = 3031
    ip      = "10.0.40.131/24"
    gateway = "10.0.40.1"
    memory  = 4096
    cpu     = 2
    disk_gb = 40
  }
}
TFVARS

# ==================================================================
# 3. manifests/kube-vip.yaml — VIP address 10.0.40.99 -> 10.0.40.100
# ==================================================================

echo "[refactor] Updating manifests/kube-vip.yaml (VIP -> 10.0.40.100)"
# Single literal replacement. The string `value: "10.0.40.99"` appears exactly once.
sed -i 's|value: "10.0.40.99"|value: "10.0.40.100"|' manifests/kube-vip.yaml

# ==================================================================
# 4. ansible/playbooks/01-common.yml — /etc/hosts block
# ==================================================================

echo "[refactor] Updating ansible/playbooks/01-common.yml (/etc/hosts block)"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("ansible/playbooks/01-common.yml")
content = p.read_text()

new_hosts_block = """        block: |
          10.0.40.100 k3s-api.k3s.lan
          10.0.40.111 k3s-node-server-3011
          10.0.40.121 k3s-node-server-3021
          10.0.40.131 k3s-node-server-3031"""

content = re.sub(
    r"        block: \|\n(?:          10\.0\.40\.[0-9]+\s+\S+\n)+",
    new_hosts_block + "\n",
    content,
    count=1,
)
p.write_text(content)
print("    01-common.yml /etc/hosts block rewritten")
PY

# ==================================================================
# 5. ansible/playbooks/03-k3s-join-servers.yml — retarget the verify play
# ==================================================================

echo "[refactor] Updating ansible/playbooks/03-k3s-join-servers.yml"

python3 - <<'PY'
from pathlib import Path

p = Path("ansible/playbooks/03-k3s-join-servers.yml")
content = p.read_text()

# 1. The join URL referenced 'k3s-orchestrator' directly via hostvars.
#    Switch to the cluster-init group's first (and only) member.
content = content.replace(
    "k3s_join_url: \"https://{{ hostvars['k3s-orchestrator']['ansible_host'] }}:6443\"",
    "k3s_join_url: \"https://{{ hostvars[groups['k3s_cluster_init'] | first]['ansible_host'] }}:6443\"",
)

# 2. The k3s_join_token var in the join play also referenced 'k3s-orchestrator'.
content = content.replace(
    "k3s_join_token: \"{{ hostvars['k3s-orchestrator']['k3s_join_token'] }}\"",
    "k3s_join_token: \"{{ hostvars[groups['k3s_cluster_init'] | first]['k3s_join_token'] }}\"",
)

# 3. The final verify play targeted k3s-orchestrator.
#    Retarget it to the cluster-init group.
content = content.replace(
    "- name: Verify cluster has all three control-plane members\n  hosts: k3s-orchestrator",
    "- name: Verify cluster has all three control-plane members\n  hosts: k3s_cluster_init",
)

p.write_text(content)
print("    03-k3s-join-servers.yml retargeted to k3s_cluster_init group")
PY

# ==================================================================
# 6. ansible/playbooks/04-cluster-workloads.yml — retarget orchestrator-only play
# ==================================================================

echo "[refactor] Updating ansible/playbooks/04-cluster-workloads.yml"

sed -i 's|^  hosts: k3s-orchestrator$|  hosts: k3s_cluster_init|' ansible/playbooks/04-cluster-workloads.yml

# ==================================================================
# 7. ansible/playbooks/05-k3s-join-agent.yml — token-source target
# ==================================================================

echo "[refactor] Updating ansible/playbooks/05-k3s-join-agent.yml"

python3 - <<'PY'
from pathlib import Path

p = Path("ansible/playbooks/05-k3s-join-agent.yml")
content = p.read_text()

# Token-source play targets k3s-orchestrator; retarget to the cluster-init group.
content = content.replace(
    "- name: Read join token from cluster-init server\n  hosts: k3s-orchestrator",
    "- name: Read join token from cluster-init server\n  hosts: k3s_cluster_init",
)

# Token lookup via hostvars used the old name.
content = content.replace(
    "k3s_join_token: \"{{ hostvars['k3s-orchestrator']['k3s_join_token'] }}\"",
    "k3s_join_token: \"{{ hostvars[groups['k3s_cluster_init'] | first]['k3s_join_token'] }}\"",
)

p.write_text(content)
print("    05-k3s-join-agent.yml retargeted to k3s_cluster_init group")
PY

# ==================================================================
# 8. workstation/02-extract-ca.sh — talk to the init server's IP
# ==================================================================

echo "[refactor] Updating workstation/02-extract-ca.sh"

python3 - <<'PY'
from pathlib import Path
p = Path("workstation/02-extract-ca.sh")
c = p.read_text()
c = c.replace("k3s-orchestrator", "k3s-node-server-3011")
c = c.replace("mark@10.0.40.100", "mark@10.0.40.111")
p.write_text(c)
print("    02-extract-ca.sh updated")
PY

# ==================================================================
# 9. workstation/04-status.sh — parameterise over Terraform output
# ==================================================================

echo "[refactor] Rewriting workstation/04-status.sh (parameterised over Terraform)"

cat > workstation/04-status.sh <<'BASH'
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
BASH
chmod +x workstation/04-status.sh

# ==================================================================
# 10. workstation/99-failover-drill.sh — parameterise + new names
# ==================================================================

echo "[refactor] Rewriting workstation/99-failover-drill.sh"

cat > workstation/99-failover-drill.sh <<'BASH'
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
BASH
chmod +x workstation/99-failover-drill.sh

# ==================================================================
# 11. README.md — narrative updates
# ==================================================================

echo "[refactor] Updating README.md"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("README.md")
c = p.read_text()

# The "What you get" bullet that listed the three old VMs.
c = re.sub(
    r"- \*\*Three control-plane VMs\*\* \(`k3s-orchestrator`, `k3s-node-3001`, `k3s-node-3002`\) running k3s with embedded etcd, provisioned by Terraform from a Proxmox template\.",
    "- **Three control-plane VMs** (`k3s-node-server-3011`, `k3s-node-server-3021`, `k3s-node-server-3031`) running k3s with embedded etcd, provisioned by Terraform from a Proxmox template. Naming follows a rack/slot scheme — see `docs/ARCHITECTURE.md`.",
    c, count=1,
)

# The VIP IP in the headline bullet.
c = c.replace(
    "- **Floating API endpoint at `10.0.40.99`**",
    "- **Floating API endpoint at `10.0.40.100`**",
)

# The cluster-survives sentence — drop the parenthetical that named the orchestrator.
c = c.replace(
    "The cluster survives the loss of any single VM (including `k3s-orchestrator`) with no operator action.",
    "The cluster survives the loss of any single VM with no operator action.",
)

# The pfSense host-overrides section pointed at .99; now .100.
c = c.replace(
    "Add three entries, all pointing at `10.0.40.99`:",
    "Add three entries, all pointing at `10.0.40.100`:",
)

p.write_text(c)
print("    README.md updated")
PY

# ==================================================================
# 12. docs/ARCHITECTURE.md — full rewrite of the topology diagram + text
# ==================================================================

echo "[refactor] Rewriting docs/ARCHITECTURE.md"

cat > docs/ARCHITECTURE.md <<'MD'
# Architecture

## End state

```
                ┌───────────────────────────────────────────────┐
                │  Operator's workstation                       │
                │   - git clone of this repo                    │
                │   - terraform, ansible, kubectl, helm         │
                │     (in the dev container)                    │
                │   - web browser                               │
                │   - Trusts the cluster's internal CA          │
                └───────────────────────────────────────────────┘
                            │                       │
                            │ Terraform → Proxmox   │ SSH + Ansible
                            │ (VM lifecycle)        │ (in-VM config)
                            ▼                       ▼
        ┌────────────────────────── LAN: 10.0.40.0/24 ──────────────────────────┐
        │                                                                        │
        │   Proxmox VE host        @ <proxmox-ip>:8006                           │
        │     - REST API (token auth)                                            │
        │     - Ubuntu 26.04 cloud-init template (VMID per terraform.tfvars)     │
        │                                                                        │
        │   pfSense @ 10.0.40.1   (gateway, DNS, OpenVPN WAN, MSS clamping)      │
        │     - Unbound host overrides:                                          │
        │         k3s-api.k3s.lan → 10.0.40.100                                  │
        │         rancher.k3s.lan → 10.0.40.100                                  │
        │         jenkins.k3s.lan → 10.0.40.100                                  │
        │                                                                        │
        │   ┌─────────── kube-vip floating VIP: 10.0.40.100 ────────────────────┐│
        │   │  Always lives on whichever control-plane server is current leader ││
        │   └───────────────────────────────────────────────────────────────────┘│
        │            ▲                       ▲                       ▲           │
        │            │                       │                       │           │
        │   ┌────────┴───────────┐ ┌─────────┴──────────┐ ┌──────────┴────────┐ │
        │   │k3s-node-server-3011│ │k3s-node-server-3021│ │k3s-node-server-3031│ │
        │   │   10.0.40.111      │ │   10.0.40.121      │ │   10.0.40.131      │ │
        │   │   VMID 3011        │ │   VMID 3021        │ │   VMID 3031        │ │
        │   │   (rack 1, slot 1) │ │   (rack 2, slot 1) │ │   (rack 3, slot 1) │ │
        │   │                    │ │                    │ │                    │ │
        │   │  k3s SERVER        │ │  k3s SERVER        │ │  k3s SERVER        │ │
        │   │  + embedded etcd   │ │  + embedded etcd   │ │  + embedded etcd   │ │
        │   │  + workloads       │ │  + workloads       │ │  + workloads       │ │
        │   └────────────────────┘ └────────────────────┘ └────────────────────┘ │
        │                                                                        │
        │   Future agent capacity (added when scale demands):                    │
        │     k3s-node-agent-3012..3019  (rack 1, slots 2-9, IPs .112-.119)      │
        │     k3s-node-agent-3022..3029  (rack 2, slots 2-9, IPs .122-.129)      │
        │     k3s-node-agent-3032..3039  (rack 3, slots 2-9, IPs .132-.139)      │
        │                                                                        │
        │   Cluster workloads (across all servers):                              │
        │     ingress-nginx   cert-manager   Rancher Manager                     │
        │     Jenkins         project apps                                       │
        │                                                                        │
        └────────────────────────────────────────────────────────────────────────┘
```

## Naming and IP scheme

A rack/slot model lets the cluster grow predictably without renaming or renumbering.

```
   Hostname            VMID    IP
   ─────────────────── ─────── ─────────────
   k3s-node-server-30x1 30x1   10.0.40.1x1        ← server in rack x
   k3s-node-agent-30xy  30xy   10.0.40.1xy        ← agent in rack x, slot y
                                                    (x = 1..9, y = 2..9)
```

- **Rack digit `x` (1..9)** is the third character of the four-digit VMID and the
  second-last octet group of the IP. Think of it as a logical grouping —
  workloads needing topology spread can target `rack` labels later.
- **Slot digit (last digit, 1..9)** distinguishes nodes within a rack.
  Slot `1` is reserved for the rack's control-plane server. Slots `2..9` are
  agents.
- **VMID matches hostname matches IP** — given any one, the other two follow.
  Memorising the pattern means glancing at `kubectl get nodes` tells you
  exactly which Proxmox VM you're looking at.

Capacity ceiling: **9 racks × (1 server + 8 agents) = 9 servers and 72 agents**.
That's enough headroom that the scheme doesn't need to change before the
cluster outgrows this hardware footprint entirely.

The **floating API VIP** is `10.0.40.100`. It is owned by kube-vip and lives
on whichever server is the current kube-vip leader.

## HA design decisions

### Why three control-plane servers, in three different racks?

An odd number ≥3 is required for etcd quorum. A 1-server cluster is a single
point of failure. A 2-server cluster cannot tolerate any failure (split brain
risk; etcd refuses writes without quorum). Three is the minimum that survives
losing any one VM.

Spreading the three servers across three different racks means a whole-rack
failure (single Proxmox host failure, a future rack-level networking issue,
etc.) loses at most one peer. Quorum survives.

### Why all initial nodes as servers, not 1 server + 2 agents?

With only three VMs in the initial topology, dedicating none to workloads
would waste capacity. k3s servers happily run workloads. When the cluster grows
beyond three nodes, additional VMs join as pure agents — typically as
`k3s-node-agent-30xy` filling slots 2..9 within an existing rack.

### Why embedded etcd?

It's k3s's HA-native datastore — no external infrastructure, scales fine at
this size, recommended by Rancher for self-hosted k3s.

### Why kube-vip?

Runs as a pod on each control-plane node. ARP-based floating VIP — no external
load balancer, no pfSense rules, no extra VMs. The VIP lives on whichever node
currently holds the kube-vip lease. Failover takes 5–10 seconds.

### Why pre-join all servers from day one?

Promotion-on-failure is operationally fragile (operator acts under pressure,
etcd reconfiguration has its own failure modes). Pre-joined peers participate
in quorum continuously and need no human action when one dies.

### Why no special-purpose "orchestrator" VM?

Earlier versions of this stack named one VM `k3s-orchestrator` and treated it
as the cluster's management entry point. That coupling broke the cluster's
symmetry: a fully HA cluster shouldn't have any node with a privileged name
or role. Under the new scheme every server is an interchangeable peer; the
cluster-init flag is just a one-time inventory marker on the first server
provisioned (by convention `k3s-node-server-3011`), and once etcd is up the
flag doesn't matter anymore.

The operator's "management hub" is the workstation (running the dev
container), not any individual VM. kubectl works against the VIP regardless of
which server is alive.

## Tool layers

| Layer | Tool | Owns |
|---|---|---|
| 1. VM lifecycle | Terraform (`bpg/proxmox`) | VM existence, sizing, networking, cloud-init data |
| 2. First-boot config | cloud-init | Hostname, static IP, SSH keys, base packages |
| 3. In-VM config | Ansible | Kernel modules, sysctls, k3s install, Helm releases |
| 4. Workload orchestration | Kubernetes (k3s) | Pods, Services, Ingresses, etc. |
| 5. Workload packaging | Helm | ingress-nginx, cert-manager, Rancher, Jenkins, project apps |

Each layer assumes the one below it is in place. Terraform produces a VM that's
SSH-reachable; Ansible turns it into a k3s node; Kubernetes runs workloads.

## Adding a node

Two places to update, in this order:

1. **`terraform/terraform.tfvars`** — add an entry to the `vms` map following
   the naming/IP/VMID convention. Pick the next free slot in an existing rack
   for agents, or the next rack's slot 1 for a new server.
2. **`ansible/inventory/hosts.yml`** — add the same hostname under
   `k3s_servers.hosts` (for an additional server) or `k3s_agents.hosts`
   (for an agent). Servers get `k3s_init_node: false` — only the original
   bootstrap server has `k3s_init_node: true`.

Then run `./workstation/03-add-node.sh <hostname>`.

## Where Jenkins fits

Jenkins is **scoped to project application CI/CD only** — building project
Docker images, pushing them to a registry, and deploying them to the cluster
via Helm. It does **not** manage cluster infrastructure. Cluster-level changes
(upgrading Rancher, installing operators, modifying ingress) are done from the
workstation using Terraform (for VMs) and Ansible playbooks (for everything
else).
MD

# ==================================================================
# 13. docs/CA-TRUST.md — single IP reference
# ==================================================================

echo "[refactor] Updating docs/CA-TRUST.md"
sed -i 's|mark@10\.0\.40\.100|mark@10.0.40.111|g' docs/CA-TRUST.md
sed -i 's|k3s-orchestrator|k3s-node-server-3011|g' docs/CA-TRUST.md 2>/dev/null || true

# ==================================================================
# 14. docs/TERRAFORM.md — naming convention + add-node example
# ==================================================================

echo "[refactor] Updating docs/TERRAFORM.md"

python3 - <<'PY'
from pathlib import Path
p = Path("docs/TERRAFORM.md")
c = p.read_text()

# Replace the VM-name examples and the drain example with the new naming.
c = c.replace(
    "`proxmox_virtual_environment_vm.node[\"k3s-node-3001\"]`",
    "`proxmox_virtual_environment_vm.node[\"k3s-node-server-3021\"]`",
)
c = c.replace(
    "ssh mark@10.0.40.100",
    "ssh mark@10.0.40.111",
)
# Any other lingering 'k3s-node-3001' or 'k3s-node-3002' references.
c = c.replace("k3s-node-3001", "k3s-node-server-3021")
c = c.replace("k3s-node-3002", "k3s-node-server-3031")

p.write_text(c)
print("    TERRAFORM.md updated")
PY

# ==================================================================
# 15. docs/TROUBLESHOOTING.md — IP and hostname references
# ==================================================================

echo "[refactor] Updating docs/TROUBLESHOOTING.md"

python3 - <<'PY'
from pathlib import Path
p = Path("docs/TROUBLESHOOTING.md")
c = p.read_text()

# Generic references to the old VIP.
c = c.replace("`10.0.40.99`", "`10.0.40.100`")
# Any lingering 'k3s-orchestrator' references.
c = c.replace("k3s-orchestrator", "k3s-node-server-3011")
# 04-status.sh / failover drill IP lists no longer hard-coded; doc still
# mentions ssh patterns we can leave generic.

p.write_text(c)
print("    TROUBLESHOOTING.md updated")
PY

# ==================================================================
# 16. docs/REPO-HOSTING.md — example URL in the bootstrap-pattern doc
# ==================================================================

echo "[refactor] Updating docs/REPO-HOSTING.md"
sed -i 's|k3s-orchestrator|k3s-node-server-3011|g' docs/REPO-HOSTING.md
sed -i 's|10\.0\.40\.100|10.0.40.111|g' docs/REPO-HOSTING.md

# ==================================================================
# 17. .ansible-lint — no changes needed (still excludes the right paths)
#     workstation/01-cluster-up.sh, 97-rebuild.sh, 98-teardown.sh, 03-add-node.sh,
#     00-install-tools.sh, 00b-install-terraform.sh — already parameterised over
#     Terraform output, no hard-coded hostnames or IPs.
# ==================================================================

# ==================================================================
# 18. Validate
# ==================================================================

echo
echo "[refactor] Validating outputs"

echo "  - bash -n on workstation/*.sh"
for s in workstation/*.sh; do
  bash -n "$s" || { echo "FAIL: $s"; exit 1; }
done

echo "  - YAML parse on all *.yml and *.yaml"
python3 - <<'PY'
import yaml, glob, sys
errors = 0
for path in glob.glob('**/*.yml', recursive=True) + glob.glob('**/*.yaml', recursive=True):
    if 'secrets/vault.yml' in path or '.tftpl' in path:
        continue
    try:
        with open(path) as f:
            list(yaml.safe_load_all(f))
    except Exception as e:
        print(f"FAIL {path}: {e}")
        errors += 1
sys.exit(errors)
PY

echo "  - ansible-playbook --syntax-check"
cd ansible
for p in playbooks/*.yml; do
  ansible-playbook --syntax-check "$p" >/dev/null 2>&1 || { echo "FAIL: $p"; exit 1; }
done
cd ..

echo "  - residual old-name check (should be empty)"
# Ignore docs/ARCHITECTURE.md — it intentionally explains the historical
# 'k3s-orchestrator' naming in the rationale for why it no longer exists.
RESIDUAL=$(grep -rn -e 'k3s-orchestrator' -e 'k3s-node-3001\b' -e 'k3s-node-3002\b' \
  --exclude-dir=.git --exclude-dir=node_modules \
  --exclude=ARCHITECTURE.md . 2>/dev/null || true)
if [[ -n "$RESIDUAL" ]]; then
  echo "WARN: residual old-name references found (excluding intentional historical refs):"
  echo "$RESIDUAL"
fi

echo "  - residual old-IP check (10.0.40.99 / .101 / .102 in unexpected places)"
RESIDUAL_IPS=$(grep -rn -e '10\.0\.40\.99\b' -e '10\.0\.40\.101\b' -e '10\.0\.40\.102\b' \
  --exclude-dir=.git . 2>/dev/null \
  | grep -v 'ansible/secrets/vault.yml' || true)
if [[ -n "$RESIDUAL_IPS" ]]; then
  echo "WARN: residual old-IP references found:"
  echo "$RESIDUAL_IPS"
fi

echo
echo "[refactor] Done."
echo
if [[ -d .git ]]; then
  echo "Files changed:"
  git status --short
  echo
fi
cat <<'NEXT'
Next steps:

  1. Review:           git diff && git status
  2. Commit:           git add -A && git commit -m 'Refactor to rack/slot naming scheme'
  3. Update pfSense:   In Services -> DNS Resolver -> Host Overrides, change the IP
                       on the rancher.k3s.lan / jenkins.k3s.lan / k3s-api.k3s.lan
                       entries from 10.0.40.99 to 10.0.40.100.
  4. Build cluster:    ./workstation/01-cluster-up.sh
                       (Terraform provisions 3 servers in racks 1-3, Ansible
                        configures them, the cluster comes up at VIP .100.)
  5. Extract CA cert:  ./workstation/02-extract-ca.sh
  6. Verify:           ./workstation/04-status.sh
  7. Failover test:    ./workstation/99-failover-drill.sh
NEXT
