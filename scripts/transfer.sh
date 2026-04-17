#!/usr/bin/env bash
# Create source/target endpoints and a SNAPSHOT_ONLY transfer via the
# yandexcloud Python SDK (gRPC).  The yc CLI only covers pg/mysql/
# mongo/ch/yds endpoint types — Metrika source needs the SDK.
#
# Reads:
#   * folder_id, counter_id, name from terraform.tfvars
#   * clickhouse cluster id + db/user from `terraform output`
#   * metrika_oauth_token + clickhouse_password from Lockbox
#
# After activation, polls the transfer status until DONE or ERROR.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

require_bin yc jq terraform python3

hdr "Refreshing YC IAM token"
refresh_yc_token

FOLDER_ID="$(tfvar_get folder_id)"
PREFIX="$(tfvar_get name 2>/dev/null || echo metrika-attribution)"
COUNTER_ID="$(tfvar_get counter_id)"

# Optional date range — stored but only applied if proto supports it.
PERIOD_FROM="${PERIOD_FROM:-$(date -u -d '30 days ago' +%Y-%m-%d 2>/dev/null \
                              || date -u -v-30d +%Y-%m-%d)}"
PERIOD_TO="${PERIOD_TO:-$(date -u +%Y-%m-%d)}"

hdr "Transfer setup ($PERIOD_FROM → $PERIOD_TO, counter $COUNTER_ID)"

log "reading terraform outputs"
SECRET_ID="$(terraform -chdir="$TF_DIR" output -raw lockbox_secret_id)"
CH_CLUSTER_ID="$(terraform -chdir="$TF_DIR" output -raw clickhouse_cluster_id)"
CH_DB="$(terraform -chdir="$TF_DIR" output -raw clickhouse_db_name 2>/dev/null || echo metrika)"
CH_USER="$(terraform -chdir="$TF_DIR" output -raw clickhouse_db_user 2>/dev/null || echo analyst)"
[ -n "$SECRET_ID" ]     || die "lockbox_secret_id output is empty"
[ -n "$CH_CLUSTER_ID" ] || die "clickhouse_cluster_id output is empty"

log "fetching secrets from Lockbox $SECRET_ID"
PAYLOAD="$(yc lockbox payload get --id "$SECRET_ID" --format json)"
METRIKA_TOKEN="$(echo "$PAYLOAD" | jq -r '.entries[] | select(.key=="metrika_oauth_token") | .text_value')"
CH_PASSWORD="$(echo "$PAYLOAD" | jq -r '.entries[] | select(.key=="clickhouse_password") | .text_value')"
[ -n "$METRIKA_TOKEN" ] || die "metrika_oauth_token not found in Lockbox payload"
[ -n "$CH_PASSWORD"   ] || die "clickhouse_password not found in Lockbox payload"

SOURCE_NAME="${PREFIX}-metrika-source"
TARGET_NAME="${PREFIX}-ch-target"
TRANSFER_NAME="${PREFIX}-metrika-to-ch"

hdr "Removing any pre-existing transfer/endpoints with these names"
# When EXISTING_SOURCE_ID is set, preserve that one endpoint — the user
# created it in the UI so the 'period' field (not exposed on public API)
# is stored in the backend.  Recreating it via SDK would lose period.
KEEP_ID="${EXISTING_SOURCE_ID:-}"
for r in transfer endpoint; do
  yc datatransfer "$r" list --folder-id "$FOLDER_ID" --format json 2>/dev/null \
    | jq -r --arg p "$PREFIX" '.[] | select(.name|startswith($p)) | .id' \
    | while read -r id; do
        [ -z "$id" ] && continue
        if [ "$id" = "$KEEP_ID" ]; then
          log "keeping $r $id (EXISTING_SOURCE_ID)"
          continue
        fi
        log "deleting $r $id"
        if [ "$r" = "transfer" ]; then
          yc datatransfer transfer deactivate "$id" 2>/dev/null || true
          yc datatransfer transfer delete "$id"  || warn "  failed"
        else
          yc datatransfer endpoint delete "$id"  || warn "  failed"
        fi
      done
done

hdr "Creating endpoints + transfer (via Python SDK)"
# Secrets go via env vars, not command-line args — never visible in ps aux.
export YC_TOKEN FOLDER_ID COUNTER_ID METRIKA_TOKEN
export PERIOD_FROM PERIOD_TO
export CH_CLUSTER_ID CH_DB CH_USER CH_PASSWORD
export SOURCE_NAME TARGET_NAME TRANSFER_NAME
export EXISTING_SOURCE_ID="${EXISTING_SOURCE_ID:-}"
[ -n "$EXISTING_SOURCE_ID" ] && log "using existing source id=$EXISTING_SOURCE_ID (skip source create)"

TRANSFER_ID="$(python3 "$SCRIPT_DIR/setup_transfer.py" || true)"
if [ -z "$TRANSFER_ID" ]; then
  warn "Automatic transfer creation is not possible on this YC API version."
  warn "Endpoints are created — follow the UI instructions printed above."
  warn "After the transfer finishes in the UI, run:  ./scripts/smoke.sh"
  exit 0
fi

log "transfer id = $TRANSFER_ID"
echo "$TRANSFER_ID" > "$TF_DIR/.transfer-id"

hdr "Polling transfer status (Ctrl-C safe — transfer keeps running)"
while true; do
  status="$(yc datatransfer transfer get "$TRANSFER_ID" --format json 2>/dev/null \
            | jq -r '.status // .state // empty')"
  log "  status=${status:-unknown}"
  case "${status:-}" in
    DONE)   ok "transfer finished successfully"; break ;;
    ERROR|FAILED)
            die "transfer failed — yc datatransfer transfer get $TRANSFER_ID" ;;
    "")     warn "  no status field in response — check transfer manually"; break ;;
    *)      sleep 15 ;;
  esac
done

ok "Transfer complete.  Next: scripts/smoke.sh to verify pipeline."
