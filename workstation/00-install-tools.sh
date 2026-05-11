#!/usr/bin/env bash
#
# Install Ansible, kubectl, and Helm on the operator's workstation.
# Linux/macOS only. Windows users should run this inside WSL2.
# Idempotent.

set -euo pipefail

# ---------- devcontainer detection ----------
# If we're inside the dev container, every tool was installed at container build
# time via Dev Container Features. Nothing to do here.
if [[ -n "${REMOTE_CONTAINERS:-}" || -n "${CODESPACES:-}" || -f "/.dockerenv" && -d "/workspaces" ]]; then
  echo "[install] Running inside a dev container — tools are already installed."
  echo "[install] Versions:"
  ansible --version 2>/dev/null | head -1 || echo "  ansible: not found"
  kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1 || echo "  kubectl: not found"
  helm version --short 2>/dev/null || echo "  helm: not found"
  terraform version 2>/dev/null | head -1 || echo "  terraform: not found"
  exit 0
fi


# ---------- detect platform ----------

OS="$(uname -s)"
case "$OS" in
  Linux*)
    if command -v apt-get >/dev/null 2>&1; then
      PKG="apt"
    elif command -v dnf >/dev/null 2>&1; then
      PKG="dnf"
    else
      echo "ERROR: Unsupported Linux distro (need apt or dnf)."
      exit 1
    fi
    ;;
  Darwin*)
    if ! command -v brew >/dev/null 2>&1; then
      echo "ERROR: macOS requires Homebrew. Install from https://brew.sh"
      exit 1
    fi
    PKG="brew"
    ;;
  *)
    echo "ERROR: Unsupported OS: $OS. Use Linux, macOS, or WSL2."
    exit 1
    ;;
esac

echo "[install] Platform: $OS / $PKG"

# ---------- install ansible ----------

install_ansible() {
  if command -v ansible >/dev/null 2>&1; then
    echo "[install] ansible already present: $(ansible --version | head -1)"
    return
  fi
  echo "[install] Installing ansible"
  case "$PKG" in
    apt)  sudo apt-get update -qq && sudo apt-get install -y ansible python3-kubernetes ;;
    dnf)  sudo dnf install -y ansible python3-kubernetes ;;
    brew) brew install ansible ;;
  esac
}

# ---------- install kubectl ----------

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    echo "[install] kubectl already present: $(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1)"
    return
  fi
  echo "[install] Installing kubectl"
  case "$PKG" in
    apt|dnf)
      KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
      curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
      sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
      rm kubectl
      ;;
    brew)
      brew install kubectl
      ;;
  esac
}

# ---------- install helm ----------

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    echo "[install] helm already present: $(helm version --short)"
    return
  fi
  echo "[install] Installing helm"
  case "$PKG" in
    apt|dnf)
      curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      ;;
    brew)
      brew install helm
      ;;
  esac
}

# ---------- install ansible collections ----------

install_ansible_collections() {
  echo "[install] Installing Ansible collections"
  ansible-galaxy collection install --upgrade \
    community.general \
    ansible.posix \
    kubernetes.core
}

# ---------- run ----------

install_ansible
install_kubectl
install_helm
install_ansible_collections

echo
echo "[install] Done."
echo "[install] Versions:"
ansible --version | head -1
kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1 || kubectl version --client 2>&1 | head -1
helm version --short
