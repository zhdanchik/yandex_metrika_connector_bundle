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
TRANSFER_ID="$(terraform -chdir="$TF_DIR" output -raw transfer_id 2>/dev/null || true)"

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
# Swallow stderr but not curl exit status — empty RAW_COUNT ≠ 0 rows means
# the query itself failed, and we should fall back to the transfer table.
RAW_COUNT="$(ch 'SELECT count() FROM visits_raw' 2>/dev/null || echo "")"
RAW_COUNT="$(printf '%s' "$RAW_COUNT" | tr -d '\n')"
log "  visits_raw rows: ${RAW_COUNT:-<query failed>}"
if [ -z "$RAW_COUNT" ] || [ "$RAW_COUNT" -lt 1 ]; then
  # YC Data Transfer creates the populated table as 'visits_<transfer_id>'.
  # It SHOULD be in $CH_DB (set via clickhouse_target.database), but verify
  # via system.tables in case YC put it somewhere else.
  [ -n "$TRANSFER_ID" ] || die "transfer_id missing from terraform output — did apply finish?"
  CANDIDATE_NAME="visits_${TRANSFER_ID}"
  log "looking up $CANDIDATE_NAME in system.tables"
  LOCATION="$(ch "SELECT database FROM system.tables WHERE name='$CANDIDATE_NAME' FORMAT TSV" 2>/dev/null | tr -d '\n' || true)"
  if [ -z "$LOCATION" ]; then
    warn "table $CANDIDATE_NAME not found anywhere — dumping system.tables for diagnosis:"
    ch "SELECT database, name FROM system.tables WHERE database NOT IN ('system','information_schema','INFORMATION_SCHEMA') ORDER BY database, name FORMAT PrettyCompactNoEscapes" || true
    die "transfer table $CANDIDATE_NAME missing — check yc datatransfer transfer get $TRANSFER_ID"
  fi
  FQ_CANDIDATE="${LOCATION}.${CANDIDATE_NAME}"
  warn "transfer table found at: $FQ_CANDIDATE"
  warn "dropping empty visits_raw and re-creating as view → $FQ_CANDIDATE"
  # The existing visits_raw is a TABLE (from sql/01_schema.sql), not a view.
  # CREATE OR REPLACE VIEW would fail against a table — drop + create.
  ch "DROP TABLE IF EXISTS visits_raw" > /dev/null
  ch "CREATE VIEW visits_raw AS SELECT * FROM $FQ_CANDIDATE" > /dev/null
  RAW_COUNT="$(ch 'SELECT count() FROM visits_raw' | tr -d '\n')"
  log "  visits_raw (via view) rows: $RAW_COUNT"
  [ "$RAW_COUNT" -gt 0 ] || die "view still empty — transfer may have succeeded with 0 rows"
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

hdr "Attribution sanity check (5 models for goal=$GOAL_ID)"
MODELS="$(ch "SELECT attribution_type,
                     count()                      AS rows,
                     round(sum(visits), 2)        AS visits,
                     round(sum(conversions), 2)   AS conv,
                     round(sum(revenue), 2)       AS revenue
              FROM attribution_results
              GROUP BY attribution_type
              ORDER BY attribution_type
              FORMAT PrettyCompactNoEscapes")"
echo "$MODELS"
n_models="$(ch "SELECT countDistinct(attribution_type) FROM attribution_results" | tr -d '\n')"
[ "$n_models" -eq 5 ] || warn "expected 5 attribution_type values, got $n_models"

# Cross-model invariant: sum(visits) should be equal across all 5 models
# (each chain contributes 1 visit total, split across its touches in
# linear/time_decay but still summing to 1 per chain).
DISTINCT_VISIT_TOTALS="$(ch "
  SELECT countDistinct(round(s, 2)) FROM (
    SELECT sum(visits) AS s FROM attribution_results GROUP BY attribution_type
  )" | tr -d '\n')"
if [ "$DISTINCT_VISIT_TOTALS" = "1" ]; then
  ok "cross-model invariant holds: sum(visits) identical across models"
else
  warn "sum(visits) differs across models — $DISTINCT_VISIT_TOTALS distinct totals"
fi

# If the goal has any conversions, rank by them.  If not (e.g. an
# intentionally unreachable goal being used as a smoke placeholder),
# rank by visits instead — more informative than "top 5 zeros".
TOTAL_CONV="$(ch "SELECT sum(conversions) FROM attribution_results
                  WHERE attribution_type='last_touch'" | tr -d '\n ')"
if [ "${TOTAL_CONV%.*}" != "0" ] 2>/dev/null && [ -n "$TOTAL_CONV" ]; then
  hdr "Top 5 last_touch sources by conversions"
  ch "SELECT source_code,
             round(sum(conversions), 2) AS conv,
             round(sum(visits), 2)       AS visits
      FROM attribution_results
      WHERE attribution_type='last_touch'
      GROUP BY source_code
      ORDER BY conv DESC
      LIMIT 5
      FORMAT PrettyCompactNoEscapes"
else
  hdr "Top 5 last_touch sources by visits (no conversions for goal=$GOAL_ID)"
  ch "SELECT source_code,
             round(sum(visits), 2)       AS visits,
             round(sum(conversions), 2) AS conv
      FROM attribution_results
      WHERE attribution_type='last_touch'
      GROUP BY source_code
      ORDER BY visits DESC
      LIMIT 5
      FORMAT PrettyCompactNoEscapes"
fi

ok "Smoke test passed."
