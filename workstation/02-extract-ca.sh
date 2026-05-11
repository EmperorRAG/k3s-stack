#!/usr/bin/env bash
#
# Extract the cluster's internal CA certificate to the repo root.
# Distribute it to operators' workstations and import into their trust stores
# (see docs/CA-TRUST.md).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="$REPO_ROOT/cluster-internal-ca.crt"

echo "[extract-ca] Fetching internal CA cert from k3s-node-server-3011"

# Use SSH to run kubectl on the orchestrator (which has the kubeconfig).
ssh mark@10.0.40.111 \
  'sudo /usr/local/bin/k3s kubectl -n cert-manager get secret cluster-internal-ca-secret -o jsonpath="{.data.ca\.crt}"' \
  | base64 -d > "$OUT_FILE"

if [[ ! -s "$OUT_FILE" ]]; then
  echo "ERROR: extracted CA cert is empty. Is cert-manager + the CA issuer installed?"
  rm -f "$OUT_FILE"
  exit 1
fi

echo "[extract-ca] Wrote $OUT_FILE"
echo "[extract-ca] Subject:"
openssl x509 -in "$OUT_FILE" -noout -subject
echo "[extract-ca] Next: see docs/CA-TRUST.md to import into your trust store."
