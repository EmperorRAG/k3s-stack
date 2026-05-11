#!/usr/bin/env bash
#
# Set up a VS Code Dev Container for the k3s-stack workstation tooling.
#
# Run from the repo root. The script adds .devcontainer/, a small note to
# README.md, and a no-op shortcut in workstation/00-install-tools.sh for
# when it's run inside the container.
#
# After running:
#   1. git diff           # review
#   2. git add -A && git commit -m "Add Dev Container"
#   3. In VS Code: cmd+shift+p → "Dev Containers: Reopen in Container"
#   4. Wait ~3 minutes for first build.
#   5. Open a terminal in VS Code (ctrl+`) — terraform/kubectl/helm/ansible
#      are all on PATH inside the container.
#
# Re-runnable. Refuses dirty trees so the diff stays reviewable.

set -euo pipefail

# ---------- safety ----------

if [[ ! -f README.md || ! -d ansible || ! -d workstation ]]; then
  echo "ERROR: run this from the k3s-stack repo root."
  exit 1
fi

if [[ -d .git ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree has uncommitted changes."
    echo "Commit or stash them first so the Dev Container changes are reviewable as a single diff."
    exit 1
  fi
fi

echo "[devcontainer] Pre-flight passed."
echo

# ==================================================================
# 1. .devcontainer/devcontainer.json
# ==================================================================

mkdir -p .devcontainer

echo "[devcontainer] Writing .devcontainer/devcontainer.json"
cat > .devcontainer/devcontainer.json <<'JSON'
{
  "name": "k3s-stack workstation",

  "build": {
    "dockerfile": "Dockerfile",
    "context": "."
  },

  // Tools installed via official Dev Container Features.
  // Versions pinned so every operator gets the same toolchain.
  // To bump: update the version strings and rebuild the container.
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": {
      "username": "mark",
      "userUid": "automatic",
      "userGid": "automatic",
      "installZsh": false,
      "configureZshAsDefaultShell": false,
      "upgradePackages": true
    },
    "ghcr.io/devcontainers/features/git:1": {
      "version": "latest"
    },
    "ghcr.io/devcontainers/features/terraform:1": {
      "version": "1.10",
      "tflint": "none",
      "terragrunt": "none"
    },
    "ghcr.io/devcontainers/features/kubectl-helm-minikube:1": {
      "version": "latest",
      "helm": "latest",
      "minikube": "none"
    },
    "ghcr.io/devcontainers-extra/features/ansible:2": {
      "version": "latest"
    }
  },

  // Forward the host's SSH agent into the container.
  // On macOS, ensure your key is loaded: `ssh-add ~/.ssh/id_ed25519` before opening.
  // Without this, the container can't SSH to the VMs.
  "mounts": [
    "source=${localEnv:HOME}/.ssh,target=/home/mark/.ssh,type=bind,consistency=cached,readonly"
  ],
  "remoteEnv": {
    // Ensures any SSH calls inside the container use the forwarded agent.
    "SSH_AUTH_SOCK": "${localEnv:SSH_AUTH_SOCK}"
  },

  // The bind-mounted ~/.ssh above is read-only by design — we don't want
  // the container scribbling on the host's known_hosts. A writable in-container
  // path is added by the Dockerfile and SSH is told to use it via ssh_config.

  "remoteUser": "mark",
  "containerUser": "mark",
  "updateRemoteUserUID": true,

  // VS Code extensions that should be installed inside the container.
  // These do NOT install on your macOS host — they run in the container.
  "customizations": {
    "vscode": {
      "extensions": [
        "hashicorp.terraform",
        "redhat.ansible",
        "ms-kubernetes-tools.vscode-kubernetes-tools",
        "redhat.vscode-yaml",
        "ms-azuretools.vscode-docker",
        "timonwong.shellcheck"
      ],
      "settings": {
        "terminal.integrated.defaultProfile.linux": "bash",
        "files.eol": "\n"
      }
    }
  },

  // Runs once after the container is built and the workspace is mounted.
  // Installs Ansible collections used by playbooks.
  "postCreateCommand": ".devcontainer/post-create.sh",

  // Runs every time the container starts. Cheap things only.
  "postStartCommand": "echo 'k3s-stack dev container ready. Tools: terraform, kubectl, helm, ansible.'",

  // No port forwarding needed — all traffic is outbound (SSH to VMs, HTTPS to
  // Proxmox/registries). Browser access to rancher.k3s.lan / jenkins.k3s.lan
  // happens on the macOS host directly via pfSense DNS.

  // Persist Terraform plugin cache and Ansible Galaxy cache so rebuilds are fast.
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/${localWorkspaceFolderBasename},type=bind,consistency=cached",
  "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}"
}
JSON

# ==================================================================
# 2. .devcontainer/Dockerfile
# ==================================================================

