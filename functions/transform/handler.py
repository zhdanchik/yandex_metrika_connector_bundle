"""
Yandex Cloud Function: Attribution Analytics Transform
======================================================
Entry point for the daily transformation pipeline.

Triggered by Cloud Scheduler after YC Data Transfer has finished
loading the latest Yandex Metrika data into ClickHouse.

Pipeline steps:
  1. Build touchpoint chains  (sql/02_build_chains.sql)
  2. Calculate attribution     (sql/03_attribution_models.sql)

Environment variables (injected by Terraform at deploy time):
  CLICKHOUSE_HOST      ClickHouse cluster hostname
  CLICKHOUSE_PORT      Native protocol port (default: 9440 TLS / 9000 plain)
  CLICKHOUSE_DB        Database name (default: default)
  CLICKHOUSE_USER      User (default: default)
  CLICKHOUSE_PASSWORD  Password
  CLICKHOUSE_TLS       '1' to use TLS (default: '1' for Managed CH)
  COUNTER_ID           Yandex Metrika counter ID
  GOAL_ID              Target goal ID for attribution
  LOOKBACK_DAYS        Attribution lookback window in days (default: 90)
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

# Ordered list of SQL files to execute.
_PIPELINE_STEPS = [
    ("build_chains", "02_build_chains.sql"),
    ("attribution_models", "03_attribution_models.sql"),
]


def _build_params() -> dict:
    """Read and validate configuration from environment variables."""
    raw = {
        "goal_id": os.environ["GOAL_ID"],
        "counter_id": os.environ["COUNTER_ID"],
        "lookback_days": os.environ.get("LOOKBACK_DAYS", "90"),
        "half_life": os.environ.get("HALF_LIFE_DAYS", "7.0"),
    }
    try:
        return {
            "goal_id": int(raw["goal_id"]),
            "counter_id": int(raw["counter_id"]),
            "lookback_days": int(raw["lookback_days"]),
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
        "Parameters – counter_id=%s  goal_id=%s  lookback_days=%s  half_life=%s",
        params["counter_id"],
        params["goal_id"],
        params["lookback_days"],
        params["half_life"],
    )

    try:
        client = _get_client()
    except Exception as exc:
        logger.error("Failed to connect to ClickHouse: %s", exc)
        return {"statusCode": 500, "body": f"ClickHouse connection error: {exc}"}

    for step_name, filename in _PIPELINE_STEPS:
        logger.info("Running step: %s (%s)", step_name, filename)
        try:
            _run_sql_file(client, step_name, filename, params)
            logger.info("Step %s completed successfully", step_name)
        except Exception as exc:
            logger.exception("Step %s failed: %s", step_name, exc)
            return {
                "statusCode": 500,
                "body": f"Pipeline failed at step '{step_name}': {exc}",
            }

    logger.info("Attribution transform completed successfully")
    return {"statusCode": 200, "body": "ok"}
