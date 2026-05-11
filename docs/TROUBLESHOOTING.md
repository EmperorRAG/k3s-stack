# Troubleshooting

## VM Bootstrap

**`curl ... | sudo bash -s -- ...` in the Proxmox console returns "command not found" or 404.**
- Wrong repo URL. Check the `AUTHORIZED_KEYS_URL` default in `vm-bootstrap/bootstrap.sh`. The URL in the runbook README points to the *repo's* bootstrap file, not the auth keys.
- Private repo without a PAT. See `docs/REPO-HOSTING.md`.

**Bootstrap finishes but SSH from the workstation fails with "Permission denied (publickey)".**
- Your public key isn't in `keys/authorized_keys` in the repo, or you forgot to push the change before running the bootstrap.
- Add the key, commit, push, then re-run bootstrap on the VM (it's idempotent — safe to re-run).

**HTTPS in the bootstrap hangs at 0 bytes.**
- pfSense MSS clamping is broken or missing. See `docs/MTU-NOTE.md`.

## Cluster Bring-Up

**`ansible all -m ping` fails for one host with "Permission denied".**
- Public key not authorized. Did you commit + push `keys/authorized_keys`, and re-run bootstrap on that VM?
- Verify directly: `ssh mark@<ip>` from the workstation. If that fails, the bootstrap didn't install the key correctly.

**`01-cluster-up.sh` fails on the k3s install step with "context deadline exceeded".**
- `get.k3s.io` couldn't be reached, or the k3s binary couldn't be downloaded. Usually network. Check the VM has internet: `ssh mark@<ip> 'curl -v https://get.k3s.io/'`.

**`02-k3s-init.yml` waits forever on "Wait for kube-vip to claim the VIP".**
- The kube-vip manifest didn't auto-deploy. Check `ssh mark@10.0.40.100 'sudo /usr/local/bin/k3s kubectl -n kube-system get pods -l name=kube-vip-ds'`. If empty, check `sudo journalctl -u k3s | grep manifest`.
- The VIP is held by something else on the LAN. Check `ip addr` from another machine on the LAN for `10.0.40.99`.

**`03-k3s-join-servers.yml` fails — node joins but goes NotReady.**
- Token mismatch. Try teardown + rebuild: `./workstation/97-rebuild.sh`.
- etcd handshake problem. `ssh mark@<failing-ip> 'sudo journalctl -u k3s | tail -100'`.

**`04-cluster-workloads.yml` fails on the Rancher rollout.**
- Almost always cert-manager. Check: `ssh mark@10.0.40.100 'sudo /usr/local/bin/k3s kubectl get clusterissuer'` — `cluster-internal-ca` should be `READY=True`.
- Check Rancher pod logs: `ssh mark@10.0.40.100 'sudo /usr/local/bin/k3s kubectl -n cattle-system logs deploy/rancher'`.

## Day-Two Operations

**Browser shows "NET::ERR_CERT_AUTHORITY_INVALID" for `https://rancher.k3s.lan`.**
- The cluster CA isn't in your workstation's trust store. Run `./workstation/02-extract-ca.sh` and follow `docs/CA-TRUST.md`.

**`kubectl get nodes` from a VM fails with "no route to host" or "connection refused".**
- The VIP isn't bound. Run `./workstation/04-status.sh` to see where it is.

**`kubectl` fails with `x509: certificate is valid for ... not k3s-api.k3s.lan`.**
- The hostname isn't a TLS SAN on the API cert. The init/join playbooks should have set this via `--tls-san`. If you bypassed them or used a different hostname, you'll need to rebuild.

**Jenkins pod `Pending`.**
- Usually missing PV. Check `ssh mark@10.0.40.100 'sudo /usr/local/bin/k3s kubectl get pvc -n jenkins'` and `kubectl get storageclass` — `local-path` should be `(default)`.
- Note that `local-path` ties a PV to a specific node. If Jenkins's node dies, its PV is unreachable until the node returns. Real HA persistence needs Longhorn or NFS (later project).

**After failover, an old pod is stuck `Terminating`.**
- The pod's node is gone. Force delete: `kubectl delete pod <name> -n <ns> --grace-period=0 --force`.

**etcd quorum lost (cluster API unresponsive even with 1+ peers up).**
- Two peers down. Cluster needs 2-of-3 to write. Bring at least 2 servers back online. If a server is permanently lost, you'll need to follow the k3s docs for removing a failed etcd member.

**`ansible-vault edit ansible/secrets/vault.yml` fails with "Decryption failed".**
- The passphrase in `.k3s-stack-vault-pass` doesn't match what the file was encrypted with. If you just changed the passphrase, you'll need to re-encrypt the vault file with `ansible-vault rekey ansible/secrets/vault.yml` *using the old passphrase first*, then update `.k3s-stack-vault-pass`.

## VS Code Remote-SSH

VS Code Remote-SSH is supported but optional — you can do everything in this repo from a local terminal. If you want it:

**"Could not establish connection" with no specific error.**
- Add the host to your workstation's `~/.ssh/config` (use Command Palette → "Remote-SSH: Open SSH Configuration File...") with `HostName <ip>` and `User mark`.

**Bootstrap hangs at "Downloading VS Code Server".**
- HTTPS to `update.code.visualstudio.com` is hanging. Almost always MSS clamping (see `docs/MTU-NOTE.md`).

**Bootstrap fails fast with "wget: command not found".**
- The VM template should ship with `wget`. The bootstrap script reinstalls it anyway as a belt-and-braces measure. If you see this, the bootstrap didn't run (or didn't complete) on the VM — re-run it.
