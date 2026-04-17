#!/usr/bin/env python3
"""
Full Metrika → ClickHouse transfer setup via Yandex Cloud SDK (gRPC).

Does end-to-end in a single process:
  1. Create Metrika-source endpoint
  2. Create ClickHouse-target endpoint
  3. Create SNAPSHOT_ONLY transfer
  4. Activate transfer
  5. Poll until DONE / ERROR

Uses proto introspection for fields that have drifted across SDK
versions (Metrika date range, clickhouse sharding layout, ...).  On
any proto mismatch, dumps the actual field list so the fix is obvious.

Env vars (all required):
  YC_TOKEN                 IAM token
  FOLDER_ID                YC folder id
  COUNTER_ID               Metrika counter
  METRIKA_TOKEN            OAuth token (sensitive, never printed)
  PERIOD_FROM, PERIOD_TO   YYYY-MM-DD (only applied if proto supports)
  CH_CLUSTER_ID            Managed ClickHouse cluster id
  CH_DB, CH_USER           Target database + user
  CH_PASSWORD              (sensitive, never printed)
  SOURCE_NAME, TARGET_NAME, TRANSFER_NAME
"""

import os
import sys
import time

try:
    import yandexcloud
    from google.protobuf.json_format import ParseDict, ParseError
    from yandex.cloud.datatransfer.v1.endpoint_pb2 import EndpointSettings, Endpoint
    from yandex.cloud.datatransfer.v1.endpoint_service_pb2 import CreateEndpointRequest
    from yandex.cloud.datatransfer.v1.endpoint_service_pb2_grpc import EndpointServiceStub
    from yandex.cloud.datatransfer.v1.transfer_pb2 import Transfer
    from yandex.cloud.datatransfer.v1.transfer_service_pb2 import (
        CreateTransferRequest, ActivateTransferRequest,
    )
    from yandex.cloud.datatransfer.v1.transfer_service_pb2_grpc import TransferServiceStub
    from yandex.cloud.operation.operation_service_pb2_grpc import OperationServiceStub
    from yandex.cloud.operation.operation_service_pb2 import GetOperationRequest
except ImportError as exc:
    sys.stderr.write(
        f"missing Python dependency: {exc}\n"
        "Install once with:  pip install yandexcloud  (inside a venv)\n"
    )
    sys.exit(2)


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


def log(msg: str) -> None:
    sys.stderr.write(f"  {msg}\n")


def _require_env(*keys: str) -> dict:
    missing = [k for k in keys if not os.environ.get(k)]
    if missing:
        sys.exit(f"missing env vars: {', '.join(missing)}")
    return {k: os.environ[k] for k in keys}


def _try_set_date_range(msg, period_from: str, period_to: str) -> bool:
    """Probe msg for a date-range sub-field; populate if found."""
    date_fields   = ("date_range", "period", "dates", "date_limits")
    from_to_pairs = (("from", "to"), ("start", "end"),
                     ("since", "until"), ("date_from", "date_to"))
    for f_name in date_fields:
        if f_name not in msg.DESCRIPTOR.fields_by_name:
            continue
        sub = getattr(msg, f_name)
        for f_from, f_to in from_to_pairs:
            if f_from in sub.DESCRIPTOR.fields_by_name:
                try:
                    ParseDict({f_from: period_from, f_to: period_to}, sub)
                    log(f"[proto] {msg.DESCRIPTOR.name}.{f_name}.{f_from}/{f_to}")
                    return True
                except ParseError:
                    continue
    return False


def _poll_operation(op_stub, operation):
    while not operation.done:
        time.sleep(2)
        operation = op_stub.Get(GetOperationRequest(operation_id=operation.id))
    if operation.HasField("error"):
        raise RuntimeError(
            f"operation {operation.id} failed: "
            f"{operation.error.code}: {operation.error.message}"
        )
    return operation


def create_metrika_source(endpoint_stub, op_stub, env: dict) -> str:
    log(f"[grpc] EndpointService.Create metrika_source name={env['SOURCE_NAME']}")
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
    log(f"[proto] MetrikaSource fields: {list(ms.DESCRIPTOR.fields_by_name)}")
    log(f"[proto] MetrikaStream fields: {list(stream.DESCRIPTOR.fields_by_name)}")

    if not _try_set_date_range(stream, env["PERIOD_FROM"], env["PERIOD_TO"]):
        if not _try_set_date_range(ms, env["PERIOD_FROM"], env["PERIOD_TO"]):
            log("[warn] no date-range field found; transfer will use API default")

    req = CreateEndpointRequest(
        folder_id=env["FOLDER_ID"],
        name=env["SOURCE_NAME"],
        settings=settings,
    )
    op = _poll_operation(op_stub, endpoint_stub.Create(req))
    ep = Endpoint()
    op.response.Unpack(ep)
    return ep.id


