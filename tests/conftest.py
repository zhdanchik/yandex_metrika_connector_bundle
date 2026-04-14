"""
pytest configuration.

Integration tests (marked with @pytest.mark.integration) require a
running ClickHouse instance.  They are skipped by default and enabled
with the --integration flag:

    pytest --integration tests/

Environment variables for integration tests:
    TEST_CH_HOST      ClickHouse host  (default: localhost)
    TEST_CH_PORT      Native port      (default: 9000)
    TEST_CH_USER      User             (default: default)
    TEST_CH_PASSWORD  Password         (default: '')
    TEST_CH_DB        Database         (default: test_attribution)
"""

import os
import time

import pytest


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--integration",
        action="store_true",
        default=False,
        help="Run integration tests that require a live ClickHouse instance.",
    )


def pytest_collection_modifyitems(
    config: pytest.Config,
    items: list[pytest.Item],
) -> None:
    if config.getoption("--integration"):
        return  # run everything

    skip = pytest.mark.skip(reason="Requires --integration flag and live ClickHouse")
    for item in items:
        if "integration" in item.keywords:
            item.add_marker(skip)


# ---------------------------------------------------------------------------
# Integration fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def ch_client():
    """Session-scoped ClickHouse client for integration tests."""
    try:
        import clickhouse_driver  # noqa: PLC0415
    except ImportError:
        pytest.skip("clickhouse-driver not installed")

    host = os.environ.get("TEST_CH_HOST", "localhost")
    port = int(os.environ.get("TEST_CH_PORT", 9000))
    user = os.environ.get("TEST_CH_USER", "default")
    password = os.environ.get("TEST_CH_PASSWORD", "")

    client = clickhouse_driver.Client(
        host=host,
        port=port,
        user=user,
        password=password,
    )
    try:
        client.execute("SELECT 1")
    except Exception as exc:
        pytest.skip(f"ClickHouse not reachable at {host}:{port} – {exc}")

    return client


@pytest.fixture()
def ch_db(ch_client):
    """
    Function-scoped isolated test database.

    Creates a fresh database, yields (client, db_name), then drops it.
    """
    import clickhouse_driver  # noqa: PLC0415

    db_name = f"test_attribution_{int(time.time() * 1000)}"
    ch_client.execute(f"CREATE DATABASE {db_name}")

    # Create a client bound to the test database
    db_client = clickhouse_driver.Client(
        host=ch_client.connection.host,
        port=ch_client.connection.port,
        user=ch_client.connection.user,
        password=ch_client.connection.password,
        database=db_name,
    )

    # Apply schema
    schema_path = (
        __file__
        .replace("conftest.py", "")
    )
    import pathlib  # noqa: PLC0415
    sql_path = pathlib.Path(__file__).parent.parent / "sql" / "01_schema.sql"
    schema_sql = sql_path.read_text(encoding="utf-8")

    for stmt in [s.strip() for s in schema_sql.split(";") if s.strip()]:
        db_client.execute(stmt)

    yield db_client, db_name

    # Teardown
    ch_client.execute(f"DROP DATABASE IF EXISTS {db_name}")
