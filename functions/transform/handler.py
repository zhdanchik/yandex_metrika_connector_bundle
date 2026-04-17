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
  4. Attribution models  (sql/05_attribution_models.sql)

Environment variables (injected by Terraform at deploy time):
  CLICKHOUSE_HOST       ClickHouse cluster hostname
  CLICKHOUSE_HTTP_PORT  HTTPS port (default: 8443 TLS / 8123 plain)
  CLICKHOUSE_DB         Database name (default: default)
  CLICKHOUSE_USER       User (default: default)
  CLICKHOUSE_TLS        '1' to use TLS (default: '1' for Managed CH)
  COUNTER_ID            Yandex Metrika counter ID
  GOAL_ID               Target goal ID for attribution
  HALF_LIFE_DAYS        Time-decay half-life in days (default: 7.0)
"""

import json
import logging
import os
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s – %(message)s",
)

# SQL files bundled alongside this handler in the function zip.
_SQL_DIR = Path(__file__).parent / "sql"

# Query to compute the 95th-percentile inter-visit gap (seconds).
_VISIT_MAX_TIMEDIFF_QUERY = """
SELECT toUInt64(quantile(0.95)(diff)) AS p95
FROM (
    SELECT
        arraySort(groupArray(UTCStartTime)) AS utc_times,
        arrayEnumerate(utc_times)           AS indexes,
        arraySlice(
            arrayMap(
                y -> if(y = 1,
                    toInt64(0),
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

_DEFAULT_VISIT_MAX_TIMEDIFF = 1800

_METADATA_TOKEN_URL = (
    "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token"
)
_LOCKBOX_PAYLOAD_URL = (
    "https://payload.lockbox.api.cloud.yandex.net/lockbox/v1/secrets/{secret_id}/payload"
)

_YC_CA_URL = "https://storage.yandexcloud.net/cloud-certs/CA.pem"
_YC_CA_TMP  = "/tmp/yandex-ca.pem"


def _get_lockbox_payload() -> dict:
    """Fetch all secret entries from Yandex Lockbox via instance metadata IAM token."""
    secret_id = os.environ["LOCKBOX_SECRET_ID"]

    meta_req = urllib.request.Request(
        _METADATA_TOKEN_URL,
        headers={"Metadata-Flavor": "Google"},
    )
    with urllib.request.urlopen(meta_req, timeout=5) as resp:
        iam_token = json.loads(resp.read())["access_token"]

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


def _ca_cert_path() -> str:
    """Return path to the Yandex Cloud CA certificate, downloading if needed."""
    bundled = Path(__file__).parent / "CA.pem"
    if bundled.exists():
        return str(bundled)
    logger.info("CA.pem not bundled; downloading from %s", _YC_CA_URL)
    urllib.request.urlretrieve(_YC_CA_URL, _YC_CA_TMP)
    return _YC_CA_TMP


def _ch_conn(secrets: dict) -> dict:
    """Build ClickHouse HTTP connection parameters.

    Uses the HTTP/HTTPS interface (default port 8443 for TLS, 8123 for plain)
    instead of the native TCP protocol, which avoids clickhouse_driver
    INSERT-detection issues that produce spurious 'Empty query' errors.
    """
    use_tls = os.environ.get("CLICKHOUSE_TLS", "1") == "1"
    default_http_port = 8443 if use_tls else 8123
    http_port = int(os.environ.get("CLICKHOUSE_HTTP_PORT", default_http_port))

    ssl_ctx: ssl.SSLContext | None = None
    if use_tls:
        ca_path = _ca_cert_path()
        ssl_ctx = ssl.create_default_context(cafile=ca_path)
        logger.info("TLS enabled, ca_cert=%s, http_port=%d", ca_path, http_port)
    else:
        logger.info("TLS disabled, http_port=%d", http_port)

    return dict(
        host=os.environ["CLICKHOUSE_HOST"],
        http_port=http_port,
        db=os.environ.get("CLICKHOUSE_DB", "default"),
        user=os.environ.get("CLICKHOUSE_USER", "default"),
        password=secrets["clickhouse_password"],
        ssl_ctx=ssl_ctx,
    )


def _ch_query(conn: dict, sql: str) -> str:
    """Execute a SQL statement via the ClickHouse HTTP interface.

    Returns the response body (empty string for DDL/INSERT, TSV rows for
    SELECT).  Raises RuntimeError on any server-side error.
    """
    scheme = "https" if conn["ssl_ctx"] is not None else "http"
    url = (
        f"{scheme}://{conn['host']}:{conn['http_port']}/"
        f"?database={urllib.parse.quote(conn['db'])}"
        "&max_execution_time=300"
    )
    data = sql.encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("X-ClickHouse-User", conn["user"])
    req.add_header("X-ClickHouse-Key", conn["password"])

    urlopen_kwargs: dict = {"timeout": 310}
    if conn["ssl_ctx"] is not None:
        urlopen_kwargs["context"] = conn["ssl_ctx"]

    try:
        with urllib.request.urlopen(req, **urlopen_kwargs) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"ClickHouse HTTP {exc.code}: {body.strip()}") from exc


def _substitute_params(sql: str, params: dict) -> str:
    """Substitute {name} placeholders with typed values (int/float only)."""
    def _replace(match: re.Match) -> str:
        key = match.group(1)
        return str(params[key]) if key in params else match.group(0)
    return re.sub(r"\{(\w+)\}", _replace, sql)


def _split_statements(sql: str) -> list[str]:
    """Split SQL on semicolons, ignoring semicolons inside -- line comments."""
    statements: list[str] = []
    current: list[str] = []

    for line in sql.splitlines(keepends=True):
        comment_pos = line.find("--")
        semi_pos = line.find(";")

        if semi_pos == -1 or (comment_pos != -1 and comment_pos < semi_pos):
            # No semicolon, or the only semicolon is inside a -- comment
            current.append(line)
        else:
            # Semicolon is in actual SQL (before any comment on this line)
            current.append(line[:semi_pos])
            stmt = "".join(current).strip()
            if stmt:
                statements.append(stmt)
            current = []
            tail = line[semi_pos + 1:]
            if tail.strip():
                current.append(tail)

    tail_stmt = "".join(current).strip()
    if tail_stmt:
        statements.append(tail_stmt)

    return statements


def _run_sql_file(
    conn: dict,
    step_name: str,
    filename: str,
    params: dict,
) -> None:
    """Load a SQL file, substitute parameters, and execute each statement."""
    sql_path = _SQL_DIR / filename
    raw_sql = sql_path.read_text(encoding="utf-8")
    sql = _substitute_params(raw_sql, params)
    statements = _split_statements(sql)

    logger.info("[%s] %d statements to execute", step_name, len(statements))
    for idx, stmt in enumerate(statements, 1):
        preview = stmt[:120].replace("\n", " ")
        logger.info("[%s] %d/%d  %s…", step_name, idx, len(statements), preview)
        try:
            _ch_query(conn, stmt)
        except Exception as exc:
            logger.error(
                "[%s] Statement %d/%d failed: %s",
                step_name, idx, len(statements), exc,
            )
            raise


def _compute_visit_max_timediff(conn: dict) -> int:
    """Compute the 95th-percentile inter-visit gap from visits_prepared.

    Returns the computed value in seconds, or a default fallback.
    """
    try:
        result = _ch_query(conn, _VISIT_MAX_TIMEDIFF_QUERY).strip()
        if result:
            value = int(result.split("\t")[0])
            if value > 0:
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
    """Yandex Cloud Function entry point."""
    logger.info("Attribution transform started.  event=%s", event)

    try:
        params = _build_params()
    except (KeyError, RuntimeError) as exc:
        logger.error("Configuration error: %s", exc)
        return {"statusCode": 500, "body": f"Configuration error: {exc}"}

    logger.info(
        "Parameters – counter_id=%s  goal_id=%s  half_life=%s",
        params["counter_id"], params["goal_id"], params["half_life"],
    )

    try:
        secrets = _get_lockbox_payload()
    except Exception as exc:
        logger.error("Failed to fetch Lockbox payload: %s", exc)
        return {"statusCode": 500, "body": f"Lockbox error: {exc}"}

    try:
        conn = _ch_conn(secrets)
        _ch_query(conn, "SELECT 1")
        logger.info("ClickHouse connectivity OK")
    except Exception as exc:
        logger.error("Failed to connect to ClickHouse: %s", exc)
        return {"statusCode": 500, "body": f"ClickHouse connection error: {exc}"}

    # ----------------------------------------------------------------
    # Step 1: Prepare visits (flatten raw → visits_prepared)
    # ----------------------------------------------------------------
    logger.info("Step 1/4: prepare_visits — truncating visits_prepared")
    try:
        _ch_query(conn, "TRUNCATE TABLE visits_prepared")
    except Exception as exc:
        logger.exception("TRUNCATE visits_prepared failed: %s", exc)
        return {"statusCode": 500, "body": f"Pipeline failed at step 'prepare_visits' (truncate): {exc}"}
    try:
        _run_sql_file(conn, "prepare_visits", "02_prepare_visits.sql", params)
    except Exception as exc:
        logger.exception("Step prepare_visits failed: %s", exc)
        return {"statusCode": 500, "body": f"Pipeline failed at step 'prepare_visits': {exc}"}

    # ----------------------------------------------------------------
    # Step 2: Compute session timeout (95th-percentile inter-visit gap)
    # ----------------------------------------------------------------
    logger.info("Step 2/4: compute visit_max_timediff")
    visit_max_timediff = _compute_visit_max_timediff(conn)

    combine_params = {**params, "visit_max_timediff": visit_max_timediff}

    # ----------------------------------------------------------------
    # Step 3: Combine visits into session chains (visits_combined)
    # ----------------------------------------------------------------
    logger.info(
        "Step 3/4: combine_visits — dropping partition %s  (visit_max_timediff=%d s)",
        params["goal_id"], visit_max_timediff,
    )
    try:
        _ch_query(conn, f"ALTER TABLE visits_combined DROP PARTITION {params['goal_id']}")
    except Exception as exc:
        logger.exception("DROP PARTITION visits_combined failed: %s", exc)
        return {"statusCode": 500, "body": f"Pipeline failed at step 'combine_visits' (drop partition): {exc}"}
    try:
        _run_sql_file(conn, "combine_visits", "03_combine_visits.sql", combine_params)
    except Exception as exc:
        logger.exception("Step combine_visits failed: %s", exc)
        return {"statusCode": 500, "body": f"Pipeline failed at step 'combine_visits': {exc}"}

    # ----------------------------------------------------------------
    # Step 4: Attribution models
    # ----------------------------------------------------------------
    logger.info("Step 4/4: attribution_models — dropping partition %s", params["goal_id"])
    try:
        _ch_query(conn, f"ALTER TABLE attribution_results DROP PARTITION {params['goal_id']}")
    except Exception as exc:
        logger.exception("DROP PARTITION attribution_results failed: %s", exc)
        return {"statusCode": 500, "body": f"Pipeline failed at step 'attribution_models' (drop partition): {exc}"}
    try:
        _run_sql_file(conn, "attribution_models", "05_attribution_models.sql", params)
    except Exception as exc:
        logger.exception("Step attribution_models failed: %s", exc)
        return {"statusCode": 500, "body": f"Pipeline failed at step 'attribution_models': {exc}"}

    logger.info("Attribution transform completed successfully")
    return {"statusCode": 200, "body": "ok"}
