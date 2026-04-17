#!/usr/bin/env bash
# Full end-to-end run from a clean folder:
#   1. cleanup — delete every project resource (manual or terraform-made)
#   2. deploy  — terraform apply: creates NAT + DT endpoints + transfer,
#                synchronously activates SNAPSHOT_ONLY transfer to completion
#   3. smoke   — invoke function + verify pipeline tables + 4 models
#
# Set ASSUME_YES=1 to skip confirmations.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

start=$(date +%s)

hdr "STAGE 1/3 — cleanup"
"$SCRIPT_DIR/cleanup.sh"

hdr "STAGE 2/3 — deploy (terraform apply, includes transfer snapshot)"
"$SCRIPT_DIR/deploy.sh"

hdr "STAGE 3/3 — smoke test"
"$SCRIPT_DIR/smoke.sh"

end=$(date +%s)
ok "End-to-end run finished in $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s"
