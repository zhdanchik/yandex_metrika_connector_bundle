#!/usr/bin/env python3
"""
Create a Yandex Data Transfer Metrika-source endpoint via REST API.

The `yc` CLI only supports postgres/mysql/mongo/clickhouse/yds endpoint
types (not metrika), so we talk to the API directly.

Reads from env:
    YC_TOKEN       IAM token (exported by scripts/lib.sh refresh_yc_token)
    FOLDER_ID      Yandex Cloud folder ID
    ENDPOINT_NAME  Name for the endpoint
    COUNTER_ID     Yandex Metrika counter ID
    METRIKA_TOKEN  OAuth token (sensitive — never echoed)
    PERIOD_FROM    YYYY-MM-DD
    PERIOD_TO      YYYY-MM-DD

Prints the created endpoint ID on stdout.  Errors go to stderr + exit 1.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://datatransfer.api.cloud.yandex.net/data-transfer/v1"
OP_API = "https://operation.api.cloud.yandex.net/operations"

# Columns we pull from Metrika.  Matches terraform/modules/transfer/main.tf
# and scripts/transfer.sh YAML spec so the attribution pipeline still works.
COLUMNS = [
    "CounterUserIDHash",
    "UTCStartTime",
    "Duration",
    "TrafficSource.Model",
    "TrafficSource.ID",
    "TrafficSource.StartTime",
    "TrafficSource.SearchEngineID",
    "TrafficSource.AdvEngineID",
    "TrafficSource.SocialSourceNetworkID",
    "TrafficSource.RecommendationSystemID",
    "TrafficSource.MessengerID",
    "TrafficSource.ClickBannerID",
    "TrafficSource.ClickTargetType",
    "Goals.ID",
    "Goals.Serial",
    "Goals.EventTime",
    "Goals.Price",
    "Goals.Currency",
    "EPurchase.ID",
    "EPurchase.Revenue",
]


def _req(method: str, url: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {os.environ['YC_TOKEN']}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    print(f"  [http] {method} {url}", file=sys.stderr)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        payload = e.read().decode("utf-8", errors="replace")
        print(f"HTTP {e.code} on {method} {url}:\n{payload}", file=sys.stderr)
        raise SystemExit(1)


def _wait_operation(op: dict) -> dict:
    """Block until the operation completes; return the final Operation object."""
    op_id = op["id"]
    while not op.get("done", False):
        time.sleep(2)
        op = _req("GET", f"{OP_API}/{op_id}")
    if "error" in op:
        print(f"operation error: {json.dumps(op['error'], indent=2)}", file=sys.stderr)
        raise SystemExit(1)
    return op


def main() -> int:
    required = [
        "YC_TOKEN", "FOLDER_ID", "ENDPOINT_NAME",
        "COUNTER_ID", "METRIKA_TOKEN", "PERIOD_FROM", "PERIOD_TO",
    ]
    missing = [v for v in required if not os.environ.get(v)]
    if missing:
        print(f"missing env vars: {', '.join(missing)}", file=sys.stderr)
        return 2

    body = {
        "folderId": os.environ["FOLDER_ID"],
        "name":     os.environ["ENDPOINT_NAME"],
        "settings": {
            "metrikaSource": {
                "counterIds": [int(os.environ["COUNTER_ID"])],
                "token": {"raw": os.environ["METRIKA_TOKEN"]},
                "streams": [{
                    "type":    "METRIKA_STREAM_TYPE_VISITS",
                    "columns": COLUMNS,
                }],
                # DateRange is a pair of YYYY-MM-DD dates.  Metrika is
                # snapshot-only, so every activation replays this window.
                "period": {
                    "from": os.environ["PERIOD_FROM"],
                    "to":   os.environ["PERIOD_TO"],
                },
            },
        },
    }

    op = _req("POST", f"{API}/endpoints", body)
    endpoint_id = (op.get("metadata") or {}).get("endpointId") \
                  or (op.get("response") or {}).get("id")
    op = _wait_operation(op)
    # Endpoint ID is in metadata regardless of done-state; response carries
    # the full resource after completion.
    if not endpoint_id:
        endpoint_id = (op.get("response") or {}).get("id")
    if not endpoint_id:
        print(f"could not extract endpoint id from:\n{json.dumps(op, indent=2)}",
              file=sys.stderr)
        return 1

    print(endpoint_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
