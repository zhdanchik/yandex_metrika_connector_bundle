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
    from google.protobuf.json_format import ParseDict
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


def _build_settings(env: dict) -> EndpointSettings:
    """Compose MetrikaSource settings via JSON→protobuf parse.

    We construct a plain dict with the same field names as the public
    API reference, then let ParseDict do the work of mapping into the
    proto message.  This insulates us from minor proto renames between
    SDK versions.
    """
    payload = {
        "metrikaSource": {
            "counterIds": [int(env["COUNTER_ID"])],
            "token": {"raw": env["METRIKA_TOKEN"]},
            "streams": [{
                "type":    "METRIKA_STREAM_TYPE_VISITS",
                "columns": COLUMNS,
            }],
            # DateRange: two YYYY-MM-DD dates, inclusive.
            "period": {
                "from": env["PERIOD_FROM"],
                "to":   env["PERIOD_TO"],
            },
        },
    }
    settings = EndpointSettings()
    ParseDict(payload, settings, ignore_unknown_fields=False)
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
