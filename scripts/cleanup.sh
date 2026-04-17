#!/usr/bin/env bash
# Wipe ALL Yandex Cloud resources in the configured folder that match the
# project name prefix (default: "metrika-attribution"), so a re-deploy
# starts from a clean slate.
#
# Picks up resources whether they were created via Terraform OR by hand.
# Also clears local Terraform state.
#
# Usage:
#   ASSUME_YES=1 ./scripts/cleanup.sh           # non-interactive
#   ./scripts/cleanup.sh                        # asks for confirmation
#   PREFIX=foo FOLDER_ID=b1g... ./scripts/cleanup.sh  # override
#
# Reads from terraform/terraform.tfvars by default.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

require_bin yc jq

hdr "Refreshing YC IAM token"
refresh_yc_token

FOLDER_ID="${FOLDER_ID:-$(tfvar_get folder_id)}"
PREFIX="${PREFIX:-$(tfvar_get name 2>/dev/null || echo metrika-attribution)}"
BUCKET_NAME="${BUCKET_NAME:-$(tfvar_get function_bucket_name 2>/dev/null || echo "")}"

hdr "Cleanup plan for folder $FOLDER_ID (prefix: $PREFIX)"

# ── 1. Inventory ────────────────────────────────────────────────────────
log "Collecting inventory…"

list_ids() {
  local cmd="$1" filter="$2"
  yc_folder $cmd list --format json 2>/dev/null \
    | jq -r --arg f "$filter" '.[] | select(.name|startswith($f)) | "\(.id)\t\(.name)"' || true
}

TRIGGERS=$(list_ids "serverless trigger" "$PREFIX")
FUNCTIONS=$(list_ids "serverless function" "$PREFIX")
TRANSFERS=$(yc_folder datatransfer transfer list --format json 2>/dev/null \
  | jq -r --arg f "$PREFIX" '.[] | select(.name|startswith($f)) | "\(.id)\t\(.name)\t\(.status)"' || true)
ENDPOINTS=$(yc_folder datatransfer endpoint list --format json 2>/dev/null \
  | jq -r --arg f "$PREFIX" '.[] | select(.name|startswith($f)) | "\(.id)\t\(.name)"' || true)
CH_CLUSTERS=$(yc_folder managed-clickhouse cluster list --format json 2>/dev/null \
  | jq -r --arg f "$PREFIX" '.[] | select(.name|startswith($f)) | "\(.id)\t\(.name)\t\(.deletion_protection // false)"' || true)
SECRETS=$(list_ids "lockbox secret" "$PREFIX")
ROUTE_TABLES=$(list_ids "vpc route-table" "$PREFIX")
GATEWAYS=$(list_ids "vpc gateway" "$PREFIX")
SAS=$(yc iam service-account list --folder-id "$FOLDER_ID" --format json 2>/dev/null \
  | jq -r --arg f "$PREFIX" '.[] | select(.name|startswith($f)) | "\(.id)\t\(.name)"' || true)

print_list "Triggers"          "$TRIGGERS"
print_list "Functions"         "$FUNCTIONS"
print_list "Data Transfers"    "$TRANSFERS"
print_list "Transfer Endpoints" "$ENDPOINTS"
print_list "ClickHouse clusters" "$CH_CLUSTERS"
print_list "Lockbox secrets"   "$SECRETS"
print_list "Route tables"      "$ROUTE_TABLES"
print_list "VPC gateways"      "$GATEWAYS"
print_list "Service accounts"  "$SAS"
[ -n "$BUCKET_NAME" ] && printf '  Bucket: %s\n' "$BUCKET_NAME" >&2

if ! confirm "Delete ALL of the above (irreversible)?"; then
  warn "Aborted by user."
  exit 1
fi

# ── 2. Delete in dependency order ───────────────────────────────────────

# Triggers first — they reference functions
hdr "Deleting triggers"
while IFS=$'\t' read -r id name; do
  [ -z "$id" ] && continue
  log "trigger $name ($id)"
  yc_folder serverless trigger delete --id "$id" || warn "  failed: $id"
done <<<"$TRIGGERS"

# Transfers — must deactivate first
hdr "Deactivating + deleting transfers"
while IFS=$'\t' read -r id name status; do
  [ -z "$id" ] && continue
  if [ "$status" = "RUNNING" ]; then
    log "deactivating $name ($id)"
    yc_folder datatransfer transfer deactivate "$id" || warn "  deactivate failed: $id"
  fi
  log "deleting transfer $name ($id)"
  yc_folder datatransfer transfer delete "$id" || warn "  failed: $id"
done <<<"$TRANSFERS"

# Endpoints.  The UI-created Metrika source endpoint (where the write-only
# `period` field lives) must survive cleanup cycles so it isn't manually
# recreated every time.  Default: preserve the id from tfvars.
# Override: export KEEP_SOURCE_ID="" to delete everything, or
#           export KEEP_SOURCE_ID=<other-id> to preserve something else.
KEEP_SOURCE_ID="${KEEP_SOURCE_ID-$(tfvar_get metrika_source_endpoint_id 2>/dev/null || echo "")}"
[ -n "$KEEP_SOURCE_ID" ] && log "will preserve source endpoint: $KEEP_SOURCE_ID"
hdr "Deleting transfer endpoints"
while IFS=$'\t' read -r id name; do
  [ -z "$id" ] && continue
  if [ "$id" = "$KEEP_SOURCE_ID" ]; then
    log "preserving $name ($id) — KEEP_SOURCE_ID"
    continue
  fi
  log "endpoint $name ($id)"
  yc_folder datatransfer endpoint delete "$id" || warn "  failed: $id"
