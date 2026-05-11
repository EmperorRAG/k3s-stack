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
