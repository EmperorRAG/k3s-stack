#!/usr/bin/env bash
#
# Rebuild the cluster from scratch. Equivalent to:
#   ./workstation/98-teardown.sh
#   ./workstation/01-cluster-up.sh
#
# Use after major topology changes, or when troubleshooting requires a clean slate.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$REPO_ROOT/workstation/98-teardown.sh"
echo
echo "[rebuild] Teardown complete. Building fresh cluster..."
echo
"$REPO_ROOT/workstation/01-cluster-up.sh"
