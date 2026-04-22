#!/usr/bin/env bash
# Run terraform init + apply non-interactively.
# Reuses local terraform state if present.
#
# NAT gateway, Data Transfer endpoints and transfer are all managed by
# Terraform — no out-of-band setup scripts needed.
#
# Use scripts/cleanup.sh first if you want a clean slate.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

require_bin terraform

"$SCRIPT_DIR/prepare.sh"

# YC IAM tokens expire after ~12h — refresh before each terraform call
# so long-running apply doesn't die mid-way.
hdr "Refreshing YC IAM token"
refresh_yc_token

hdr "Terraform CLI config"
ensure_tf_cli_config

hdr "Terraform init"
terraform -chdir="$TF_DIR" init -input=false

hdr "Terraform plan"
refresh_yc_token
terraform -chdir="$TF_DIR" plan -input=false -out=tfplan

if ! confirm "Apply this plan?"; then
  warn "Aborted."
  rm -f "$TF_DIR/tfplan"
  exit 1
fi

hdr "Terraform apply (~15 min for ClickHouse cluster)"
refresh_yc_token
terraform -chdir="$TF_DIR" apply -input=false tfplan
rm -f "$TF_DIR/tfplan"

hdr "Outputs"
terraform -chdir="$TF_DIR" output

ok "Deploy complete.  Transfer is activated and snapshot loaded — run scripts/smoke.sh to verify the pipeline."
