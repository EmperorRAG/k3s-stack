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
