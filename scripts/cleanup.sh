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
SAS=$(yc iam service-account list --folder-id "$FOLDER_ID" --format json 2>/dev/null \
  | jq -r --arg f "$PREFIX" '.[] | select(.name|startswith($f)) | "\(.id)\t\(.name)"' || true)

print_list "Triggers"          "$TRIGGERS"
print_list "Functions"         "$FUNCTIONS"
print_list "Data Transfers"    "$TRANSFERS"
print_list "Transfer Endpoints" "$ENDPOINTS"
print_list "ClickHouse clusters" "$CH_CLUSTERS"
print_list "Lockbox secrets"   "$SECRETS"
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

# Endpoints
hdr "Deleting transfer endpoints"
while IFS=$'\t' read -r id name; do
  [ -z "$id" ] && continue
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

# Object storage bucket — must be emptied before delete
if [ -n "$BUCKET_NAME" ]; then
  hdr "Deleting Object Storage bucket"
  log "checking bucket $BUCKET_NAME"
  if yc storage bucket get --name "$BUCKET_NAME" >/dev/null 2>&1; then
    # Need to remove all objects + multipart uploads first.
    if command -v aws >/dev/null 2>&1; then
      log "emptying bucket via aws-cli (S3 endpoint)"
      AWS_EC2_METADATA_DISABLED=true aws --endpoint-url=https://storage.yandexcloud.net \
        s3 rm "s3://$BUCKET_NAME" --recursive || warn "  s3 rm failed (may need creds)"
    else
      warn "aws-cli not installed; bucket objects will block delete. Install awscli or empty manually."
    fi
    log "deleting bucket"
    yc storage bucket delete --name "$BUCKET_NAME" || warn "  failed (likely non-empty)"
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
