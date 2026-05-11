#!/usr/bin/env bash
#
# Install Terraform on the operator workstation. Called by 00-install-tools.sh.
# Idempotent.

set -euo pipefail

if command -v terraform >/dev/null 2>&1; then
  echo "[install-terraform] terraform already present: $(terraform version | head -1)"
  exit 0
fi

OS="$(uname -s)"
case "$OS" in
  Linux*)
    if command -v apt-get >/dev/null 2>&1; then
      echo "[install-terraform] Installing via HashiCorp apt repo"
      sudo apt-get update -qq
      sudo apt-get install -y -qq gnupg software-properties-common
      wget -O- https://apt.releases.hashicorp.com/gpg | \
        gpg --dearmor | \
        sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
        https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
      sudo apt-get update -qq
      sudo apt-get install -y terraform
    elif command -v dnf >/dev/null 2>&1; then
      echo "[install-terraform] Installing via HashiCorp dnf repo"
      sudo dnf install -y dnf-plugins-core
      sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
      sudo dnf install -y terraform
    else
      echo "ERROR: Unsupported Linux distro (need apt or dnf)."
      exit 1
    fi
    ;;
  Darwin*)
    echo "[install-terraform] Installing via Homebrew"
    brew tap hashicorp/tap
    brew install hashicorp/tap/terraform
    ;;
  *)
    echo "ERROR: Unsupported OS: $OS. Use Linux, macOS, or WSL2."
    exit 1
    ;;
esac

terraform version | head -1
