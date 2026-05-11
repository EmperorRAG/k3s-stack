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
