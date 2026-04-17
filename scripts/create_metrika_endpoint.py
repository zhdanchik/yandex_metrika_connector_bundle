#!/usr/bin/env python3
"""
Create a Yandex Data Transfer Metrika-source endpoint.

YC Data Transfer does not expose a REST gateway — only gRPC — and the
`yc` CLI only implements pg/mysql/mongo/ch/yds endpoint types.  We use
the official yandexcloud Python SDK (gRPC client) instead.

Install once:
    pip install --user yandexcloud

Reads from env:
    YC_TOKEN       IAM token (exported by scripts/lib.sh refresh_yc_token)
    FOLDER_ID      Yandex Cloud folder ID
    ENDPOINT_NAME  Name for the endpoint
    COUNTER_ID     Yandex Metrika counter ID
    METRIKA_TOKEN  OAuth token for Metrika (sensitive — never printed)
    PERIOD_FROM    YYYY-MM-DD
    PERIOD_TO      YYYY-MM-DD

Prints the created endpoint ID on stdout.
"""

import os
import sys
import time

try:
    import yandexcloud
    from google.protobuf.json_format import ParseDict, ParseError
    from yandex.cloud.datatransfer.v1.endpoint_pb2 import EndpointSettings, Endpoint
    from yandex.cloud.datatransfer.v1.endpoint_service_pb2 import (
        CreateEndpointRequest,
    )
    from yandex.cloud.datatransfer.v1.endpoint_service_pb2_grpc import (
        EndpointServiceStub,
    )
    from yandex.cloud.operation.operation_service_pb2_grpc import OperationServiceStub
    from yandex.cloud.operation.operation_service_pb2 import GetOperationRequest
except ImportError as exc:
    sys.stderr.write(
        f"missing Python dependency: {exc}\n"
        "Install once with:  pip install --user yandexcloud\n"
    )
    sys.exit(2)


# Columns mirror terraform/modules/transfer/main.tf so the downstream
# attribution pipeline (visits_prepared → visits_combined → results) still
# finds the fields it expects.
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


def _require_env() -> dict:
    required = [
        "YC_TOKEN", "FOLDER_ID", "ENDPOINT_NAME",
        "COUNTER_ID", "METRIKA_TOKEN", "PERIOD_FROM", "PERIOD_TO",
    ]
    missing = [v for v in required if not os.environ.get(v)]
    if missing:
        sys.exit(f"missing env vars: {', '.join(missing)}")
    return {v: os.environ[v] for v in required}


def _set_date_range(msg, period_from: str, period_to: str) -> bool:
    """Try to populate a date-range sub-message on `msg`.

    The Yandex proto for MetrikaStream has mutated over SDK versions
    (known names: date_range, period, dates), as have the inner
    field names (from/to vs start/end vs since/until).  We probe the
    actual descriptor rather than hard-code.  Returns True if set.
    """
    date_field_candidates = ("date_range", "period", "dates", "date_limits")
    from_to_candidates = (
        ("from", "to"), ("from_", "to"),
        ("start", "end"),
        ("since", "until"),
        ("date_from", "date_to"),
    )
    for field_name in date_field_candidates:
        if field_name not in msg.DESCRIPTOR.fields_by_name:
            continue
        sub = getattr(msg, field_name)
        for f_from, f_to in from_to_candidates:
            if f_from in sub.DESCRIPTOR.fields_by_name:
                try:
                    ParseDict({f_from: period_from, f_to: period_to}, sub)
                    sys.stderr.write(
                        f"  [proto] date range → {msg.DESCRIPTOR.name}."
                        f"{field_name}.{f_from}/{f_to}\n"
                    )
                    return True
                except ParseError:
                    continue
        sys.stderr.write(
            f"  [proto] found date field '{field_name}' on "
            f"{msg.DESCRIPTOR.name} but no from/to fields matched.  "
            f"Sub-fields: {list(sub.DESCRIPTOR.fields_by_name)}\n"
        )
    return False


def _build_settings(env: dict) -> EndpointSettings:
    """Compose MetrikaSource settings with introspection-based date-range."""
    payload = {
        "metrikaSource": {
            "counterIds": [int(env["COUNTER_ID"])],
            "token": {"raw": env["METRIKA_TOKEN"]},
            "streams": [{
                "type":    "METRIKA_STREAM_TYPE_VISITS",
                "columns": COLUMNS,
            }],
        },
    }
    settings = EndpointSettings()
    ParseDict(payload, settings)

    ms = settings.metrika_source
    stream = ms.streams[0]

    # Dump the proto layout once so any future mismatch is obvious.
    sys.stderr.write(
        f"  [proto] MetrikaSource fields: "
        f"{list(ms.DESCRIPTOR.fields_by_name)}\n"
    )
    sys.stderr.write(
        f"  [proto] MetrikaStream fields: "
        f"{list(stream.DESCRIPTOR.fields_by_name)}\n"
    )

    # Try stream first (most likely), then fall back to source.
    if not _set_date_range(stream, env["PERIOD_FROM"], env["PERIOD_TO"]):
        if not _set_date_range(ms, env["PERIOD_FROM"], env["PERIOD_TO"]):
            sys.stderr.write(
                "  WARNING: no usable date-range field found; the transfer\n"
                "  will pull whatever window Metrika returns by default.\n"
            )
    return settings


def main() -> int:
    env = _require_env()

    sdk = yandexcloud.SDK(iam_token=env["YC_TOKEN"])
    endpoint_stub = sdk.client(EndpointServiceStub)
    op_stub = sdk.client(OperationServiceStub)

    request = CreateEndpointRequest(
        folder_id=env["FOLDER_ID"],
        name=env["ENDPOINT_NAME"],
        settings=_build_settings(env),
    )

    sys.stderr.write(f"  [grpc] EndpointService.Create name={env['ENDPOINT_NAME']}\n")
    operation = endpoint_stub.Create(request)

    # Poll operation to completion (usually < 5s for endpoint create).
    while not operation.done:
        time.sleep(2)
        operation = op_stub.Get(GetOperationRequest(operation_id=operation.id))

    if operation.HasField("error"):
        sys.stderr.write(
            f"operation error {operation.error.code}: {operation.error.message}\n"
        )
        return 1

    endpoint = Endpoint()
    operation.response.Unpack(endpoint)
    if not endpoint.id:
        sys.stderr.write("unexpected: operation completed but no endpoint id\n")
        return 1
    print(endpoint.id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
