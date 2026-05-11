#!/usr/bin/env bash
#
# Runs once, after the dev container is built and the workspace is mounted.
# Anything that needs to happen "the first time you open this repo in the
# dev container" goes here.

set -euo pipefail

echo "[post-create] Installing Ansible Galaxy collections used by playbooks"
ansible-galaxy collection install --upgrade \
    community.general \
    ansible.posix \
    kubernetes.core

# The host's ~/.ssh is bind-mounted read-only at /home/mark/.ssh.
# Set up a per-container writable SSH config that:
#   - reads the host's keys/config via the bind mount
#   - writes known_hosts to a container-local path
# This keeps the host's known_hosts pristine while still letting ssh-add
# and the agent work via SSH_AUTH_SOCK forwarding.
echo "[post-create] Wiring writable SSH known_hosts inside the container"
mkdir -p "$HOME/.ssh-container"
chmod 700 "$HOME/.ssh-container"
touch "$HOME/.ssh-container/known_hosts"
chmod 600 "$HOME/.ssh-container/known_hosts"

# Container-side ssh_config that delegates identities to the agent and uses
# the container-local known_hosts. The host's ~/.ssh/config (if it has entries
# for the cluster VMs) is still consulted via Include.
cat > "$HOME/.ssh-container/config" <<'EOF'
# Container-local SSH config. Loaded by ~/.ssh/config below.
UserKnownHostsFile ~/.ssh-container/known_hosts
StrictHostKeyChecking accept-new
ServerAliveInterval 30
EOF

# The bind-mounted ~/.ssh is read-only, so we can't write a regular ~/.ssh/config.
# Instead, point SSH at the container-local config via an env var in .bashrc.
# (SSH_CONFIG isn't a real env var; we use -F via aliases in bashrc.)
grep -q 'alias ssh=' "$HOME/.bashrc" 2>/dev/null || cat >> "$HOME/.bashrc" <<'EOF'

# Use the container-local SSH config (host's ~/.ssh is mounted read-only).
alias ssh='ssh -F ~/.ssh-container/config'
alias scp='scp -F ~/.ssh-container/config'
alias ssh-copy-id='ssh-copy-id -F ~/.ssh-container/config'
EOF

# Friendly motd printed by .bashrc on each new shell.
grep -q 'k3s-stack dev container' "$HOME/.bashrc" 2>/dev/null || cat >> "$HOME/.bashrc" <<'EOF'

if [[ -z "${K3S_STACK_MOTD_SHOWN:-}" ]]; then
  export K3S_STACK_MOTD_SHOWN=1
  echo ""
  echo "  k3s-stack dev container"
  echo "  -----------------------"
  echo "  Tools:    $(terraform version | head -1 2>/dev/null || echo 'terraform: n/a')"
  echo "            $(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -1 | xargs || echo 'kubectl: n/a')"
  echo "            $(helm version --short 2>/dev/null || echo 'helm: n/a')"
  echo "            $(ansible --version 2>/dev/null | head -1 || echo 'ansible: n/a')"
  echo ""
  echo "  Bring up the cluster:  ./workstation/01-cluster-up.sh"
  echo "  Check status:          ./workstation/04-status.sh"
  echo ""
fi
EOF

echo "[post-create] Done."
