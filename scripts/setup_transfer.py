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

# ─────────────────────────────────────────────────────────────────────────
# Protobuf wire-format helpers.  The YC backend's MetrikaSource accepts a
# `period` sub-message (visible in the UI as "Период выгрузки данных")
# that is NOT in the public proto.  We inject it as an unknown field;
# field number is a best-guess (default 4 — first free slot after
# counter_ids=1, token=2, streams=3).  Override via PERIOD_FIELD_NUMBER
# / PERIOD_FROM_TAG / PERIOD_TO_TAG env vars if our guess is wrong.
# ─────────────────────────────────────────────────────────────────────────

def _wire_varint(n: int) -> bytes:
    out = bytearray()
    while n > 0x7F:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def _wire_tag(field_number: int, wire_type: int) -> bytes:
    return _wire_varint((field_number << 3) | wire_type)


def _wire_string(field_number: int, value: str) -> bytes:
    data = value.encode("utf-8")
    return _wire_tag(field_number, 2) + _wire_varint(len(data)) + data


def _wire_submessage(field_number: int, inner: bytes) -> bytes:
    return _wire_tag(field_number, 2) + _wire_varint(len(inner)) + inner


def _build_period_unknown_field(period_from: str, period_to: str) -> bytes:
    outer_tag = int(os.environ.get("PERIOD_FIELD_NUMBER", "4"))
    from_tag  = int(os.environ.get("PERIOD_FROM_TAG", "1"))
    to_tag    = int(os.environ.get("PERIOD_TO_TAG", "2"))
    inner = _wire_string(from_tag, period_from) + _wire_string(to_tag, period_to)
    return _wire_submessage(outer_tag, inner)

try:
    import grpc
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
    log(f"[proto] MetrikaSource public fields: {list(ms.DESCRIPTOR.fields_by_name)}")

    # Inject `period` as an unknown protobuf field so the backend accepts the
    # snapshot transfer.  See wire-format helpers + comment above.
    period_bytes = _build_period_unknown_field(env["PERIOD_FROM"], env["PERIOD_TO"])
    ms_bytes = ms.SerializeToString() + period_bytes
    ms.Clear()
    ms.MergeFromString(ms_bytes)
    log(
        f"[proto] injected period unknown field "
        f"(outer_tag={os.environ.get('PERIOD_FIELD_NUMBER', '4')}, "
        f"from={env['PERIOD_FROM']} to={env['PERIOD_TO']})"
    )

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


def _print_ui_instructions(src_id: str, tgt_id: str, env: dict) -> None:
    sys.stderr.write(
        "\n"
        "  ══ Manual step required ══════════════════════════════════════════\n"
        "\n"
        "  The Metrika 'period' field isn't in the public YC proto, so our\n"
        "  best-guess wire-format injection (unknown field at tag 4) was\n"
        "  rejected.  Fix it in the UI or probe the correct tag number.\n"
        "\n"
        "  OPTION A — set period in the endpoint via UI:\n"
        f"    1. Open https://console.yandex.cloud/folders/{env['FOLDER_ID']}/data-transfer/endpoints\n"
        f"    2. Edit endpoint: {env['SOURCE_NAME']} (id={src_id})\n"
        "       → expand 'Период выгрузки данных'\n"
        f"       → Начало = {env['PERIOD_FROM']},  Конец = {env['PERIOD_TO']}\n"
        "       → Apply\n"
        "    3. Then go to Transfers → Create transfer:\n"
        f"       Source = {src_id} ({env['SOURCE_NAME']})\n"
        f"       Target = {tgt_id} ({env['TARGET_NAME']})\n"
        f"       Name   = {env['TRANSFER_NAME']}\n"
        "       Type   = Копирование (snapshot)\n"
        "    4. Activate.\n"
        "\n"
        "  OPTION B — probe the real field tag from a UI-created endpoint:\n"
        f"    PROBE_ENDPOINT_ID={src_id} python3 scripts/setup_transfer.py\n"
        "    The hex dump will show the real tag number for 'period'.\n"
        "    Then re-run transfer.sh with:\n"
        "      PERIOD_FIELD_NUMBER=<real-tag> ./scripts/transfer.sh\n"
        "\n"
        "  After the transfer finishes: ./scripts/smoke.sh\n"
        "\n"
    )


