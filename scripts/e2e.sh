#!/usr/bin/env bash
# Full end-to-end run from a clean folder:
#   1. cleanup    — delete every project resource (manual or terraform-made)
#   2. deploy     — terraform apply (preflight runs prepare.sh inside)
#   3. transfer   — create + activate Data Transfer (CLI fallback)
#   4. smoke      — invoke function + verify pipeline tables + 4 models
#
# Set ASSUME_YES=1 to skip confirmations.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

start=$(date +%s)

hdr "STAGE 1/4 — cleanup"
"$SCRIPT_DIR/cleanup.sh"

hdr "STAGE 2/4 — deploy"
"$SCRIPT_DIR/deploy.sh"

hdr "STAGE 3/4 — data transfer"
"$SCRIPT_DIR/transfer.sh"

hdr "STAGE 4/4 — smoke test"
"$SCRIPT_DIR/smoke.sh"

end=$(date +%s)
ok "End-to-end run finished in $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s"
