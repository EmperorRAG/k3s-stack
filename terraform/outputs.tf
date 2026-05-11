output "vm_ips" {
  description = "Map of hostname to IPv4 address for each provisioned VM"
  value = {
    for name, vm in var.vms : name => split("/", vm.ip)[0]
  }
}

output "vm_ids" {
  description = "Map of hostname to Proxmox VMID"
  value = {
    for name, vm in var.vms : name => vm.vmid
  }
}