def _walk_wire(raw: bytes, known_numbers: set, depth: int = 0) -> list:
    """Return list of (field_number, wire_type, payload_bytes, is_known)."""
    results = []
    i = 0
    while i < len(raw):
        try:
            key, n = _read_varint(raw, i); i += n
        except IndexError:
            break
        fn, wt = key >> 3, key & 7
        if wt == 2:                       # length-delimited
            length, n = _read_varint(raw, i); i += n
            chunk = raw[i:i+length]; i += length
            results.append((fn, wt, chunk, fn in known_numbers))
        elif wt == 0:                     # varint
            v, n = _read_varint(raw, i); i += n
            results.append((fn, wt, v, fn in known_numbers))
        elif wt == 1:                     # fixed64
            results.append((fn, wt, raw[i:i+8], fn in known_numbers)); i += 8
        elif wt == 5:                     # fixed32
            results.append((fn, wt, raw[i:i+4], fn in known_numbers)); i += 4
        else:
            break
    return results


def _looks_like_date(b: bytes) -> bool:
    s = b.decode("utf-8", errors="ignore")
    return (
        len(s) in (10,) and s[4] == "-" and s[7] == "-" and
        s.replace("-", "").isdigit()
    )


def _decode_nested(chunk: bytes, indent: str = "    ") -> None:
    """Try to decode chunk as submessage; print dates/strings if found."""
    for (fn, wt, payload, _) in _walk_wire(chunk, set()):
        if wt == 2 and isinstance(payload, bytes):
            if _looks_like_date(payload):
                sys.stderr.write(f"{indent}inner field={fn} DATE={payload.decode()!r}\n")
            else:
                try:
                    sys.stderr.write(f"{indent}inner field={fn} str={payload.decode()!r}\n")
                except UnicodeDecodeError:
                    sys.stderr.write(f"{indent}inner field={fn} nested_hex={payload.hex()}\n")
        else:
            sys.stderr.write(f"{indent}inner field={fn} wt={wt} value={payload!r}\n")


def probe_transfer(sdk, transfer_id: str) -> int:
    """Fetch a Transfer and dump its full wire bytes.

    Use when probe_endpoint shows no unknown fields — the period might
    live on the transfer, not the endpoint.  Manually create a full
    transfer in the UI first, then run:

        PROBE_TRANSFER_ID=<id> python3 scripts/setup_transfer.py
    """
    from yandex.cloud.datatransfer.v1.transfer_service_pb2 import GetTransferRequest
    transfer_stub = sdk.client(TransferServiceStub)
    tr = transfer_stub.Get(GetTransferRequest(transfer_id=transfer_id))
    raw = tr.SerializeToString()
    known = {f.number for f in tr.DESCRIPTOR.fields_by_name.values()}

    log(f"transfer {transfer_id}")
    log(f"  proto-known numbers on Transfer: {sorted(known)}")
    log(f"  raw bytes ({len(raw)}): {raw.hex()[:400]}{'...' if len(raw) > 200 else ''}")
    log("")

    for (fn, wt, payload, is_known) in _walk_wire(raw, known):
        marker = "known" if is_known else "UNKNOWN"
        if wt == 2 and isinstance(payload, bytes):
            log(f"  field={fn} wt={wt} len={len(payload)} [{marker}]  hex={payload.hex()[:200]}")
            _decode_nested(payload)
        else:
            log(f"  field={fn} wt={wt} value={payload!r} [{marker}]")

    log("")
    log("→ Look for DATE=... strings anywhere in the output.  Their")
    log("  location tells you where the YC backend stores the period.")
    return 0


