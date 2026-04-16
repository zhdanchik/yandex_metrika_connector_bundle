"""
Yandex Cloud Function: Attribution Analytics Transform
======================================================
Entry point for the daily transformation pipeline.

Triggered by Cloud Scheduler after YC Data Transfer has finished
loading the latest Yandex Metrika data into ClickHouse.

Pipeline steps:
  1. Prepare visits      (sql/02_prepare_visits.sql)
  2. Compute visit_max_timediff  (inline query — 95th-percentile inter-visit gap)
  3. Combine visits      (sql/03_combine_visits.sql)
  4. Build chains        (sql/04_build_chains.sql)
  5. Attribution models  (sql/05_attribution_models.sql)

Environment variables (injected by Terraform at deploy time):
  CLICKHOUSE_HOST      ClickHouse cluster hostname
  CLICKHOUSE_PORT      Native protocol port (default: 9440 TLS / 9000 plain)
  CLICKHOUSE_DB        Database name (default: default)
  CLICKHOUSE_USER      User (default: default)
  CLICKHOUSE_PASSWORD  Password
  CLICKHOUSE_TLS       '1' to use TLS (default: '1' for Managed CH)
  COUNTER_ID           Yandex Metrika counter ID
  GOAL_ID              Target goal ID for attribution
  HALF_LIFE_DAYS       Time-decay half-life in days (default: 7.0)
"""

import json
import logging
import os
import re
import urllib.request
from pathlib import Path
from typing import Any

import clickhouse_driver

logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s – %(message)s",
)

# SQL files bundled alongside this handler in the function zip.
_SQL_DIR = Path(__file__).parent / "sql"

# Query to compute the 95th-percentile inter-visit gap (seconds).
# Mirrors visit_diff_percentile_q from analyse_channels_chain.py.
# Executed after visits_prepared is populated; result is passed as
# {visit_max_timediff} to 03_combine_visits.sql.
_VISIT_MAX_TIMEDIFF_QUERY = """
SELECT toUInt64(quantile(0.95)(diff)) AS p95
FROM (
    SELECT
        arraySort(groupArray(UTCStartTime)) AS utc_times,
        arrayEnumerate(utc_times)           AS indexes,
        arraySlice(
            arrayMap(
                y -> if(y = 1,
                    toUInt64(0),
                    toUInt64(utc_times[y]) - toUInt64(utc_times[y - 1])
                ),
                indexes
            ),
            2
        ) AS diffs
    FROM visits_prepared
    GROUP BY CounterID, UserID
    HAVING length(utc_times) > 1
)
ARRAY JOIN diffs AS diff
WHERE diff > 0
"""

# Default fallback when visits_prepared has no multi-visit users
# (e.g. first run with very little data).  30 minutes in seconds.
_DEFAULT_VISIT_MAX_TIMEDIFF = 1800

# Metadata service endpoint (available inside Yandex Cloud Functions).
_METADATA_TOKEN_URL = (
    "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token"
)
_LOCKBOX_PAYLOAD_URL = (
    "https://payload.lockbox.api.cloud.yandex.net/lockbox/v1/secrets/{secret_id}/payload"
)


def _get_lockbox_payload() -> dict:
    """
    Fetch all secret entries from Yandex Lockbox.

    Uses the IAM token obtained from the instance metadata service so
    that no credentials are stored in environment variables.  The
    function's service account must hold the lockbox.payloadViewer role
    on the secret (granted by Terraform).

    Returns a dict mapping entry key → text value.
    """
    secret_id = os.environ["LOCKBOX_SECRET_ID"]

    # Step 1: get a short-lived IAM token from the metadata service.
    meta_req = urllib.request.Request(
        _METADATA_TOKEN_URL,
        headers={"Metadata-Flavor": "Google"},
    )
    with urllib.request.urlopen(meta_req, timeout=5) as resp:
        iam_token = json.loads(resp.read())["access_token"]

    # Step 2: fetch the secret payload using the IAM token.
    secret_req = urllib.request.Request(
        _LOCKBOX_PAYLOAD_URL.format(secret_id=secret_id),
        headers={"Authorization": f"Bearer {iam_token}"},
    )
    with urllib.request.urlopen(secret_req, timeout=10) as resp:
        entries = json.loads(resp.read())["entries"]

    return {e["key"]: e["textValue"] for e in entries}


