# Trusting the Cluster's Internal CA

After running `./workstation/02-extract-ca.sh`, you have `cluster-internal-ca.crt` at the repo root. Distribute it to every operator's workstation and import it into the trust store. Once imported, `https://rancher.k3s.lan/` and `https://jenkins.k3s.lan/` load with valid TLS — no browser warnings.

This is a one-time step per workstation per CA. If the cluster is rebuilt (which regenerates the CA), re-extract and re-import.

## Linux

```bash
sudo cp cluster-internal-ca.crt /usr/local/share/ca-certificates/k3s-cluster-internal-ca.crt
sudo update-ca-certificates
```

Then in Firefox specifically (Firefox uses its own trust store): Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import → select the file.

Chrome / Edge / Chromium on Linux use the system trust store automatically after `update-ca-certificates`.

## macOS

Double-click `cluster-internal-ca.crt`. The Keychain Access app opens.

1. The cert lands in your login keychain. Drag it to the **System** keychain.
2. Find the certificate (named `k3s-cluster-internal-ca`), double-click it.
3. Expand "Trust", set "When using this certificate" to **Always Trust**.
4. Close the window. Authenticate when prompted.

Safari, Chrome, and Edge all honor the system trust store. Firefox needs its own import (Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import).

## Windows

1. Double-click `cluster-internal-ca.crt`. Click "Install Certificate..."
2. Store Location: **Local Machine** (requires admin).
3. Place all certificates in the following store: **Trusted Root Certification Authorities**.
4. Finish.

Edge and Chrome use the system trust store. Firefox needs its own import.

## On the VMs themselves

If you need to `curl https://rancher.k3s.lan/` from inside one of the cluster VMs (e.g., from a shell script or a Pod that doesn't have the cluster CA in its image), copy the cert into the system trust store:

```bash
scp cluster-internal-ca.crt mark@10.0.40.100:/tmp/
ssh mark@10.0.40.100 'sudo mv /tmp/cluster-internal-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates'
```

Repeat for each peer if needed.
