terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }

  # Local state is fine for the POC phase. When moving to multi-operator use
  # or production, migrate to an Azure Storage backend — see docs/TERRAFORM.md.
}