def probe_endpoint(sdk, endpoint_id: str) -> int:
    """Fetch a Metrika-source endpoint and reveal the period field tag.

    Use this after creating a source endpoint in the UI with the period
    filled in.  The script dumps every field in the received wire bytes,
    marks which are unknown to our public proto, and tries to decode
    sub-messages looking for date-shaped strings.
    """
    from yandex.cloud.datatransfer.v1.endpoint_service_pb2 import GetEndpointRequest
    endpoint_stub = sdk.client(EndpointServiceStub)
    ep = endpoint_stub.Get(GetEndpointRequest(endpoint_id=endpoint_id))
    if not ep.settings.HasField("metrika_source"):
        sys.exit(f"endpoint {endpoint_id} is not a Metrika source")

    ms  = ep.settings.metrika_source
    raw = ms.SerializeToString()
    known = {f.number for f in ms.DESCRIPTOR.fields_by_name.values()}

    log(f"endpoint {endpoint_id}")
    log(f"  proto-known numbers on MetrikaSource: {sorted(known)}")
    log(f"  raw bytes ({len(raw)}): {raw.hex()}")
    log("")

    for (fn, wt, payload, is_known) in _walk_wire(raw, known):
        marker = "known" if is_known else "UNKNOWN"
        if wt == 2 and isinstance(payload, bytes):
            log(f"  field={fn} wt={wt} len={len(payload)} [{marker}]  hex={payload.hex()}")
            _decode_nested(payload)
        else:
            log(f"  field={fn} wt={wt} value={payload!r} [{marker}]")

    log("")
    log("→ Look for an UNKNOWN field whose submessage contains DATE=... lines.")
    log("  That field number is your PERIOD_FIELD_NUMBER.")
    log("  Inner tags for from/to are usually 1/2 unless shown otherwise.")
    return 0


def _read_varint(buf: bytes, start: int):
    value, shift = 0, 0
    i = start
    while True:
        b = buf[i]
        value |= (b & 0x7F) << shift
        i += 1
        if not (b & 0x80):
            return value, i - start
        shift += 7


def main() -> int:
    # Probe mode — dump an existing endpoint/transfer's wire bytes and exit.
    probe_ep = os.environ.get("PROBE_ENDPOINT_ID")
    probe_tr = os.environ.get("PROBE_TRANSFER_ID")
    if probe_ep or probe_tr:
        _require_env("YC_TOKEN")
        sdk = yandexcloud.SDK(iam_token=os.environ["YC_TOKEN"])
        if probe_ep:
            probe_endpoint(sdk, probe_ep)
        if probe_tr:
            probe_transfer(sdk, probe_tr)
        return 0

    # Required always
    env = _require_env(
        "YC_TOKEN", "FOLDER_ID",
        "CH_CLUSTER_ID", "CH_DB", "CH_USER", "CH_PASSWORD",
        "SOURCE_NAME", "TARGET_NAME", "TRANSFER_NAME",
    )
    # Required only when we auto-create source
    existing_src = os.environ.get("EXISTING_SOURCE_ID")
    if not existing_src:
        env.update(_require_env(
            "COUNTER_ID", "METRIKA_TOKEN", "PERIOD_FROM", "PERIOD_TO",
        ))

    sdk = yandexcloud.SDK(iam_token=env["YC_TOKEN"])
    endpoint_stub = sdk.client(EndpointServiceStub)
    transfer_stub = sdk.client(TransferServiceStub)
    op_stub       = sdk.client(OperationServiceStub)

    if existing_src:
        log(f"using existing source endpoint id = {existing_src}")
        src_id = existing_src
    else:
        src_id = create_metrika_source(endpoint_stub, op_stub, env)
        log(f"source endpoint id = {src_id}")

    tgt_id = create_clickhouse_target(endpoint_stub, op_stub, env)
    log(f"target endpoint id = {tgt_id}")

    try:
        transfer_id = create_and_activate_transfer(
            transfer_stub, op_stub, env, src_id, tgt_id
        )
        print(transfer_id)
        return 0
    except grpc.RpcError as exc:
        detail = getattr(exc, "details", lambda: str(exc))()
        if "period" in detail.lower():
            _print_ui_instructions(src_id, tgt_id, env)
            # stdout empty → transfer.sh detects and prints matching guidance
            return 0
        raise


if __name__ == "__main__":
    sys.exit(main())