done <<<"$ENDPOINTS"

# Functions (after triggers gone)
hdr "Deleting functions"
while IFS=$'\t' read -r id name; do
  [ -z "$id" ] && continue
  log "function $name ($id)"
  yc_folder serverless function delete --id "$id" || warn "  failed: $id"
done <<<"$FUNCTIONS"

# ClickHouse clusters — disable deletion_protection first
hdr "Deleting ClickHouse clusters"
while IFS=$'\t' read -r id name protected; do
  [ -z "$id" ] && continue
  if [ "$protected" = "true" ]; then
    log "disabling deletion_protection on $name ($id)"
    yc_folder managed-clickhouse cluster update --id "$id" --deletion-protection=false || warn "  failed"
  fi
  log "deleting cluster $name ($id)"
  yc_folder managed-clickhouse cluster delete --id "$id" || warn "  failed: $id"
done <<<"$CH_CLUSTERS"

# Lockbox secrets
hdr "Deleting Lockbox secrets"
while IFS=$'\t' read -r id name; do
  [ -z "$id" ] && continue
  log "secret $name ($id)"
  yc_folder lockbox secret delete --id "$id" || warn "  failed: $id"
done <<<"$SECRETS"

# VPC — route tables must be unbound from subnets before delete.
# Subnet itself is user-owned, so we just unbind (--route-table-id "")
# and leave the subnet in place.
hdr "Unbinding subnet from route-table (if bound to ours) + deleting route tables"
SUBNET_ID_VAL="$(tfvar_get subnet_id 2>/dev/null || echo "")"
while IFS=$'\t' read -r id name; do
  [ -z "$id" ] && continue
  if [ -n "$SUBNET_ID_VAL" ]; then
    BOUND_RT="$(yc vpc subnet get --id "$SUBNET_ID_VAL" --format json 2>/dev/null \
      | jq -r '.route_table_id // empty')"
    if [ "$BOUND_RT" = "$id" ]; then
      log "unbinding subnet $SUBNET_ID_VAL from route-table $id"
      yc vpc subnet update --id "$SUBNET_ID_VAL" --route-table-id "" \
        || warn "  unbind failed: $id"
    fi
  fi
  log "route-table $name ($id)"
  yc_folder vpc route-table delete --id "$id" || warn "  failed: $id"
done <<<"$ROUTE_TABLES"

# Gateways — deletable only after no route-table references them.
hdr "Deleting VPC gateways"
while IFS=$'\t' read -r id name; do
  [ -z "$id" ] && continue
  log "gateway $name ($id)"
  yc_folder vpc gateway delete --id "$id" || warn "  failed: $id"
done <<<"$GATEWAYS"

# Object storage bucket — must be emptied before delete.
# We use scripts/s3_empty.py (stdlib-only SigV4 S3 client) so no aws-cli
# dependency is required.  Credentials come from a temporary static
# access key minted for the storage SA.
if [ -n "$BUCKET_NAME" ]; then
  hdr "Deleting Object Storage bucket"
  log "checking bucket $BUCKET_NAME"
  if yc storage bucket get --name "$BUCKET_NAME" >/dev/null 2>&1; then
    STORAGE_SA_NAME="${PREFIX}-transform-storage-sa"
    STORAGE_SA_ID="$(yc iam service-account list --folder-id "$FOLDER_ID" --format json \
      | jq -r --arg n "$STORAGE_SA_NAME" '.[] | select(.name==$n) | .id')"

    if [ -z "$STORAGE_SA_ID" ]; then
      warn "  storage SA $STORAGE_SA_NAME not found — can't empty bucket"
      warn "  aborting bucket delete (manual cleanup required)"
    else
      log "minting temporary static access key for SA $STORAGE_SA_ID"
      KEY_JSON="$(yc iam access-key create --service-account-id "$STORAGE_SA_ID" --format json)"
      export AWS_ACCESS_KEY_ID="$(echo "$KEY_JSON"  | jq -r '.access_key.key_id')"
      export AWS_SECRET_ACCESS_KEY="$(echo "$KEY_JSON" | jq -r '.secret')"

      log "emptying bucket $BUCKET_NAME via stdlib S3 client"
      if python3 "$SCRIPT_DIR/s3_empty.py" "$BUCKET_NAME"; then
        log "deleting bucket"
        yc storage bucket delete --name "$BUCKET_NAME" || warn "  delete failed"
      else
        warn "  failed to empty bucket — leaving it alone"
      fi

      log "revoking temporary access key $AWS_ACCESS_KEY_ID"
      yc iam access-key delete --id "$AWS_ACCESS_KEY_ID" >/dev/null \
        || warn "  failed to delete temp key (will be removed with SA)"
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    fi
  else
    log "bucket $BUCKET_NAME doesn't exist, skipping"
  fi
fi

# Service accounts last — they may be referenced by IAM bindings
hdr "Deleting service accounts"
while IFS=$'\t' read -r id name; do
  [ -z "$id" ] && continue
  log "service account $name ($id)"
  yc iam service-account delete --id "$id" || warn "  failed: $id"
done <<<"$SAS"

# ── 3. Local Terraform state ────────────────────────────────────────────
hdr "Wiping local Terraform state"
for f in "$TF_DIR"/.terraform "$TF_DIR"/.terraform.lock.hcl \
         "$TF_DIR"/terraform.tfstate "$TF_DIR"/terraform.tfstate.backup \
         "$TF_DIR"/tfplan; do
  if [ -e "$f" ]; then
    log "rm -rf $f"
    rm -rf "$f"
  fi
done

ok "Cleanup complete. Folder is ready for a fresh deploy."
