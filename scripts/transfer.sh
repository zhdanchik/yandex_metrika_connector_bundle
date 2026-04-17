#!/usr/bin/env bash
# Create source/target endpoints and a SNAPSHOT_ONLY transfer via yc CLI.
# (The Terraform provider can't set the metrika_source.period.from/to dates
# required for snapshot mode, so we fall back to the CLI here.)
#
# Reads:
#   * folder_id, counter_id, function_bucket_name, name from terraform.tfvars
#   * cluster_id from `terraform output`
#   * metrika_oauth_token from Lockbox (via secret_id from terraform output)
#   * clickhouse_password from Lockbox
#   * service_account_id of the transfer SA from `yc iam service-account list`
#
# After creation, activates the transfer and polls until it reaches DONE/ERROR.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

require_bin yc jq terraform

hdr "Refreshing YC IAM token"
refresh_yc_token

FOLDER_ID="$(tfvar_get folder_id)"
PREFIX="$(tfvar_get name 2>/dev/null || echo metrika-attribution)"
COUNTER_ID="$(tfvar_get counter_id)"

# Optional date range — default last 30 days through today.
PERIOD_FROM="${PERIOD_FROM:-$(date -u -d '30 days ago' +%Y-%m-%d 2>/dev/null \
                              || date -u -v-30d +%Y-%m-%d)}"
PERIOD_TO="${PERIOD_TO:-$(date -u +%Y-%m-%d)}"

hdr "Transfer setup ($PERIOD_FROM → $PERIOD_TO, counter $COUNTER_ID)"

# Lookup IDs from terraform state.
log "reading terraform outputs"
SECRET_ID="$(terraform -chdir="$TF_DIR" output -raw lockbox_secret_id)"
CH_CLUSTER_ID="$(terraform -chdir="$TF_DIR" output -raw clickhouse_cluster_id)"
[ -n "$SECRET_ID" ]      || die "lockbox_secret_id output is empty"
[ -n "$CH_CLUSTER_ID" ]  || die "clickhouse_cluster_id output is empty"

# Pull secrets from Lockbox (executor must have lockbox.payloadViewer or admin).
log "fetching secrets from Lockbox $SECRET_ID"
PAYLOAD="$(yc lockbox payload get --id "$SECRET_ID" --format json)"
METRIKA_TOKEN="$(echo "$PAYLOAD" | jq -r '.entries[] | select(.key=="metrika_oauth_token") | .text_value')"
CH_PASSWORD="$(echo "$PAYLOAD" | jq -r '.entries[] | select(.key=="clickhouse_password") | .text_value')"
[ -n "$METRIKA_TOKEN" ] || die "metrika_oauth_token not found in Lockbox payload"
[ -n "$CH_PASSWORD"   ] || die "clickhouse_password not found in Lockbox payload"

# Service account for the transfer (created by terraform).
TRANSFER_SA_ID="$(yc iam service-account list --folder-id "$FOLDER_ID" --format json \
  | jq -r --arg n "${PREFIX}-transfer-sa" '.[] | select(.name==$n) | .id')"
[ -n "$TRANSFER_SA_ID" ] || die "transfer SA ${PREFIX}-transfer-sa not found"

CH_DB="$(terraform -chdir="$TF_DIR" output -raw clickhouse_db_name 2>/dev/null || echo metrika)"
CH_USER="$(terraform -chdir="$TF_DIR" output -raw clickhouse_db_user 2>/dev/null || echo analyst)"

SOURCE_NAME="${PREFIX}-metrika-source"
TARGET_NAME="${PREFIX}-ch-target"
TRANSFER_NAME="${PREFIX}-metrika-to-ch"

# Idempotency: delete prior endpoints/transfer with the same names.
hdr "Removing any pre-existing transfer/endpoints with these names"
for r in transfer endpoint; do
  yc datatransfer "$r" list --folder-id "$FOLDER_ID" --format json \
    | jq -r --arg p "$PREFIX" '.[] | select(.name|startswith($p)) | .id' \
    | while read -r id; do
        [ -z "$id" ] && continue
        log "deleting $r $id"
        if [ "$r" = "transfer" ]; then
          yc datatransfer transfer deactivate "$id" 2>/dev/null || true
          yc datatransfer transfer delete "$id"  || warn "  failed"
        else
          yc datatransfer endpoint delete "$id"  || warn "  failed"
        fi
      done
done

# Build YAML specs in tmp files (avoid shell quoting hell with secrets).
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
chmod 700 "$TMP_DIR"

TGT_SPEC="$TMP_DIR/target.yaml"
umask 077

cat > "$TGT_SPEC" <<EOF
connection:
  connection_options:
    mdb_cluster_id: $CH_CLUSTER_ID
    database: $CH_DB
    user: $CH_USER
    password:
      raw: "$CH_PASSWORD"
sharding:
  column_value_hash:
    column_name: CounterUserIDHash
cleanup_policy: CLICKHOUSE_CLEANUP_POLICY_DISABLED
EOF

hdr "Creating endpoints"
# Metrika source: yc CLI doesn't support create metrika-source, so we hit
# the REST API directly from scripts/create_metrika_endpoint.py.  Secrets
# are passed via env (never cmdline / ps aux).
log "  source: Yandex Metrika (via REST API)"
SRC_ID="$(
  FOLDER_ID="$FOLDER_ID" \
  ENDPOINT_NAME="$SOURCE_NAME" \
  COUNTER_ID="$COUNTER_ID" \
  METRIKA_TOKEN="$METRIKA_TOKEN" \
  PERIOD_FROM="$PERIOD_FROM" \
  PERIOD_TO="$PERIOD_TO" \
  python3 "$SCRIPT_DIR/create_metrika_endpoint.py"
)"
[ -n "$SRC_ID" ] || die "failed to create Metrika source endpoint"
log "    id=$SRC_ID"

log "  target: Managed ClickHouse (via yc CLI)"
TGT_ID="$(yc datatransfer endpoint create clickhouse-target \
  --folder-id "$FOLDER_ID" --name "$TARGET_NAME" \
  --settings-from-file "$TGT_SPEC" --format json | jq -r .id)"
log "    id=$TGT_ID"

hdr "Creating transfer (SNAPSHOT_ONLY)"
TRANSFER_ID="$(yc datatransfer transfer create \
  --folder-id "$FOLDER_ID" --name "$TRANSFER_NAME" \
  --source-id "$SRC_ID" --target-id "$TGT_ID" \
  --type SNAPSHOT_ONLY --format json | jq -r .id)"
log "  id=$TRANSFER_ID"

hdr "Activating transfer"
yc datatransfer transfer activate "$TRANSFER_ID" --async
log "polling status (Ctrl-C is safe — transfer keeps running)"
while true; do
  status="$(yc datatransfer transfer get "$TRANSFER_ID" --format json | jq -r .status)"
  log "  status=$status"
  case "$status" in
    DONE)   ok "transfer finished successfully"; break ;;
    ERROR)  die "transfer failed — check yc datatransfer transfer get $TRANSFER_ID" ;;
    *)      sleep 15 ;;
  esac
done

ok "Transfer complete.  Next: scripts/smoke.sh to verify pipeline."
echo "$TRANSFER_ID" > "$TF_DIR/.transfer-id"
