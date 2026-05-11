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
