#!/usr/bin/env bash
# Preflight before `terraform apply`:
#   * verify prerequisites (yc, terraform, clickhouse client, jq, python3)
#   * verify tfvars exists and contains required keys (no placeholders)
#   * download Yandex Cloud root CA (with sanity check)
#   * sync sql/*.sql into functions/transform/sql/ (single source of truth)
#
# Idempotent.  Safe to re-run.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

hdr "Preflight checks"

# 1. Binaries
log "checking required binaries"
require_bin terraform yc jq python3 curl
if ! command -v clickhouse-client >/dev/null 2>&1 && ! command -v clickhouse >/dev/null 2>&1; then
  die "need clickhouse-client or the single-binary 'clickhouse' (for DDL provisioner)"
fi
ok "  all binaries present"

# 2. tfvars
log "checking $TFVARS"
[ -f "$TFVARS" ] || die "$TFVARS not found — copy terraform.tfvars.example and fill it"
for key in folder_id network_id subnet_id counter_id goal_id \
           metrika_source_endpoint_id function_bucket_name clickhouse_password; do
  tfvar_get "$key" >/dev/null 2>&1 || {
    # secrets can be supplied via TF_VAR_*
    case "$key" in
      clickhouse_password)
        var="TF_VAR_$key"
        [ -n "${!var:-}" ] || die "missing $key in tfvars and \$TF_VAR_$key not set"
        ;;
      *)
        die "missing required key in terraform.tfvars: $key"
        ;;
    esac
  }
done
ok "  tfvars OK"

# Refuse to proceed if tfvars has placeholder values
if grep -qE 'b1g\.\.\.|enpb\.\.\.|e9b\.\.\.|dte\.\.\.|StrongP@ssw0rd' "$TFVARS"; then
  die "terraform.tfvars still contains example placeholders — edit before running"
fi

# 3. Yandex Cloud root CA
CA_PATH="$REPO_ROOT/functions/transform/CA.pem"
CA_URL="https://storage.yandexcloud.net/cloud-certs/CA.pem"
if [ -s "$CA_PATH" ]; then
  log "CA already present at $CA_PATH"
else
  log "downloading Yandex Cloud root CA from $CA_URL"
  # curl with --fail verifies HTTPS chain against system trust (bootstrap ToFU).
  curl --fail --silent --show-error --location "$CA_URL" -o "$CA_PATH.tmp"
  # Sanity: must be a PEM file starting with BEGIN CERTIFICATE
  if ! head -1 "$CA_PATH.tmp" | grep -q 'BEGIN CERTIFICATE'; then
    rm -f "$CA_PATH.tmp"
    die "downloaded CA is not PEM-formatted"
  fi
  mv "$CA_PATH.tmp" "$CA_PATH"
fi
ok "  CA OK ($(wc -c < "$CA_PATH") bytes)"

# 4. Sync SQL
log "syncing sql/ → functions/transform/sql/"
mkdir -p "$REPO_ROOT/functions/transform/sql"
# Only the files actually used by the function handler
for f in 01_schema.sql 02_prepare_visits.sql 03_combine_visits.sql 05_attribution_models.sql; do
  cp "$REPO_ROOT/sql/$f" "$REPO_ROOT/functions/transform/sql/$f"
done
ok "  SQL synced"

# 4b. Sync source-name dictionaries (CSV lookup tables).  Shipped inside
# the function ZIP; handler.py loads them into dict_* tables on each run.
log "syncing dicts/ → functions/transform/dicts/"
mkdir -p "$REPO_ROOT/functions/transform/dicts"
for f in search_engine_roots.csv adv_engines.csv social_networks.csv \
         recommendation_systems.csv messengers.csv; do
  if [ -f "$REPO_ROOT/dicts/$f" ]; then
    cp "$REPO_ROOT/dicts/$f" "$REPO_ROOT/functions/transform/dicts/$f"
  else
    warn "  dicts/$f missing — source names will fall back to '<Root>: код <id>'"
    # Write a header-only stub so handler.py does not fail on missing file.
    printf 'id,name_ru\n' > "$REPO_ROOT/functions/transform/dicts/$f"
  fi
done
ok "  dicts synced"

# 5. Refuse unsafe CLICKHOUSE_TLS
if [ "${CLICKHOUSE_TLS:-1}" = "0" ]; then
  warn "CLICKHOUSE_TLS=0 set in env — TLS WILL BE DISABLED in the function"
fi

# 6. macOS sleep gotcha: if the laptop suspends mid-apply, the terraform
# local-exec polling loop pauses with it — the wall-clock of terraform
# balloons even though the snapshot itself is fast.  Nudge the user.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && [ -z "${CAFFEINATED:-}" ]; then
  warn "macOS detected. Apply takes 15-30 min (cluster + snapshot).  If the Mac"
  warn "  sleeps, terraform's local-exec polling pauses too.  Consider running"
  warn "  under caffeinate:   CAFFEINATED=1 caffeinate -is ./scripts/e2e.sh"
fi

ok "Preflight passed.  Ready for: terraform -chdir=terraform init && terraform -chdir=terraform apply"