def _build_params() -> dict:
    """Read and validate configuration from environment variables."""
    raw = {
        "goal_id": os.environ["GOAL_ID"],
        "counter_id": os.environ["COUNTER_ID"],
        "half_life": os.environ.get("HALF_LIFE_DAYS", "7.0"),
    }
    try:
        return {
            "goal_id": int(raw["goal_id"]),
            "counter_id": int(raw["counter_id"]),
            "half_life": float(raw["half_life"]),
        }
    except (ValueError, TypeError) as exc:
        raise RuntimeError(f"Invalid environment variable: {exc}") from exc


_YC_CA_URL = "https://storage.yandexcloud.net/cloud-certs/CA.pem"
_YC_CA_TMP  = "/tmp/yandex-ca.pem"


def _ca_cert_path() -> str:
    """Return a path to the Yandex Cloud CA certificate.

    Prefers the file bundled with the function zip (CA.pem next to
    handler.py).  Falls back to downloading from Yandex Object Storage,
    which is reachable from Cloud Functions without extra network rules.
    """
    bundled = Path(__file__).parent / "CA.pem"
    if bundled.exists():
        return str(bundled)

    logger.info("CA.pem not bundled; downloading from %s", _YC_CA_URL)
    urllib.request.urlretrieve(_YC_CA_URL, _YC_CA_TMP)
    return _YC_CA_TMP


def _get_client(secrets: dict) -> clickhouse_driver.Client:
    """Create a ClickHouse native-protocol client.

    ``secrets`` is the dict returned by _get_lockbox_payload().
    The password is never stored in environment variables.
    """
    use_tls = os.environ.get("CLICKHOUSE_TLS", "1") == "1"
    default_port = 9440 if use_tls else 9000

    ca_path = _ca_cert_path() if use_tls else None
    logger.info("TLS=%s  ca_cert=%s", use_tls, ca_path)

    return clickhouse_driver.Client(
        host=os.environ["CLICKHOUSE_HOST"],
        port=int(os.environ.get("CLICKHOUSE_PORT", default_port)),
        database=os.environ.get("CLICKHOUSE_DB", "default"),
        user=os.environ.get("CLICKHOUSE_USER", "default"),
        password=secrets["clickhouse_password"],
        secure=use_tls,
        verify=use_tls,
        ca_certs=ca_path,
        settings={
            # Allow long-running mutations (DROP PARTITION) to complete.
            "receive_timeout": 300,
            "send_timeout": 300,
        },
    )


def _substitute_params(sql: str, params: dict) -> str:
    """
    Substitute {name} placeholders with their typed values.

    Only replaces placeholders whose names exist in params; unknown
    {names} (e.g. in SQL comments) are left untouched.  All substituted
    values are int or float, so there is no SQL injection risk.
    """
    def _replace(match: re.Match) -> str:
        key = match.group(1)
        return str(params[key]) if key in params else match.group(0)

    return re.sub(r"\{(\w+)\}", _replace, sql)


def _split_statements(sql: str) -> list[str]:
    """Split a SQL file into individual statements on ';'."""
    return [s.strip() for s in sql.split(";") if s.strip()]


def _run_sql_file(
    client: clickhouse_driver.Client,
    step_name: str,
    filename: str,
    params: dict,
) -> None:
    """Load a SQL file, substitute parameters, and execute each statement."""
    sql_path = _SQL_DIR / filename
    raw_sql = sql_path.read_text(encoding="utf-8")
    sql = _substitute_params(raw_sql, params)
    statements = _split_statements(sql)

    # Disconnect before the first statement so any previous query's
    # unread packets (e.g. from _compute_visit_max_timediff) are flushed.
    try:
        client.disconnect()
    except Exception:
        pass

    logger.info("[%s] %d statements to execute", step_name, len(statements))
    for idx, stmt in enumerate(statements, 1):
        preview = stmt[:120].replace("\n", " ")
        logger.info("[%s] %d/%d  %s…", step_name, idx, len(statements), preview)
        try:
            client.execute(stmt)
        except Exception as exc:
            logger.error(
                "[%s] Statement %d/%d failed: %s\n%s",
                step_name, idx, len(statements), exc, stmt,
            )
            raise
        finally:
            # Disconnect after each statement except the last so that DDL
            # operations (ALTER TABLE, TRUNCATE) don't leave unread Progress
            # packets in the TCP buffer, which would confuse the next query.
            if idx < len(statements):
                try:
                    client.disconnect()
                except Exception:
                    pass


