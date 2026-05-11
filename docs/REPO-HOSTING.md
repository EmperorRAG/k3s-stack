# Repository Hosting: GitHub Now → Azure DevOps Later

The team's production source of truth for private repositories is Azure DevOps. The k3s-stack repo currently lives on **private GitHub** for the POC phase, with the explicit plan to migrate to Azure DevOps once the stack is stable.

## Why GitHub for now

- Faster onboarding (no Azure DevOps project/permission setup needed during the experimentation phase).
- The `curl ... | sudo bash -s -- ...` pattern in `vm-bootstrap/bootstrap.sh` works trivially with `raw.githubusercontent.com` URLs.
- The team is more familiar with GitHub's web UI for ad-hoc browsing and PRs during early iteration.

## What needs to change to move to Azure DevOps

There are exactly two URLs in this repo that point at GitHub:

1. **`vm-bootstrap/bootstrap.sh`** — the `AUTHORIZED_KEYS_URL` default.
2. **`README.md`** — the example curl invocations in the Procedure section.

Update both, then push the changes to Azure DevOps. The rest of the repo is hosting-agnostic.

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
curl -fsSL -u :<PAT> "https://dev.azure.com/<org>/<project>/_apis/git/repositories/<repo>/items?path=/vm-bootstrap/bootstrap.sh&api-version=7.1&download=true"
```

Note the colon before `<PAT>` — Azure DevOps wants the PAT as the password with an empty username.

## Suggested bootstrap-script change for the Azure DevOps phase

When you move, update `bootstrap.sh` to accept the PAT via an environment variable so the URL stays out of `git log`:

```bash
# AUTHORIZED_KEYS_URL becomes:
AUTHORIZED_KEYS_URL="${AUTHORIZED_KEYS_URL:-https://dev.azure.com/<org>/<project>/_apis/git/repositories/k3s-stack/items?path=/keys/authorized_keys&api-version=7.1&download=true}"
AZDO_PAT="${AZDO_PAT:-}"

# Replace the curl invocation with:
if [[ -n "$AZDO_PAT" ]]; then
  curl -fsSL -u ":$AZDO_PAT" "$AUTHORIZED_KEYS_URL" -o "$TMP_KEYS"
else
  curl -fsSL "$AUTHORIZED_KEYS_URL" -o "$TMP_KEYS"
fi
```

The operator then runs the Proxmox-console one-liner with the PAT inline:
```bash
curl -fsSL -u ":$AZDO_PAT" "https://dev.azure.com/<org>/<project>/_apis/git/repositories/k3s-stack/items?path=/vm-bootstrap/bootstrap.sh&api-version=7.1&download=true" \
  | AZDO_PAT="$AZDO_PAT" sudo -E bash -s -- k3s-orchestrator 10.0.40.100
```

A short PAT with `Code (Read)` scope, valid for the duration of cluster provisioning, is the right token to issue here. Revoke it after.

## During the GitHub phase: handling private repos

While the repo is on private GitHub, the `raw.githubusercontent.com` URLs require a PAT. The cleanest approach is the same pattern:

```bash
curl -fsSL -H "Authorization: token $GITHUB_PAT" "https://raw.githubusercontent.com/<user>/<repo>/main/vm-bootstrap/bootstrap.sh" | sudo bash -s -- k3s-orchestrator 10.0.40.100
```

If the repo is briefly *public* during POC (which some teams do), the URLs work with no auth at all. Easier but it does mean the repo's contents (including the encrypted vault file and the vault passphrase) are world-readable. The vault passphrase being in-repo is a deliberate trade-off for the POC phase only (see `SECRETS.md`); during a public phase, set the passphrase to something specific to this throwaway environment and rotate it before going private.
