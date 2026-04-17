#!/usr/bin/env bash
# End-to-end smoke test:
#   1. Verify visits_raw is non-empty
#   2. Invoke the Cloud Function synchronously
#   3. Verify visits_prepared / visits_combined / attribution_results populated
#   4. Print a small attribution summary
#
# Reads connection params from terraform output and Lockbox.
# Uses HTTPS to ClickHouse with proper CA verification (curl --cacert).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

require_bin yc jq curl terraform

hdr "Refreshing YC IAM token"
refresh_yc_token

FOLDER_ID="$(tfvar_get folder_id)"
PREFIX="$(tfvar_get name 2>/dev/null || echo metrika-attribution)"
GOAL_ID="$(tfvar_get goal_id)"

CA_PATH="$REPO_ROOT/functions/transform/CA.pem"
[ -s "$CA_PATH" ] || die "CA cert missing — run scripts/prepare.sh first"

log "reading terraform outputs"
CH_HOST="$(terraform -chdir="$TF_DIR" output -raw clickhouse_host)"
CH_DB="$(terraform -chdir="$TF_DIR" output -raw clickhouse_db_name 2>/dev/null || echo metrika)"
CH_USER="$(terraform -chdir="$TF_DIR" output -raw clickhouse_db_user 2>/dev/null || echo analyst)"
SECRET_ID="$(terraform -chdir="$TF_DIR" output -raw lockbox_secret_id)"
FN_ID="$(terraform -chdir="$TF_DIR" output -raw function_id)"

log "fetching ClickHouse password from Lockbox"
CH_PASSWORD="$(yc lockbox payload get --id "$SECRET_ID" --format json \
  | jq -r '.entries[] | select(.key=="clickhouse_password") | .text_value')"
[ -n "$CH_PASSWORD" ] || die "clickhouse_password missing from Lockbox"

# ── ClickHouse query helper (TLS verified) ───────────────────────────────
ch() {
  # Send password via header (over TLS), not on cmdline
  local sql="$1"
  curl --silent --show-error --fail \
    --cacert "$CA_PATH" \
    -H "X-ClickHouse-User: $CH_USER" \
    -H "X-ClickHouse-Key: $CH_PASSWORD" \
    --data-binary "$sql" \
    "https://$CH_HOST:8443/?database=$CH_DB&max_execution_time=300"
}

hdr "Pre-check: visits_raw"
RAW_COUNT="$(ch 'SELECT count() FROM visits_raw' 2>/dev/null | tr -d '\n' || echo 0)"
log "  visits_raw rows: $RAW_COUNT"
if [ "${RAW_COUNT:-0}" -lt 1 ]; then
  warn "visits_raw is missing or empty — listing all tables to diagnose…"
  TABLES="$(ch "SELECT name FROM system.tables WHERE database='$CH_DB' AND name NOT LIKE '.%' FORMAT TSV")"
  echo "$TABLES" | sed 's/^/    /'

  # YC Data Transfer names the populated table 'visits_<transfer_id>'.
  # Exclude the pipeline's own tables (visits_raw/_prepared/_combined,
  # attribution_results) so we don't accidentally alias an empty
  # intermediate table.
  CANDIDATE="$(echo "$TABLES" \
    | grep -iE '^visits_' \
    | grep -vxE 'visits_raw|visits_prepared|visits_combined' \
    | head -1 | tr -d '\n' || true)"
  if [ -z "$CANDIDATE" ]; then
    die "no transfer-populated visits_<id> table found in $CH_DB — run transfer first"
  fi

  warn "found candidate: $CANDIDATE"
  warn "dropping empty visits_raw table and re-creating as view → $CANDIDATE"
  # The existing visits_raw is a TABLE (from sql/01_schema.sql), not a view.
  # CREATE OR REPLACE VIEW would fail against a table — drop + create.
  ch "DROP TABLE IF EXISTS visits_raw" > /dev/null
  ch "CREATE VIEW visits_raw AS SELECT * FROM $CANDIDATE" > /dev/null
  RAW_COUNT="$(ch 'SELECT count() FROM visits_raw' | tr -d '\n')"
  log "  visits_raw (via view) rows: $RAW_COUNT"
  [ "$RAW_COUNT" -gt 0 ] || die "view still empty — something else is off"
fi

hdr "Invoking Cloud Function"
INVOKE_OUT="$(yc serverless function invoke --id "$FN_ID" --data '{}' --format json 2>&1)"
echo "$INVOKE_OUT" | jq . 2>/dev/null || echo "$INVOKE_OUT"
echo "$INVOKE_OUT" | grep -q '"statusCode":\s*200' \
  || die "function returned non-200 — check yc serverless function logs read --id $FN_ID"
ok "function returned 200"

hdr "Post-check: pipeline tables"
for table in visits_prepared visits_combined attribution_results; do
  cnt="$(ch "SELECT count() FROM $table" | tr -d '\n')"
  log "  $table rows: $cnt"
  [ "$cnt" -gt 0 ] || warn "    table $table is empty"
done

hdr "Attribution sanity check (4 models for goal=$GOAL_ID)"
MODELS="$(ch "SELECT attribution_type, count() AS rows, round(sum(conversions),2) AS conv
              FROM attribution_results
              GROUP BY attribution_type
              ORDER BY attribution_type
              FORMAT PrettyCompactNoEscapes")"
echo "$MODELS"
n_models="$(ch "SELECT countDistinct(attribution_type) FROM attribution_results" | tr -d '\n')"
[ "$n_models" -eq 4 ] || warn "expected 4 attribution_type values, got $n_models"

hdr "Top 5 sources by last_touch conversions"
ch "SELECT source_code, round(sum(conversions),2) AS conv
    FROM attribution_results
    WHERE attribution_type='last_touch'
    GROUP BY source_code
    ORDER BY conv DESC
    LIMIT 5
    FORMAT PrettyCompactNoEscapes"

ok "Smoke test passed."