def _compute_visit_max_timediff(client: clickhouse_driver.Client) -> int:
    """
    Compute the 95th-percentile inter-visit gap in seconds from
    visits_prepared.  Mirrors visit_diff_percentile_q from
    analyse_channels_chain.py.

    Returns the computed value, or a default fallback if there are
    not enough multi-visit users to compute a percentile.
    """
    try:
        rows = client.execute(_VISIT_MAX_TIMEDIFF_QUERY)
        if rows and rows[0][0] and rows[0][0] > 0:
            value = int(rows[0][0])
            logger.info("visit_max_timediff (p95) = %d seconds", value)
            return value
    except Exception as exc:
        logger.warning(
            "Could not compute visit_max_timediff: %s — using default %d s",
            exc, _DEFAULT_VISIT_MAX_TIMEDIFF,
        )

    logger.warning(
        "visit_max_timediff fallback: %d s (no multi-visit data found)",
        _DEFAULT_VISIT_MAX_TIMEDIFF,
    )
    return _DEFAULT_VISIT_MAX_TIMEDIFF


def handler(event: dict, context: Any) -> dict:
    """
    Yandex Cloud Function entry point.

    ``event`` and ``context`` follow the standard YC Function contract.
    The function returns an HTTP-compatible response dict so that it can
    also be wired to a Trigger (which ignores the return value) or called
    via HTTPS for manual runs.
    """
    logger.info("Attribution transform started.  event=%s", event)

    try:
        params = _build_params()
    except (KeyError, RuntimeError) as exc:
        logger.error("Configuration error: %s", exc)
        return {"statusCode": 500, "body": f"Configuration error: {exc}"}

    logger.info(
        "Parameters – counter_id=%s  goal_id=%s  half_life=%s",
        params["counter_id"],
        params["goal_id"],
        params["half_life"],
    )

    # Fetch secrets from Lockbox (password is never stored in env vars).
    try:
        secrets = _get_lockbox_payload()
    except Exception as exc:
        logger.error("Failed to fetch Lockbox payload: %s", exc)
        return {"statusCode": 500, "body": f"Lockbox error: {exc}"}

    try:
        client = _get_client(secrets)
    except Exception as exc:
        logger.error("Failed to connect to ClickHouse: %s", exc)
        return {"statusCode": 500, "body": f"ClickHouse connection error: {exc}"}

    # ----------------------------------------------------------------
    # Step 1: Prepare visits (flatten raw → visits_prepared)
    # ----------------------------------------------------------------
    logger.info("Step 1/4: prepare_visits")
    try:
        _run_sql_file(client, "prepare_visits", "02_prepare_visits.sql", params)
    except Exception as exc:
        logger.exception("Step prepare_visits failed: %s", exc)
        return {"statusCode": 500, "body": f"Pipeline failed at step 'prepare_visits': {exc}"}

    # ----------------------------------------------------------------
    # Step 2: Compute session timeout (95th-percentile inter-visit gap)
    # ----------------------------------------------------------------
    logger.info("Step 2/4: compute visit_max_timediff")
    visit_max_timediff = _compute_visit_max_timediff(client)

    combine_params = {**params, "visit_max_timediff": visit_max_timediff}

    # ----------------------------------------------------------------
    # Step 3: Combine visits into session chains (visits_combined)
    # ----------------------------------------------------------------
    logger.info("Step 3/4: combine_visits  (visit_max_timediff=%d s)", visit_max_timediff)
    try:
        _run_sql_file(client, "combine_visits", "03_combine_visits.sql", combine_params)
    except Exception as exc:
        logger.exception("Step combine_visits failed: %s", exc)
        return {"statusCode": 500, "body": f"Pipeline failed at step 'combine_visits': {exc}"}

    # ----------------------------------------------------------------
    # Step 4: Attribution models
    # ----------------------------------------------------------------
    logger.info("Step 4/4: attribution_models")
    try:
        _run_sql_file(client, "attribution_models", "05_attribution_models.sql", params)
    except Exception as exc:
        logger.exception("Step attribution_models failed: %s", exc)
        return {"statusCode": 500, "body": f"Pipeline failed at step 'attribution_models': {exc}"}

    logger.info("Attribution transform completed successfully")
    return {"statusCode": 200, "body": "ok"}
