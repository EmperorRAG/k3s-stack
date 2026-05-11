# Architecture

## End state

```
                ┌───────────────────────────────────────────────┐
                │  Operator's workstation                       │
                │   - git clone of this repo                    │
                │   - terraform, ansible, kubectl, helm         │
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
        │         k3s-api.k3s.lan → 10.0.40.99                                   │
        │         rancher.k3s.lan → 10.0.40.99                                   │
        │         jenkins.k3s.lan → 10.0.40.99                                   │
        │                                                                        │
        │   ┌──────────────── kube-vip floating VIP: 10.0.40.99 ───────────────┐ │
        │   │  Always lives on whichever control-plane server is current leader│ │
        │   └──────────────────────────────────────────────────────────────────┘ │
        │                  ▲                  ▲                  ▲                │
        │   ┌──────────────┴──┐ ┌─────────────┴───┐ ┌────────────┴────┐          │
        │   │ k3s-orchestrator│ │  k3s-node-3001  │ │  k3s-node-3002  │          │
        │   │   10.0.40.100   │ │   10.0.40.101   │ │   10.0.40.102   │          │
        │   │   VMID 3000     │ │   VMID 3001     │ │   VMID 3002     │          │
        │   │   (Terraform)   │ │   (Terraform)   │ │   (Terraform)   │          │
        │   │                 │ │                 │ │                 │          │
        │   │  k3s SERVER     │ │  k3s SERVER     │ │  k3s SERVER     │          │
        │   │  + embedded etcd│ │  + embedded etcd│ │  + embedded etcd│          │
        │   │  + workloads    │ │  + workloads    │ │  + workloads    │          │
        │   └─────────────────┘ └─────────────────┘ └─────────────────┘          │
        │                                                                        │
        │   Cluster workloads (across all three nodes):                          │
        │     ingress-nginx   cert-manager   Rancher Manager                     │
        │     Jenkins         project apps                                       │
        │                                                                        │
        └────────────────────────────────────────────────────────────────────────┘
```

## Tool layers

| Layer | Tool | Owns |
|---|---|---|
| 1. VM lifecycle | Terraform (`bpg/proxmox`) | VM existence, sizing, networking, cloud-init data |
| 2. First-boot config | cloud-init | Hostname, static IP, SSH keys, base packages |
| 3. In-VM config | Ansible | Kernel modules, sysctls, k3s install, Helm releases |
| 4. Workload orchestration | Kubernetes (k3s) | Pods, Services, Ingresses, etc. |
| 5. Workload packaging | Helm | ingress-nginx, cert-manager, Rancher, Jenkins, project apps |

Each layer assumes the one below it is in place. Terraform produces a VM that's SSH-reachable; Ansible turns it into a k3s node; Kubernetes runs workloads.

## HA design decisions

### Why three control-plane peers?

An odd number ≥3 is required for etcd quorum. A 1-server cluster is a single point of failure. A 2-server cluster cannot tolerate any failure (split brain risk; etcd refuses writes without quorum). Three is the minimum that survives losing any one VM.

### Why all three as servers, not 1 server + 2 agents?

With only three VMs in the initial topology, dedicating none to workloads would waste capacity. k3s servers happily run workloads. When the cluster grows beyond three nodes, additional `k3s-node-3xxx` VMs join as pure agents (use `workstation/03-add-node.sh` with the host in the `k3s_agents` group and the `vms` map).

### Why embedded etcd?

It's k3s's HA-native datastore — no external infrastructure, scales fine at this size, recommended by Rancher for self-hosted k3s.

### Why kube-vip?

Runs as a pod on each control-plane node. ARP-based floating VIP — no external load balancer, no pfSense rules, no extra VMs. The VIP lives on whichever node currently holds the kube-vip lease. Failover takes 5–10 seconds.

### Why pre-join all three from day one?

Promotion-on-failure is operationally fragile (operator acts under pressure, etcd reconfiguration has its own failure modes). Pre-joined peers participate in quorum continuously and need no human action when one dies.

### Why Terraform for VM lifecycle?

- **Declarative.** "These VMs should exist with these properties." Adding/removing VMs is editing a map and re-running.
- **Drift detection.** `terraform plan` shows changes since last apply.
- **Idempotent destroy.** `terraform destroy` removes the VMs cleanly.
- **Standard pattern.** "Terraform for infra, Ansible for config" is widely understood; new operators can recognize it without retraining.

The alternative — using Ansible's `community.proxmox` collection — would be simpler (one less tool) but loses drift detection and the declarative model.

## The orchestrator's two facets

`k3s-orchestrator` (VM 3000) plays two roles:

| Facet | What happens when VM 3000 is gone |
|---|---|
| **Management hub** | Each peer has `~/.kube/config` pointing at the VIP. The operator's workstation can SSH to any peer. Nothing depends on VM 3000 specifically. |
| **k3s control plane peer** | Other two servers retain etcd quorum (2 of 3). kube-vip moves the VIP to a surviving node. API stays reachable. |

The **name** `k3s-orchestrator` and the **IP** `10.0.40.100` stay bound to VM 3000 throughout. They are not floating — they identify a specific VM. The floating piece is the API endpoint `10.0.40.99`, which is owned by kube-vip.

## What runs where

- **Operator workstation:** git clone, terraform, ansible, kubectl, helm, web browser.
- **Each VM:** k3s server (with embedded etcd), kube-vip pod, ingress-nginx pod, cert-manager pods, Rancher pod, Jenkins pod (the single Jenkins pod runs on one node at a time; rescheduled on failure).
- **In the cluster:** all of the above plus project applications you deploy via Jenkins.

## Where Jenkins fits

Jenkins is **scoped to project application CI/CD only** — building project Docker images, pushing them to a registry, and deploying them to the cluster via Helm. It does **not** manage cluster infrastructure. Cluster-level changes (upgrading Rancher, installing operators, modifying ingress) are done from the workstation using Terraform (for VMs) and Ansible playbooks (for everything else).
