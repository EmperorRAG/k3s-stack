# The Proxmox API token is supplied via the PROXMOX_VE_API_TOKEN environment
# variable, which workstation/01-cluster-up.sh exports from Ansible Vault before
# calling Terraform. This keeps the token out of HCL and out of `terraform show`.
#
# Format: PROXMOX_VE_API_TOKEN="<token-id>=<token-secret>"
# Example: PROXMOX_VE_API_TOKEN="terraform@pve!k3s-stack=00000000-0000-0000-0000-000000000000"

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = var.proxmox_insecure
}
