# Proxmox endpoint and node. Adjust to your environment.
proxmox_endpoint = "https://proxmox.k3s.lan:8006/"
proxmox_node     = "pve"

# Template the VMs are cloned from. Must be configured with:
#   - cloud-init drive attached
#   - qemu-guest-agent installed and enabled
#   - virtio network device on vmbr0
# See docs/TERRAFORM.md for the template prep checklist.
template_id   = 9000
template_node = "pve"

vms = {
  "k3s-orchestrator" = {
    vmid    = 3000
    ip      = "10.0.40.100/24"
    gateway = "10.0.40.1"
    memory  = 4096
    cpu     = 2
    disk_gb = 40
  }
  "k3s-node-3001" = {
    vmid    = 3001
    ip      = "10.0.40.101/24"
    gateway = "10.0.40.1"
    memory  = 4096
    cpu     = 2
    disk_gb = 40
  }
  "k3s-node-3002" = {
    vmid    = 3002
    ip      = "10.0.40.102/24"
    gateway = "10.0.40.1"
    memory  = 4096
    cpu     = 2
    disk_gb = 40
  }
}