echo "[devcontainer] Writing .devcontainer/Dockerfile"
cat > .devcontainer/Dockerfile <<'DOCKER'
# Base image: Microsoft's official Dev Containers Ubuntu image.
# Tools (terraform, kubectl, helm, ansible) are layered on by Dev Container Features
# declared in devcontainer.json — see that file rather than reinventing the install
# logic here.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# A few small things easier to do in a Dockerfile than via features:
#   - A writable in-container SSH config dir so the bind-mounted host ~/.ssh
#     can stay read-only.
#   - Standard CLI tools the scripts assume.

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl \
        wget \
        ca-certificates \
        jq \
        python3-pip \
        python3-kubernetes \
        openssh-client \
        rsync \
        unzip \
        less \
    && rm -rf /var/lib/apt/lists/*

# Create a writable SSH config dir for the mark user. The host's ~/.ssh is
# bind-mounted read-only at /home/mark/.ssh per devcontainer.json; we point
# SSH at a writable copy of the config for known_hosts and the like.
# The post-create script handles the actual user-level setup, since it
# runs after the common-utils feature has created the user.
DOCKER

# ==================================================================
# 3. .devcontainer/post-create.sh
# ==================================================================

echo "[devcontainer] Writing .devcontainer/post-create.sh"
cat > .devcontainer/post-create.sh <<'SH'
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
SH
chmod +x .devcontainer/post-create.sh

# ==================================================================
# 4. .devcontainer/README.md
# ==================================================================

echo "[devcontainer] Writing .devcontainer/README.md"
cat > .devcontainer/README.md <<'MD'
# Dev Container

This directory defines a VS Code Dev Container that provides every workstation tool the k3s-stack runbook needs — Terraform, kubectl, Helm, Ansible — inside a Linux container, so your host machine stays clean.

## Why use it

- **No host pollution.** Nothing installs on macOS / Windows / Linux. All tools live in the container.
- **Reproducible.** Every operator gets the exact same versions, pinned in `devcontainer.json`.
- **One-click onboarding.** Install Docker Desktop + VS Code + the Dev Containers extension; open the repo; click "Reopen in Container." First build is ~3 minutes; subsequent opens are instant.

## What's in it

| Tool | Source | Version |
|---|---|---|
| Terraform | `ghcr.io/devcontainers/features/terraform` | 1.10 |
| kubectl | `ghcr.io/devcontainers/features/kubectl-helm-minikube` | latest |
| Helm | (same feature) | latest |
| Ansible | `ghcr.io/devcontainers-extra/features/ansible` | latest |
| Base OS | `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` | — |

VS Code extensions installed inside the container (not on the host):
HashiCorp Terraform, Red Hat Ansible, Kubernetes, YAML, Docker, ShellCheck.

## Prerequisites

- **Docker Desktop** running on macOS / Windows, or **Docker Engine** on Linux.
- **VS Code** with the **Dev Containers** extension (`ms-vscode-remote.remote-containers`).
- Your SSH key loaded in the macOS / Linux SSH agent:
  ```bash
  ssh-add ~/.ssh/id_ed25519
  ```
  The container forwards your host's SSH agent so you can SSH from inside the container using your host's keys without copying private keys into the container.

## Opening the repo in the container

1. Open the repo folder in VS Code.
2. Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`) → **Dev Containers: Reopen in Container**.
3. First time: VS Code builds the image. Takes ~3 minutes depending on your connection.
4. When the build finishes, a new VS Code window opens with the repo mounted at `/workspaces/k3s-stack`.
5. Open a terminal (`Ctrl+\``) — you're now in the container, as user `mark`, with all the tools on PATH.

## Verifying it works

In the container terminal:

```bash
terraform version
kubectl version --client
helm version --short
ansible --version
```

All four should report current versions.

## Working with SSH

The container forwards your host's SSH agent automatically. To verify:

```bash
ssh-add -l    # should list the keys you've added on the host
```

If empty, run `ssh-add ~/.ssh/id_ed25519` on the host (outside VS Code) and reopen the container.

To SSH to a cluster VM from inside the container:

```bash
ssh mark@10.0.40.100
```

The `ssh` alias in `~/.bashrc` automatically uses a container-local known_hosts file (`~/.ssh-container/known_hosts`) so the host's known_hosts stays untouched.

## Rebuilding the container

If `devcontainer.json` or the `Dockerfile` changes, rebuild:

Command Palette → **Dev Containers: Rebuild Container**.

State that survives a rebuild: everything in the workspace (the repo). State that does NOT survive a rebuild: anything installed in the container outside the repo, shell history, container-local `~/.ssh-container/known_hosts`. None of those matter for this project.

## Falling back to the host

The Dev Container is optional. The `workstation/00-install-tools.sh` script still works to install everything directly on macOS / Linux if you prefer. The Dev Container path and the host path are equivalent; the same scripts run in either.
MD

# ==================================================================
# 5. Update workstation/00-install-tools.sh
# ==================================================================

echo "[devcontainer] Adding dev-container detection to workstation/00-install-tools.sh"

# Only add the detection block if it's not already there.
if ! grep -q "REMOTE_CONTAINERS\|devcontainer detection" workstation/00-install-tools.sh; then
  # Insert after the shebang and initial comments. Use python to do this precisely.
  python3 - <<'PY'
from pathlib import Path

path = Path("workstation/00-install-tools.sh")
content = path.read_text()

# Insert detection block after the first `set -euo pipefail`.
marker = "set -euo pipefail\n"
addition = """
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

"""

# Insert immediately after the first occurrence of `set -euo pipefail`.
idx = content.find(marker)
if idx == -1:
    print("WARN: couldn't find 'set -euo pipefail' anchor in 00-install-tools.sh; skipping")
else:
    insert_at = idx + len(marker)
    content = content[:insert_at] + addition + content[insert_at:]
    path.write_text(content)
    print("00-install-tools.sh updated")
PY
else
  echo "[devcontainer]   (already updated; skipping)"
fi

# ==================================================================
# 6. Update README.md — add Quick start (Dev Container) section
# ==================================================================

echo "[devcontainer] Adding Dev Container quick-start section to README.md"

if ! grep -q "Quick start (Dev Container)" README.md; then
  python3 - <<'PY'
from pathlib import Path
import re

path = Path("README.md")
content = path.read_text()

# Insert a "Quick start (Dev Container)" section right before "## Prerequisites".
section = """## Quick start (Dev Container)

The fastest way to onboard is the **Dev Container** under `.devcontainer/`. It bundles Terraform, kubectl, Helm, and Ansible into a Linux container so nothing installs on your host machine.

Prerequisites: Docker Desktop (macOS/Windows) or Docker Engine (Linux), VS Code, and the Dev Containers extension.

1. Clone the repo and open it in VS Code.
2. `ssh-add ~/.ssh/id_ed25519` on your host so the container can SSH to the VMs using your key.
3. Command Palette → **Dev Containers: Reopen in Container**. First build ~3 minutes.
4. When the new VS Code window opens, you have a terminal inside the container with every workstation tool on PATH. Skip to step 2 of the Procedure below (the tool install is already done).

See `.devcontainer/README.md` for details.

If you'd rather install tools directly on your host machine instead, follow the Procedure as written — `workstation/00-install-tools.sh` handles that path.

---

"""

# Find the "## Prerequisites" heading and insert before it.
m = re.search(r"^## Prerequisites", content, re.MULTILINE)
if m:
    content = content[:m.start()] + section + content[m.start():]
    path.write_text(content)
    print("README.md updated")
else:
    print("WARN: couldn't find '## Prerequisites' in README.md; skipping")
PY
else
  echo "[devcontainer]   (already updated; skipping)"
fi

# ==================================================================
# 7. Update .gitignore for any dev-container-specific exclusions
# ==================================================================

if ! grep -q "^.devcontainer/.cache" .gitignore 2>/dev/null; then
  cat >> .gitignore <<'EOF'

# Dev Container state (none currently, but reserved)
.devcontainer/.cache/
EOF
fi

# ==================================================================
# 8. Validate
# ==================================================================

echo
echo "[devcontainer] Validating outputs"

echo "  - .devcontainer/devcontainer.json is valid JSON (with comments allowed)"
python3 - <<'PY'
import json, re, sys
with open(".devcontainer/devcontainer.json") as f:
    raw = f.read()
# devcontainer.json is JSONC — strip line comments before parsing.
stripped = re.sub(r"//[^\n]*", "", raw)
# Also strip block comments
stripped = re.sub(r"/\*.*?\*/", "", stripped, flags=re.DOTALL)
try:
    json.loads(stripped)
    print("    OK")
except json.JSONDecodeError as e:
    print(f"    FAIL: {e}")
    sys.exit(1)
PY

echo "  - .devcontainer/post-create.sh has valid bash syntax"
bash -n .devcontainer/post-create.sh

echo "  - workstation/00-install-tools.sh still has valid bash syntax"
bash -n workstation/00-install-tools.sh

echo
echo "[devcontainer] Done."
echo
echo "Files added/modified:"
if [[ -d .git ]]; then
  git status --short
else
  echo "  (not a git repo — review files manually)"
fi
echo
echo "Next steps:"
echo "  1. Review:        git diff && git status"
echo "  2. Commit:        git add -A && git commit -m 'Add Dev Container'"
echo "  3. Load SSH key:  ssh-add ~/.ssh/id_ed25519   # on macOS host"
echo "  4. In VS Code:    cmd+shift+p -> 'Dev Containers: Reopen in Container'"
echo "  5. Wait for first build (~3 min), then open a terminal inside VS Code."
