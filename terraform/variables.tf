variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint URL"
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS verification on the Proxmox API. True is acceptable for an internal cluster using a self-signed cert."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node name (the hypervisor host) to provision VMs on"
  type        = string
}

variable "template_id" {
  description = "VMID of the Ubuntu Server 26.04 template to clone from"
  type        = number
}

variable "template_node" {
  description = "Proxmox node the template lives on (usually the same as proxmox_node)"
  type        = string
}

variable "vms" {
  description = "VM definitions. Keys are hostnames; values define VMID, IP, role, resources."
  type = map(object({
    vmid    = number
    ip      = string # e.g. "10.0.40.100/24"
    gateway = string # e.g. "10.0.40.1"
    memory  = number # MiB
    cpu     = number # vCPU count
    disk_gb = number # primary disk size in GiB
  }))
}

variable "ssh_authorized_keys_file" {
  description = "Path (relative to this directory) to the file containing operator SSH public keys"
  type        = string
  default     = "../keys/authorized_keys"
}

variable "vm_user" {
  description = "Cloud-init user account name on each VM"
  type        = string
  default     = "mark"
}
