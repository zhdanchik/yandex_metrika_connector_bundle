#!/usr/bin/env bash
# Ensure the Cloud Function's subnet has egress to the public internet
# (needed to hit Lockbox API at payload.lockbox.api.cloud.yandex.net).
#
# Idempotent:
#   * Re-uses an existing egress gateway if one is already present.
#   * Re-uses an existing route table with a 0.0.0.0/0 → gateway route.
#   * Attaches the route table to the subnet only if it's not already bound.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

require_bin yc jq
refresh_yc_token

FOLDER_ID="$(tfvar_get folder_id)"
NETWORK_ID="$(tfvar_get network_id)"
SUBNET_ID="$(tfvar_get subnet_id)"
PREFIX="$(tfvar_get name 2>/dev/null || echo metrika-attribution)"

GW_NAME="${PREFIX}-egress-nat"
RT_NAME="${PREFIX}-egress-rt"

hdr "Ensuring Cloud NAT for Cloud Function → Lockbox"

# ── 1. Egress gateway ────────────────────────────────────────────────────
GW_ID="$(yc vpc gateway list --folder-id "$FOLDER_ID" --format json \
  | jq -r --arg n "$GW_NAME" '.[] | select(.name==$n) | .id')"
if [ -z "$GW_ID" ]; then
  log "creating egress gateway $GW_NAME"
  # yc CLI versions have used either no flag (default = shared egress),
  # --shared-egress, or --shared-egress-gateway.  Try in that order.
  for FLAG_SET in \
      "" \
      "--shared-egress" \
      "--shared-egress-gateway"; do
    # shellcheck disable=SC2086
    if GW_JSON=$(yc vpc gateway create \
                  --folder-id "$FOLDER_ID" \
                  --name "$GW_NAME" \
                  $FLAG_SET \
                  --format json 2>&1); then
      GW_ID="$(echo "$GW_JSON" | jq -r .id)"
      [ -n "$GW_ID" ] && [ "$GW_ID" != "null" ] && break
    fi
    log "  flag variant ${FLAG_SET:-<none>} failed, trying next"
  done
  if [ -z "$GW_ID" ] || [ "$GW_ID" = "null" ]; then
    die "could not create egress gateway — run 'yc vpc gateway create --help' and tell me the correct flag"
  fi
fi
log "  gateway id = $GW_ID"

# ── 2. Route table with default route → gateway ──────────────────────────
RT_ID="$(yc vpc route-table list --folder-id "$FOLDER_ID" --format json \
  | jq -r --arg n "$RT_NAME" '.[] | select(.name==$n) | .id')"
if [ -z "$RT_ID" ]; then
  log "creating route table $RT_NAME"
  RT_ID="$(yc vpc route-table create \
    --folder-id "$FOLDER_ID" \
    --name "$RT_NAME" \
    --network-id "$NETWORK_ID" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID" \
    --format json | jq -r .id)"
else
  # Make sure an existing table actually has the default route pointing at our gateway.
  HAS_ROUTE="$(yc vpc route-table get --id "$RT_ID" --format json \
    | jq --arg gw "$GW_ID" \
        '[.static_routes[]? | select(.destination_prefix=="0.0.0.0/0" and .gateway_id==$gw)] | length')"
  if [ "${HAS_ROUTE:-0}" -eq 0 ]; then
    warn "route table $RT_NAME exists but has no 0.0.0.0/0 → $GW_ID route; updating"
    yc vpc route-table update --id "$RT_ID" \
      --route "destination=0.0.0.0/0,gateway-id=$GW_ID" >/dev/null
  fi
fi
log "  route table id = $RT_ID"

# ── 3. Bind route table to subnet if not already bound ───────────────────
CURRENT_RT="$(yc vpc subnet get --id "$SUBNET_ID" --format json \
  | jq -r '.route_table_id // empty')"
if [ "$CURRENT_RT" = "$RT_ID" ]; then
  log "subnet $SUBNET_ID already bound to this route table"
else
  if [ -n "$CURRENT_RT" ]; then
    warn "subnet $SUBNET_ID currently bound to another route table ($CURRENT_RT) — overwriting"
  fi
  log "binding route table $RT_ID to subnet $SUBNET_ID"
  yc vpc subnet update --id "$SUBNET_ID" --route-table-id "$RT_ID" >/dev/null
fi

ok "NAT egress is in place.  Cloud Function can now reach Lockbox / external APIs."