def create_clickhouse_target(endpoint_stub, op_stub, env: dict) -> str:
    log(f"[grpc] EndpointService.Create clickhouse_target name={env['TARGET_NAME']}")
    payload = {
        "clickhouseTarget": {
            "connection": {
                "connectionOptions": {
                    "mdbClusterId": env["CH_CLUSTER_ID"],
                    "database":     env["CH_DB"],
                    "user":         env["CH_USER"],
                    "password":     {"raw": env["CH_PASSWORD"]},
                },
            },
            "sharding": {
                "columnValueHash": {"columnName": "CounterUserIDHash"},
            },
            "cleanupPolicy": "CLICKHOUSE_CLEANUP_POLICY_DISABLED",
        },
    }
    settings = EndpointSettings()
    try:
        ParseDict(payload, settings)
    except ParseError as exc:
        ct = settings.clickhouse_target
        log(f"[proto] ClickhouseTarget fields: {list(ct.DESCRIPTOR.fields_by_name)}")
        raise SystemExit(f"clickhouse_target payload rejected: {exc}")

    req = CreateEndpointRequest(
        folder_id=env["FOLDER_ID"],
        name=env["TARGET_NAME"],
        settings=settings,
    )
    op = _poll_operation(op_stub, endpoint_stub.Create(req))
    ep = Endpoint()
    op.response.Unpack(ep)
    return ep.id


def create_and_activate_transfer(transfer_stub, op_stub, env: dict,
                                 src_id: str, tgt_id: str) -> str:
    log(f"[grpc] TransferService.Create name={env['TRANSFER_NAME']}")
    # TransferType: SNAPSHOT_ONLY lives either as Transfer.TransferType enum
    # or as module-level TransferType.  Try both.
    transfer_type = None
    if hasattr(Transfer, "TransferType"):
        transfer_type = Transfer.TransferType.Value("SNAPSHOT_ONLY")
    else:
        from yandex.cloud.datatransfer.v1 import transfer_pb2 as tpb
        transfer_type = tpb.TransferType.Value("SNAPSHOT_ONLY")
    req = CreateTransferRequest(
        folder_id=env["FOLDER_ID"],
        name=env["TRANSFER_NAME"],
        source_id=src_id,
        target_id=tgt_id,
        type=transfer_type,
    )
    op = _poll_operation(op_stub, transfer_stub.Create(req))
    tr = Transfer()
    op.response.Unpack(tr)
    transfer_id = tr.id
    log(f"[grpc] transfer created id={transfer_id}")

    log(f"[grpc] TransferService.Activate id={transfer_id}")
    op = transfer_stub.Activate(ActivateTransferRequest(transfer_id=transfer_id))
    # Activation operation finishes quickly; the actual data load is async.
    _poll_operation(op_stub, op)
    return transfer_id


def main() -> int:
    env = _require_env(
        "YC_TOKEN", "FOLDER_ID",
        "COUNTER_ID", "METRIKA_TOKEN", "PERIOD_FROM", "PERIOD_TO",
        "CH_CLUSTER_ID", "CH_DB", "CH_USER", "CH_PASSWORD",
        "SOURCE_NAME", "TARGET_NAME", "TRANSFER_NAME",
    )

    sdk = yandexcloud.SDK(iam_token=env["YC_TOKEN"])
    endpoint_stub = sdk.client(EndpointServiceStub)
    transfer_stub = sdk.client(TransferServiceStub)
    op_stub       = sdk.client(OperationServiceStub)

    src_id = create_metrika_source(endpoint_stub, op_stub, env)
    log(f"source endpoint id = {src_id}")

    tgt_id = create_clickhouse_target(endpoint_stub, op_stub, env)
    log(f"target endpoint id = {tgt_id}")

    transfer_id = create_and_activate_transfer(
        transfer_stub, op_stub, env, src_id, tgt_id
    )
    # Print the transfer id on stdout — transfer.sh captures it for polling.
    print(transfer_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
