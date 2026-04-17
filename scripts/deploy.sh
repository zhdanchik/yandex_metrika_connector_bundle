#!/usr/bin/env bash
# Run terraform init + apply non-interactively.
# Reuses local terraform state if present.
#
# Use scripts/cleanup.sh first if you want a clean slate.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

require_bin terraform

"$SCRIPT_DIR/prepare.sh"

hdr "Terraform init"
terraform -chdir="$TF_DIR" init -input=false

hdr "Terraform plan"
terraform -chdir="$TF_DIR" plan -input=false -out=tfplan

if ! confirm "Apply this plan?"; then
  warn "Aborted."
  rm -f "$TF_DIR/tfplan"
  exit 1
fi

hdr "Terraform apply (~15 min for ClickHouse cluster)"
terraform -chdir="$TF_DIR" apply -input=false tfplan
rm -f "$TF_DIR/tfplan"

hdr "Outputs"
terraform -chdir="$TF_DIR" output

ok "Deploy complete.  Next: scripts/transfer.sh to create+activate Data Transfer."
