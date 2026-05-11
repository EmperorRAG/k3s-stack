# Secrets

## Where we are: Ansible Vault, passphrase in-repo

The current setup uses **Ansible Vault** to encrypt the contents of `ansible/secrets/vault.yml`. The vault passphrase lives in `.k3s-stack-vault-pass` at the repo root, which is committed to the repo.

This is deliberate for the first version of the stack:

- **Simplicity.** No out-of-band passphrase distribution. Anyone with the repo can run the playbooks.
- **Speed to first working cluster.** No new service (HashiCorp Vault) to stand up before the cluster exists.
- **Familiar workflow.** Ansible Vault is built into Ansible. No new tooling for the team to learn while they're learning k3s.

The trade-off: **anyone with read access to the repo can decrypt the secrets.** That's acceptable because the repo is private (GitHub private, later Azure DevOps private) and the secrets it holds are bootstrap-grade — initial Rancher and Jenkins admin passwords that the operator changes on first login, and the k3s join token which is only useful inside the LAN.

## Where we're going: HashiCorp Vault

HashiCorp Vault is a separate running service that:

- Stores secrets behind a real authentication boundary (per-user / per-service tokens).
- Supports **dynamic secrets** (e.g., generates short-lived database credentials on demand).
- Has fine-grained ACLs (per-secret read/write policies).
- Provides an audit log of who decrypted what.
- Can integrate with cloud KMS for key wrapping.
- Has both cluster-infrastructure use cases (current Ansible Vault scope) **and** project-application use cases (apps fetch DB passwords, API keys, OAuth secrets at runtime instead of baking them into images or ConfigMaps).

The reason to move to HashiCorp Vault later, rather than stay on Ansible Vault forever:

- The current setup conflates "secrets needed to build the cluster" with "secrets at rest in git." Once project applications need secrets at runtime, Ansible Vault stops being the right tool for that part — Ansible runs at deploy time, not at request time.
- HashiCorp Vault gives both layers (infra + apps) a single source of truth.

## Migration plan (sketch)

This is the rough shape, not a runbook. The runbook will be written when migration is actually next on the priority list.

1. **Stand up Vault in the cluster.** Run Vault in HA mode (3 replicas with Raft storage) as a Helm chart deployment. Initialize and unseal.
2. **Move existing secrets.** Move the contents of `ansible/secrets/vault.yml` into Vault. Update playbooks to read them from Vault at runtime (via the `community.hashi_vault` Ansible collection) instead of via vars_files.
3. **Wire project applications to Vault.** Use the Vault Agent Injector or External Secrets Operator to make Vault secrets available as Kubernetes Secrets or mounted files inside Pods.
4. **Decommission Ansible Vault.** Once all secrets have moved, delete `ansible/secrets/vault.yml` and `.k3s-stack-vault-pass`. The repo no longer contains any secrets at all (encrypted or otherwise).

## What this means for now

- **Do edit `ansible/secrets/vault.yml`** with `ansible-vault edit ansible/secrets/vault.yml` and set real bootstrap passwords before running `01-cluster-up.sh`.
- **Don't put project-application secrets** (DB passwords, API keys) in Ansible Vault. Wait for HashiCorp Vault. In the meantime, Kubernetes Secrets created by `kubectl` directly are an acceptable interim measure for project apps — they aren't committed to git.
- **Do change `.k3s-stack-vault-pass`** from its placeholder value to something specific to your environment. It's still in the repo, but a unique passphrase per environment means a leaked repo from one environment doesn't compromise another.
