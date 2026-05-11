#!/usr/bin/env bash
#
# k3s-stack VM bootstrap.
# Pasted via `curl ... | sudo bash -s -- <hostname> <ip>` from the Proxmox console
# on a fresh VM. Idempotent — safe to re-run.
#
# What it does:
#   1. Validates args.
#   2. Writes /etc/netplan/01-static.yaml with the static IP.
#   3. Removes the installer netplan file if present.
#   4. Applies netplan.
#   5. Installs openssh-server, wget, ca-certificates, curl (if any are missing).
#   6. Sets the hostname.
#   7. Fetches the operator authorized_keys file from the repo and writes it to ~mark/.ssh/authorized_keys.
#
# What it does NOT do:
#   - Install k3s (Ansible from the workstation does that).
#   - Configure MTU (handled upstream by pfSense MSS clamping).
#   - Disable cloud-init (template already does that).

set -euo pipefail

# ---------- configuration ----------

# Adjust this URL when you swap GitHub for Azure DevOps. For a private GitHub repo,
# embed a PAT: https://<TOKEN>@raw.githubusercontent.com/...
AUTHORIZED_KEYS_URL="${AUTHORIZED_KEYS_URL:-https://raw.githubusercontent.com/EmperorRAG/k3s-stack/main/keys/authorized_keys}"

GATEWAY="10.0.40.1"
DNS_SERVER="10.0.40.1"
NIC="ens18"
USER_NAME="mark"

# ---------- arg parsing ----------

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <hostname> <ip>"
  echo "Example: $0 k3s-orchestrator 10.0.40.100"
  exit 1
fi

HOSTNAME_ARG="$1"
IP_ARG="$2"

if ! [[ "$IP_ARG" =~ ^10\.0\.40\.[0-9]+$ ]]; then
  echo "ERROR: IP must be in 10.0.40.0/24; got '$IP_ARG'"
  exit 1
fi

echo "[bootstrap] Hostname: $HOSTNAME_ARG"
echo "[bootstrap] IP:       $IP_ARG/24"
echo "[bootstrap] Gateway:  $GATEWAY"
echo "[bootstrap] DNS:      $DNS_SERVER"

# ---------- must be root ----------

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: this script must run as root (use sudo)"
  exit 1
fi

# ---------- netplan ----------

echo "[bootstrap] Writing /etc/netplan/01-static.yaml"
cat > /etc/netplan/01-static.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NIC}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${IP_ARG}/24
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - ${DNS_SERVER}
EOF
chmod 600 /etc/netplan/01-static.yaml

# Remove the installer's netplan file so there's only one source of truth.
if [[ -f /etc/netplan/00-installer-config.yaml ]]; then
  echo "[bootstrap] Removing /etc/netplan/00-installer-config.yaml"
  rm -f /etc/netplan/00-installer-config.yaml
fi

echo "[bootstrap] Applying netplan"
netplan generate
netplan apply

# Give the NIC a moment to settle on the new address.
sleep 3

# ---------- base packages ----------

echo "[bootstrap] Updating apt cache"
apt-get update -qq

echo "[bootstrap] Installing base packages (openssh-server, wget, ca-certificates, curl)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  openssh-server \
  wget \
  ca-certificates \
  curl

systemctl enable --now ssh

# ---------- hostname ----------

echo "[bootstrap] Setting hostname to $HOSTNAME_ARG"
hostnamectl set-hostname "$HOSTNAME_ARG"

# /etc/hosts entry so sudo doesn't complain about hostname resolution.
if ! grep -qE "^127\.0\.1\.1\s+$HOSTNAME_ARG" /etc/hosts; then
  echo "127.0.1.1 $HOSTNAME_ARG" >> /etc/hosts
fi

# ---------- authorized_keys ----------

echo "[bootstrap] Fetching operator authorized_keys from repo"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
SSH_DIR="$USER_HOME/.ssh"
AUTH_FILE="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Fetch to a temp file first so a download failure doesn't blow away existing keys.
TMP_KEYS=$(mktemp)
if curl -fsSL "$AUTHORIZED_KEYS_URL" -o "$TMP_KEYS"; then
  # Strip the comment-only lines from the repo file; keep real keys only.
  grep -vE '^\s*(#|$)' "$TMP_KEYS" > "$AUTH_FILE" || true
  chmod 600 "$AUTH_FILE"
  chown -R "$USER_NAME:$USER_NAME" "$SSH_DIR"
  echo "[bootstrap] Installed $(wc -l < "$AUTH_FILE") authorized key(s)"
else
  echo "[bootstrap] WARNING: failed to fetch authorized_keys from $AUTHORIZED_KEYS_URL"
  echo "[bootstrap] Continuing — you can add keys manually later."
fi
rm -f "$TMP_KEYS"

# ---------- done ----------

echo
echo "[bootstrap] Done."
echo "[bootstrap] $HOSTNAME_ARG is reachable at $IP_ARG."
echo "[bootstrap] You can close this console."
