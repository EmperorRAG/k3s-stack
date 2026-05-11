#!/usr/bin/env bash
#
# Refactor the k3s-stack repo to reflect the team's actual policy:
#
#   - Azure DevOps repos are used for git hosting only.
#   - All other cloud services remain out of scope (no Azure Storage, no
#     Azure Pipelines, no Azure-anything-else; same for AWS / GCP).
#   - Terraform state backend stays on self-hosted options.
#
# This script is run after refactor-no-cloud.sh (which generalised everything
# to "self-hosted"). It restores the Azure DevOps repo-hosting plan while
# keeping the self-hosted state-backend section intact.
#
# Idempotent. Refuses dirty trees.

set -euo pipefail

# ---------- safety ----------

if [[ ! -f README.md || ! -d docs || ! -d terraform ]]; then
  echo "ERROR: run this from the k3s-stack repo root."
  exit 1
fi

if [[ -d .git ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree has uncommitted changes."
    echo "Commit or stash them first so this refactor is reviewable as a single diff."
    exit 1
  fi
fi

echo "[azdo-only] Pre-flight passed."
echo

# ==================================================================
# 1. docs/REPO-HOSTING.md — restore the Azure DevOps repo-hosting plan
# ==================================================================

echo "[azdo-only] Rewriting docs/REPO-HOSTING.md (Azure DevOps for git only)"

cat > docs/REPO-HOSTING.md <<'MD'
# Repository Hosting: GitHub Now → Azure DevOps Later

The team's production source of truth for private repositories is **Azure DevOps repos**. The k3s-stack repo currently lives on **private GitHub** for the POC phase, with the explicit plan to migrate to Azure DevOps once the stack is stable.

## Scope of Azure DevOps usage

Azure DevOps offers many services (Boards, Pipelines, Artifacts, Test Plans) bundled with its git hosting. **The team uses Azure DevOps for git hosting only.** The other services are intentionally out of scope:

- **CI/CD: Jenkins** (runs in-cluster, see the main runbook). Azure Pipelines is not used.
- **Artifacts (container images, Helm charts, packages):** in-cluster registry once the cluster supports it; not Azure Artifacts.
- **Work tracking:** whatever the team already uses; not Azure Boards.
- **Test management:** none required by this repo.

The reason for this narrow scope: the team's broader policy is to avoid commercial cloud services for production infrastructure. Repo hosting is the one exception, because (1) the team is already using Azure DevOps repos for other private repositories, and (2) git hosting is a low-coupling service — a repo is portable to any git host with `git remote set-url`, so the lock-in cost is genuinely low.

State, secrets, build artifacts, container images, and runtime workloads all stay on self-hosted infrastructure. See `docs/TERRAFORM.md` for the state-backend options and `docs/SECRETS.md` for the secrets-management plan.

## Why GitHub for now

- Faster onboarding (no Azure DevOps project/permission setup needed during the experimentation phase).
- The team is more familiar with GitHub's web UI for ad-hoc browsing and PRs during early iteration.

## What needs to change to move to Azure DevOps

As of v2 (Terraform-based), no script fetches from the repo URL during cluster bring-up — Terraform reads the repo's `keys/authorized_keys` file from the local working copy. So the GitHub→AzDO migration is now purely a documentation update.

Files to update when moving to Azure DevOps:

1. **`README.md`** — any URLs in the Procedure or examples.
2. **`docs/REPO-HOSTING.md`** — this file (update its own examples).
3. **Anywhere the repo URL appears in a comment** (e.g., the `# Repository:` header in workstation scripts).
4. **Operator git remotes** — each operator runs `git remote set-url origin https://dev.azure.com/<org>/<project>/_git/k3s-stack`.

After updating those, push to Azure DevOps. The rest of the repo is hosting-agnostic — Terraform, Ansible, Helm, and the scripts all work with the repo files on the local filesystem only.

## The Azure DevOps raw-file URL pattern

GitHub gives you:
```
https://raw.githubusercontent.com/<user>/<repo>/<branch>/<path>
```

Azure DevOps gives you:
```
https://dev.azure.com/<org>/<project>/_apis/git/repositories/<repo>/items?path=<path>&api-version=7.1&download=true
```

For a private Azure DevOps repo, the request must carry a Personal Access Token (PAT). The cleanest way is to encode it as basic auth:
```
curl -fsSL -u :<PAT> "https://dev.azure.com/<org>/<project>/_apis/git/repositories/<repo>/items?path=/keys/authorized_keys&api-version=7.1&download=true"
```

Note the colon before `<PAT>` — Azure DevOps wants the PAT as the password with an empty username.

## Authentication for the migration

Two reasonable patterns:

- **SSH keys.** Azure DevOps supports SSH for `git push/pull`. Each operator uploads their public key under their Azure DevOps profile. The key is then identical to the one already in `keys/authorized_keys` for SSH to the cluster VMs.
- **Personal Access Tokens (PATs).** Required for HTTPS-based git access and for the REST API. Scoped to `Code (read)` (or `Code (read & write)` for committing). Rotate on a schedule the team agrees on.

The team's existing pattern for other Azure DevOps repositories carries over directly here.

## During the GitHub phase: handling private repos

While the repo is on private GitHub, fetches require a GitHub PAT:

```bash
curl -fsSL -H "Authorization: token $GITHUB_PAT" \
  "https://raw.githubusercontent.com/<user>/<repo>/main/keys/authorized_keys"
```

If the repo is briefly *public* during POC (which some teams do), the URLs work with no auth at all — but that means the repo's contents (including the encrypted vault file and the vault passphrase) are world-readable. The vault passphrase being in-repo is a deliberate trade-off for the POC phase only (see `SECRETS.md`); during any public phase, set the passphrase to something specific to this throwaway environment and rotate it before going private or moving to Azure DevOps.
MD

# ==================================================================
# 2. docs/TERRAFORM.md — keep state backend self-hosted; refresh framing
# ==================================================================

echo "[azdo-only] Updating docs/TERRAFORM.md (state-backend framing)"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("docs/TERRAFORM.md")
content = p.read_text()

new_state_section = """## State

The repo uses **local state** (`terraform/terraform.tfstate`, gitignored). This is fine for a single operator on a single workstation, and consistent with the rest of the POC's "simple now, hardened later" posture.

When the time comes to move to multi-operator use, the state needs to live somewhere shared. Azure DevOps is the team's choice for git hosting, but the team's broader policy keeps infrastructure services (storage, databases, secret stores) on self-hosted infrastructure. That means state lives on the cluster itself or on a small dedicated VM, not on a commercial cloud storage service.

Three self-hosted options exist, in order of preference:

| Backend | Hosts where | Notes |
|---|---|---|
| **`pg` against in-cluster PostgreSQL** | A Postgres Pod on k3s | Strongest locking semantics (row-level locks via Postgres advisory locks). Postgres is the most likely shared service to appear on the cluster regardless — once it's there for any project app, it's the natural place for Terraform state. Recommended. |
| **`http` against a small state server** | A `terraform-state-server` Pod on k3s, or any HTTP-backend-compatible service | Simple, single-purpose service. Native locking. Choose this if a Postgres dependency feels too heavy for state alone. |
| **`s3` against in-cluster MinIO** | A MinIO Pod on k3s | Works if the team already wants S3-compatible object storage on-cluster for other reasons. Locking on the s3 backend requires a separate DynamoDB-compatible service or a tolerance for unlocked state — more moving parts than the alternatives. |

The migration to remote state is a single configuration block change in `versions.tf` plus one `terraform init -migrate-state` invocation. It does not require rewriting anything else. The choice between the three backends can be deferred until the migration is actually scheduled.

### Example: `pg` backend block

```hcl
terraform {
  backend "pg" {
    conn_str    = "postgres://terraform@postgres.k3s.lan/terraform_state?sslmode=verify-full"
    schema_name = "k3s_stack"
  }
}
```

The password is supplied at runtime via `PGPASSWORD`, set by `workstation/01-cluster-up.sh` from Ansible Vault — the same pattern already used for the Proxmox API token. State is encrypted at rest by whatever encryption Postgres is configured for; TLS in transit comes from the cluster's internal CA.

### Why not Azure Storage / Blob backend

The Azure DevOps repo hosting is the only commercial cloud service in scope. Storage, databases, KMS, and other infrastructure services remain self-hosted. The Terraform Azure backends (`azurerm` storage account, etc.) are not used."""

content = re.sub(
    r"## State\n.*?(?=^## |\Z)",
    new_state_section + "\n\n",
    content,
    count=1,
    flags=re.DOTALL | re.MULTILINE,
)
p.write_text(content)
print("    TERRAFORM.md updated")
PY

# ==================================================================
# 3. terraform/versions.tf — backend comment
# ==================================================================

echo "[azdo-only] Updating terraform/versions.tf comment"

sed -i 's|migrate to a self-hosted backend (Forgejo HTTP, in-cluster Postgres, or MinIO) — see docs/TERRAFORM.md.|migrate to a self-hosted backend (in-cluster Postgres, in-cluster HTTP state server, or in-cluster MinIO) — see docs/TERRAFORM.md.|' terraform/versions.tf

# ==================================================================
# 4. docs/SECRETS.md — fix the parenthetical
# ==================================================================

echo "[azdo-only] Updating docs/SECRETS.md (Azure DevOps reference)"

python3 - <<'PY'
from pathlib import Path
p = Path("docs/SECRETS.md")
c = p.read_text()

# Restore the Azure DevOps reference for the repo (it's where the repo will live).
c = c.replace(
    "(GitHub private, later self-hosted Forgejo private)",
    "(GitHub private, later Azure DevOps private)",
)

# Leave the HashiCorp Vault future-state bullet about auto-unseal as it is —
# the self-hosted-Vault future state is independent of the repo hosting.

p.write_text(c)
print("    SECRETS.md updated")
PY

# ==================================================================
# 5. README.md — update repo-layout description
# ==================================================================

echo "[azdo-only] Updating README.md (repo-layout description)"

sed -i 's|REPO-HOSTING.md                # GitHub → self-hosted Forgejo migration|REPO-HOSTING.md                # GitHub → Azure DevOps migration|' README.md

# ==================================================================
# 6. Validate
# ==================================================================

echo
echo "[azdo-only] Validating outputs"

echo "  - bash -n on workstation/*.sh"
for s in workstation/*.sh; do
  bash -n "$s" || { echo "FAIL: $s"; exit 1; }
done

echo "  - YAML parse on all *.yml and *.yaml"
python3 - <<'PY'
import yaml, glob, sys
errors = 0
for path in glob.glob('**/*.yml', recursive=True) + glob.glob('**/*.yaml', recursive=True):
    if 'secrets/vault.yml' in path or '.tftpl' in path:
        continue
    try:
        with open(path) as f:
            list(yaml.safe_load_all(f))
    except Exception as e:
        print(f"FAIL {path}: {e}")
        errors += 1
sys.exit(errors)
PY

echo "  - residual Forgejo references (should be empty)"
RESIDUAL=$(grep -rin 'forgejo\|gitea' --exclude-dir=.git . 2>/dev/null || true)
if [[ -n "$RESIDUAL" ]]; then
  echo "WARN: residual self-hosted-Git references found:"
  echo "$RESIDUAL"
fi

echo "  - residual cloud-infra references (should be in 'Why not...' contexts only)"
RESIDUAL_INFRA=$(grep -rin -e 'azure storage' -e 'azurerm' -e 'azure blob' \
  -e 'aws s3' -e 'amazon s3' -e 'google cloud storage' \
  --exclude-dir=.git . 2>/dev/null || true)

# Ignore the intentional "Why not Azure Storage / Blob backend" section in TERRAFORM.md
# which documents what is deliberately NOT used.
RESIDUAL_INFRA_FILTERED=$(echo "$RESIDUAL_INFRA" \
  | grep -v 'TERRAFORM.md.*Why not Azure Storage' \
  | grep -v 'TERRAFORM.md.*Azure DevOps repo hosting is the only commercial cloud service' \
  | grep -v 'TERRAFORM.md.*Terraform Azure backends.*are not used' \
  || true)

if [[ -n "$RESIDUAL_INFRA_FILTERED" ]]; then
  echo "WARN: residual cloud-infra references found (excluding intentional 'Why not...' docs):"
  echo "$RESIDUAL_INFRA_FILTERED"
fi

echo
echo "[azdo-only] Done."
echo
if [[ -d .git ]]; then
  echo "Files changed:"
  git status --short
  echo
fi
cat <<'NEXT'
Next steps:

  1. Review:           git diff && git status
  2. Commit:           git add -A && git commit -m 'Restore Azure DevOps repo hosting; keep state self-hosted'
NEXT
