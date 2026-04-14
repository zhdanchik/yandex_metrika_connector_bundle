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

import logging
import os
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


def _get_client() -> clickhouse_driver.Client:
    """Create a ClickHouse native-protocol client."""
    use_tls = os.environ.get("CLICKHOUSE_TLS", "1") == "1"
    default_port = 9440 if use_tls else 9000

    return clickhouse_driver.Client(
        host=os.environ["CLICKHOUSE_HOST"],
        port=int(os.environ.get("CLICKHOUSE_PORT", default_port)),
        database=os.environ.get("CLICKHOUSE_DB", "default"),
        user=os.environ.get("CLICKHOUSE_USER", "default"),
        password=os.environ["CLICKHOUSE_PASSWORD"],
        secure=use_tls,
        verify=use_tls,
        settings={
            # Allow long-running mutations (DROP PARTITION) to complete.
            "receive_timeout": 300,
            "send_timeout": 300,
        },
    )


def _substitute_params(sql: str, params: dict) -> str:
    """
    Substitute {name} placeholders with their typed values.

    All substituted values are validated as int or float before
    formatting, so there is no SQL injection risk.
    """
    return sql.format(**params)


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

    try:
        client = _get_client()
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
