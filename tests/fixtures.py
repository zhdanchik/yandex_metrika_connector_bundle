"""
Synthetic visit data for unit and integration tests.

All helpers return plain Python dicts (for unit tests) or
ClickHouse INSERT rows (for integration tests).
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import List


# Shared reference time so tests are deterministic
T0 = datetime(2024, 6, 1, 12, 0, 0)

COUNTER_ID = 12345
GOAL_ID = 99


def _visit(
    client_id: int,
    days_ago: float,
    utm_source: str = "",
    utm_medium: str = "",
    traffic_source: str = "",
    referer_domain: str = "",
    goals: list[int] | None = None,
    visit_id: int | None = None,
) -> dict:
    """Return a minimal visit dict for unit-test chain building."""
    return {
        "client_id": client_id,
        "visit_id": visit_id or (client_id * 1000 + int(days_ago * 100)),
        "counter_id": COUNTER_ID,
        "start_time": T0 - timedelta(days=days_ago),
        "utm_source": utm_source,
        "utm_medium": utm_medium,
        "traffic_source": traffic_source,
        "referer_domain": referer_domain,
        "goals_id": goals or [],
    }


# ---------------------------------------------------------------------------
# Scenario 1: Single-touchpoint chain  (trivial case)
#   User arrives via CPC and immediately converts.
# ---------------------------------------------------------------------------
def single_touch_visits() -> List[dict]:
    return [
        _visit(1, days_ago=0.0, utm_source="google", utm_medium="cpc",
               goals=[GOAL_ID]),
    ]


# ---------------------------------------------------------------------------
# Scenario 2: Two-touchpoint chain
#   First: organic search  →  Last: direct  →  converts on last
# ---------------------------------------------------------------------------
def two_touch_visits() -> List[dict]:
    return [
        _visit(2, days_ago=5.0, traffic_source="organic"),
        _visit(2, days_ago=0.0, goals=[GOAL_ID]),           # direct / none
    ]


# ---------------------------------------------------------------------------
# Scenario 3: Three-touchpoint chain
#   organic (7d) → cpc (3d) → direct (0d, converts)
# ---------------------------------------------------------------------------
def three_touch_visits() -> List[dict]:
    return [
        _visit(3, days_ago=7.0, traffic_source="organic"),
        _visit(3, days_ago=3.0, utm_source="yandex", utm_medium="cpc"),
        _visit(3, days_ago=0.0, goals=[GOAL_ID]),
    ]


# ---------------------------------------------------------------------------
# Scenario 4: Multiple clients, each with a different path
#   Used to test aggregated attribution totals.
#
#   client 4: organic → converts          (1 touchpoint)
#   client 5: social → email → converts  (2 touchpoints)
#   client 6: cpc → direct → converts    (2 touchpoints)
# ---------------------------------------------------------------------------
def multi_client_visits() -> List[dict]:
    return [
        # client 4
        _visit(4, days_ago=0.0, traffic_source="organic", goals=[GOAL_ID]),

        # client 5
        _visit(5, days_ago=4.0, traffic_source="social",
               referer_domain="vk.com"),
        _visit(5, days_ago=0.0, utm_source="email", utm_medium="newsletter",
               goals=[GOAL_ID]),

        # client 6
        _visit(6, days_ago=6.0, utm_source="yandex", utm_medium="cpc"),
        _visit(6, days_ago=0.0, goals=[GOAL_ID]),
    ]


# ---------------------------------------------------------------------------
# Scenario 5: Visit outside the lookback window should be excluded
#   Touchpoint at 100 days ago should NOT appear in a 90-day window.
# ---------------------------------------------------------------------------
def lookback_window_visits(lookback_days: int = 90) -> List[dict]:
    return [
        _visit(7, days_ago=100.0, utm_source="old_campaign", utm_medium="cpc"),
        _visit(7, days_ago=10.0, traffic_source="organic"),
        _visit(7, days_ago=0.0, goals=[GOAL_ID]),
    ]


# ---------------------------------------------------------------------------
# Scenario 6: Same client, multiple conversions (two separate chains)
# ---------------------------------------------------------------------------
def repeat_converter_visits() -> List[dict]:
    return [
        # First conversion event
        _visit(8, days_ago=20.0, traffic_source="organic"),
        _visit(8, days_ago=15.0, goals=[GOAL_ID], visit_id=8001),

        # Second conversion event (later)
        _visit(8, days_ago=5.0, utm_source="email", utm_medium="newsletter"),
        _visit(8, days_ago=0.0, goals=[GOAL_ID], visit_id=8002),
    ]


# ---------------------------------------------------------------------------
# ClickHouse INSERT rows
# For integration tests: returns list of tuples matching visits_raw columns.
# ---------------------------------------------------------------------------
def visits_to_ch_rows(visits: List[dict]) -> List[tuple]:
    """
    Convert unit-test visit dicts to tuples for ClickHouse insertion.
    Column order matches the INSERT statement in test_integration.py.
    """
    rows = []
    for v in visits:
        goals = v.get("goals_id", [])
        row = (
            v["counter_id"],                          # CounterID
            v["visit_id"],                             # VisitID
            v["client_id"],                            # ClientID
            v["start_time"],                           # StartTime
            0,                                         # Duration
            0,                                         # Bounce
            1,                                         # PageViews
            v.get("utm_source", ""),                   # UTMSource
            v.get("utm_medium", ""),                   # UTMMedium
            "",                                        # UTMCampaign
            "",                                        # UTMContent
            "",                                        # UTMTerm
            v.get("traffic_source", ""),               # TrafficSource
            0,                                         # SearchEngineID
            "",                                        # SearchPhrase
            0,                                         # AdvEngineID
            "",                                        # Referer
            v.get("referer_domain", ""),               # RefererDomain
            "",                                        # StartURL
            goals,                                     # GoalsID
            [0] * len(goals),                          # GoalsSerial
            [v["start_time"]] * len(goals),            # GoalsEventTime
            [0] * len(goals),                          # GoalsCurrencyID
            [0.0] * len(goals),                        # GoalsPrice
            "",                                        # FromParam
            1,                                         # Sign
        )
        rows.append(row)
    return rows
