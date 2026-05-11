# Read operator SSH public keys from the in-repo keys file. The bootstrap.sh
# fetched this at runtime; we now bake it in at VM creation time via cloud-init.
locals {
  ssh_keys = [
    for line in split("\n", file(var.ssh_authorized_keys_file)) :
    line if length(trimspace(line)) > 0 && !startswith(trimspace(line), "#")
  ]
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.vms

  name        = each.key
  vm_id       = each.value.vmid
  node_name   = var.proxmox_node
  description = "k3s-stack node: ${each.key}. Managed by Terraform."
  tags        = ["k3s-stack", "terraform"]

  # Clone from the Ubuntu Server 26.04 template.
  clone {
    vm_id     = var.template_id
    node_name = var.template_node
    full      = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cpu
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk_gb
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # Cloud-init: structured fields here; arbitrary YAML in the user_data_file.
  initialization {
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = each.value.gateway
      }
    }

    dns {
      servers = ["10.0.40.1"]
    }

    user_account {
      username = var.vm_user
      keys     = local.ssh_keys
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data[each.key].id
  }

  operating_system {
    type = "l26" # Linux 2.6+ (covers 5.x and 6.x kernels)
  }

  lifecycle {
    # Re-cloning the disk every time the template is rebuilt is rarely what we
    # want. Once the VM exists, treat the disk as durable.
    ignore_changes = [
      clone,
    ]
  }
}

# Per-VM cloud-init user-data snippet. Sets hostname, installs base packages,
# enables SSH. Replaces what vm-bootstrap/bootstrap.sh did in v1.
resource "proxmox_virtual_environment_file" "cloud_init_user_data" {
  for_each = var.vms

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    file_name = "${each.key}-user-data.yaml"
    data = templatefile("${path.module}/cloud-init-user-data.yaml.tftpl", {
      hostname = each.key
    })
  }
}
