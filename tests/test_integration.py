"""
Integration tests for the full SQL pipeline.

These tests require a running ClickHouse instance.
Run with:  pytest --integration tests/

They insert synthetic data into an isolated test database, execute
the transformation SQL via the same code path as the Cloud Function,
and verify that the attribution tables contain correct results.
"""

import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

from attribution_math import (
    build_chains,
    compute_first_touch,
    compute_last_touch,
    compute_linear,
    compute_time_decay,
)
from fixtures import (
    COUNTER_ID,
    GOAL_ID,
    multi_client_visits,
    single_touch_visits,
    three_touch_visits,
    two_touch_visits,
    visits_to_ch_rows,
)


pytestmark = pytest.mark.integration


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_INSERT_VISITS = """
INSERT INTO visits_raw
(CounterID, UserIDHash, VisitID, StartDate, UTCStartTime, Duration, VisitVersion,
 `TrafficSource.Model`, `TrafficSource.ID`, `TrafficSource.StartTime`,
 `TrafficSource.SearchEngineID`, `TrafficSource.AdvEngineID`,
 `TrafficSource.SocialSourceNetworkID`, `TrafficSource.RecommendationSystemID`,
 `TrafficSource.MessengerID`, `TrafficSource.ClickBannerID`, `TrafficSource.ClickTargetType`,
 `Goals.ID`, `Goals.Serial`, `Goals.EventTime`, `Goals.Price`, `Goals.Currency`,
 `EPurchase.ID`, `EPurchase.Revenue`,
 Sign)
VALUES
"""

_SQL_DIR = pathlib.Path(__file__).parent.parent / "sql"

PARAMS = {
    "goal_id": GOAL_ID,
    "counter_id": COUNTER_ID,
    "lookback_days": 90,
    "half_life": 7.0,
}


def _run_pipeline(client, params: dict) -> None:
    """Execute the full transformation pipeline against the test database."""
    for filename in ("02_build_chains.sql", "03_attribution_models.sql"):
        raw_sql = (_SQL_DIR / filename).read_text(encoding="utf-8")
        sql = raw_sql.format(**params)
        for stmt in [s.strip() for s in sql.split(";") if s.strip()]:
            client.execute(stmt)


def _insert_visits(client, visits: list) -> None:
    rows = visits_to_ch_rows(visits)
    client.execute(_INSERT_VISITS, rows)


def _read_attribution(client, table: str, goal_id: int) -> dict:
    """Return {source_code: conversions} from an attribution table."""
    rows = client.execute(
        f"SELECT source_code, sum(conversions) FROM {table} FINAL "
        f"WHERE goal_id = {goal_id} GROUP BY source_code"
    )
    return {row[0]: row[1] for row in rows}


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestChainBuilding:
    def test_single_touch_creates_one_chain_row(self, ch_db):
        client, _ = ch_db
        _insert_visits(client, single_touch_visits())
        _run_pipeline(client, PARAMS)

        rows = client.execute(
            "SELECT count() FROM sessions_chains FINAL "
            f"WHERE goal_id = {GOAL_ID}"
        )
        assert rows[0][0] == 1

    def test_three_touch_creates_three_chain_rows(self, ch_db):
        client, _ = ch_db
        _insert_visits(client, three_touch_visits())
        _run_pipeline(client, PARAMS)

        rows = client.execute(
            "SELECT count() FROM sessions_chains FINAL "
            f"WHERE goal_id = {GOAL_ID}"
        )
        assert rows[0][0] == 3

    def test_positions_are_sequential(self, ch_db):
        client, _ = ch_db
        _insert_visits(client, three_touch_visits())
        _run_pipeline(client, PARAMS)

        rows = client.execute(
            "SELECT position FROM sessions_chains FINAL "
            f"WHERE goal_id = {GOAL_ID} ORDER BY position"
        )
        positions = [r[0] for r in rows]
        assert positions == [1, 2, 3]

    def test_pipeline_is_idempotent(self, ch_db):
        """Running the pipeline twice should not duplicate results."""
        client, _ = ch_db
        _insert_visits(client, three_touch_visits())
        _run_pipeline(client, PARAMS)
        _run_pipeline(client, PARAMS)

        rows = client.execute(
            "SELECT count() FROM sessions_chains FINAL "
            f"WHERE goal_id = {GOAL_ID}"
        )
        assert rows[0][0] == 3


class TestAttributionModels:
    def _expected(self, model_fn, visits):
        chains = build_chains(visits, GOAL_ID)
        return model_fn(chains)

    def test_first_touch_matches_python_reference(self, ch_db):
        client, _ = ch_db
        visits = multi_client_visits()
        _insert_visits(client, visits)
        _run_pipeline(client, PARAMS)

        actual = _read_attribution(client, "attribution_first_touch", GOAL_ID)
        expected = self._expected(compute_first_touch, visits)

        assert set(actual.keys()) == set(expected.keys())
        for channel in expected:
            assert actual[channel] == pytest.approx(expected[channel], abs=1e-6)

    def test_last_touch_matches_python_reference(self, ch_db):
        client, _ = ch_db
        visits = multi_client_visits()
        _insert_visits(client, visits)
        _run_pipeline(client, PARAMS)

        actual = _read_attribution(client, "attribution_last_touch", GOAL_ID)
        expected = self._expected(compute_last_touch, visits)

        assert set(actual.keys()) == set(expected.keys())
        for channel in expected:
            assert actual[channel] == pytest.approx(expected[channel], abs=1e-6)

    def test_linear_matches_python_reference(self, ch_db):
        client, _ = ch_db
        visits = multi_client_visits()
        _insert_visits(client, visits)
        _run_pipeline(client, PARAMS)

        actual = _read_attribution(client, "attribution_linear", GOAL_ID)
        expected = self._expected(compute_linear, visits)

        assert set(actual.keys()) == set(expected.keys())
        for channel in expected:
            assert actual[channel] == pytest.approx(expected[channel], abs=1e-6)

    def test_time_decay_matches_python_reference(self, ch_db):
        client, _ = ch_db
        visits = multi_client_visits()
        _insert_visits(client, visits)
        _run_pipeline(client, PARAMS)

        actual = _read_attribution(client, "attribution_time_decay", GOAL_ID)
        expected = self._expected(
            lambda c: compute_time_decay(c, half_life=PARAMS["half_life"]),
            visits,
        )

        assert set(actual.keys()) == set(expected.keys())
        for channel in expected:
            assert actual[channel] == pytest.approx(expected[channel], abs=1e-5)

    def test_all_models_total_equals_conversion_count(self, ch_db):
        client, _ = ch_db
        visits = multi_client_visits()
        _insert_visits(client, visits)
        _run_pipeline(client, PARAMS)

        n_chains = len(build_chains(visits, GOAL_ID))

        for table in (
            "attribution_first_touch",
            "attribution_last_touch",
            "attribution_linear",
            "attribution_time_decay",
        ):
            rows = client.execute(
                f"SELECT sum(conversions) FROM {table} FINAL "
                f"WHERE goal_id = {GOAL_ID}"
            )
            total = rows[0][0]
            assert total == pytest.approx(n_chains, abs=1e-6), (
                f"{table}: expected {n_chains} total conversions, got {total}"
            )
