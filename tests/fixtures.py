"""
Synthetic visit data for unit and integration tests.

Visit dicts use the field names from the Data Transfer schema
(analyse_channels_chain.py) rather than UTM strings:
  user_id, utc_start_time, goals_id, trafic_source_id, etc.

SourceCode reference (for assertions in tests):
  trafic_source_id=2, search_engine_id=621  → "2_621"  Yandex organic
  trafic_source_id=2, search_engine_id=1    → "2_1"    Google organic
  trafic_source_id=3, adv_engine_id=1       → "3_1"    Yandex Direct
  trafic_source_id=3, adv_engine_id=2       → "3_2"    Google Ads
  trafic_source_id=6                        → "6"      direct
  trafic_source_id=7                        → "7"      email
  trafic_source_id=8, social_id=1           → "8_1"    VK
  trafic_source_id=0                        → "0"      other referral
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import List

# Shared reference time so tests are deterministic
T0 = datetime(2024, 6, 1, 12, 0, 0)

COUNTER_ID = 12345
GOAL_ID = 99


def _visit(
    user_id: int,
    days_ago: float,
    trafic_source_id: int = 0,
    search_engine_id: int = 0,
    adv_engine_id: int = 0,
    social_source_network_id: int = 0,
    recommendation_system_id: int = 0,
    messenger_id: int = 0,
    click_banner_id: int = 0,
    click_target_type: int = 0,
    goals: list | None = None,
    visit_id: int | None = None,
) -> dict:
    """Return a minimal visit dict using the Data Transfer field names."""
    return {
        "user_id": user_id,
        "visit_id": visit_id or (user_id * 1000 + int(days_ago * 100)),
        "counter_id": COUNTER_ID,
        "utc_start_time": T0 - timedelta(days=days_ago),
        "trafic_source_id": trafic_source_id,
        "search_engine_id": search_engine_id,
        "adv_engine_id": adv_engine_id,
        "social_source_network_id": social_source_network_id,
        "recommendation_system_id": recommendation_system_id,
        "messenger_id": messenger_id,
        "click_banner_id": click_banner_id,
        "click_target_type": click_target_type,
        "goals_id": goals or [],
    }


# ---------------------------------------------------------------------------
# Scenario 1: Single-touchpoint chain  (trivial case)
#   User arrives via Yandex Direct and immediately converts.
#   Expected source_code: "3_1"
# ---------------------------------------------------------------------------
def single_touch_visits() -> List[dict]:
    return [
        _visit(1, days_ago=0.0, trafic_source_id=3, adv_engine_id=1,
               goals=[GOAL_ID]),
    ]


# ---------------------------------------------------------------------------
# Scenario 2: Two-touchpoint chain
#   First: Yandex organic (2_621)  →  Last: direct (6, converts)
# ---------------------------------------------------------------------------
def two_touch_visits() -> List[dict]:
    return [
        _visit(2, days_ago=5.0, trafic_source_id=2, search_engine_id=621),
        _visit(2, days_ago=0.0, trafic_source_id=6, goals=[GOAL_ID]),
    ]


# ---------------------------------------------------------------------------
# Scenario 3: Three-touchpoint chain
#   Yandex organic (2_621, 7d) → Yandex Direct (3_1, 3d) → direct (6, 0d, converts)
# ---------------------------------------------------------------------------
def three_touch_visits() -> List[dict]:
    return [
        _visit(3, days_ago=7.0, trafic_source_id=2, search_engine_id=621),
        _visit(3, days_ago=3.0, trafic_source_id=3, adv_engine_id=1),
        _visit(3, days_ago=0.0, trafic_source_id=6, goals=[GOAL_ID]),
    ]


# ---------------------------------------------------------------------------
# Scenario 4: Multiple clients, each with a different path
#   Used to test aggregated attribution totals.
#
#   client 4: Yandex organic (2_621) → converts          1 touchpoint
#   client 5: VK social (8_1) → email (7) → converts     2 touchpoints
#   client 6: Yandex Direct (3_1) → direct (6) → converts  2 touchpoints
# ---------------------------------------------------------------------------
def multi_client_visits() -> List[dict]:
    return [
        # client 4: single organic touch
        _visit(4, days_ago=0.0, trafic_source_id=2, search_engine_id=621,
               goals=[GOAL_ID]),

        # client 5: social then email
        _visit(5, days_ago=4.0, trafic_source_id=8, social_source_network_id=1),
        _visit(5, days_ago=0.0, trafic_source_id=7, goals=[GOAL_ID]),

        # client 6: cpc then direct
        _visit(6, days_ago=6.0, trafic_source_id=3, adv_engine_id=1),
        _visit(6, days_ago=0.0, trafic_source_id=6, goals=[GOAL_ID]),
    ]


# ---------------------------------------------------------------------------
# Scenario 5: Visit outside the lookback window should be excluded
#   The 100-day-old Google Ads visit must NOT appear in a 90-day window.
# ---------------------------------------------------------------------------
def lookback_window_visits(lookback_days: int = 90) -> List[dict]:
    return [
        _visit(7, days_ago=100.0, trafic_source_id=3, adv_engine_id=2),  # "3_2" Google Ads
        _visit(7, days_ago=10.0,  trafic_source_id=2, search_engine_id=621),
        _visit(7, days_ago=0.0,   trafic_source_id=6, goals=[GOAL_ID]),
    ]


# ---------------------------------------------------------------------------
# Scenario 6: Same user, multiple conversions (two separate chains)
# ---------------------------------------------------------------------------
def repeat_converter_visits() -> List[dict]:
    return [
        # First conversion path
        _visit(8, days_ago=20.0, trafic_source_id=2, search_engine_id=621),
        _visit(8, days_ago=15.0, trafic_source_id=6, goals=[GOAL_ID], visit_id=8001),
        # Second conversion path
        _visit(8, days_ago=5.0,  trafic_source_id=7),
        _visit(8, days_ago=0.0,  trafic_source_id=6, goals=[GOAL_ID], visit_id=8002),
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
        goals_id = v.get("goals_id", [])
        n_goals = len(goals_id)
        row = (
            v["counter_id"],                                 # CounterID
            v["user_id"],                                    # CounterUserIDHash
            v["visit_id"],                                   # VisitID
            v["utc_start_time"].date(),                      # StartDate
            v["utc_start_time"],                             # UTCStartTime
            0,                                               # Duration
            1,                                               # VisitVersion
            # TrafficSource nested arrays (single-element, Model=1)
            [1],                                             # TrafficSource.Model
            [v.get("trafic_source_id", 0)],                 # TrafficSource.ID
            [v["utc_start_time"]],                           # TrafficSource.StartTime
            [v.get("search_engine_id", 0)],                 # TrafficSource.SearchEngineID
            [v.get("adv_engine_id", 0)],                    # TrafficSource.AdvEngineID
            [v.get("social_source_network_id", 0)],         # TrafficSource.SocialSourceNetworkID
            [v.get("recommendation_system_id", 0)],         # TrafficSource.RecommendationSystemID
            [v.get("messenger_id", 0)],                     # TrafficSource.MessengerID
            [v.get("click_banner_id", 0)],                  # TrafficSource.ClickBannerID
            [v.get("click_target_type", 0)],                # TrafficSource.ClickTargetType
            # Goals nested arrays
            goals_id,                                        # Goals.ID
            [0] * n_goals,                                   # Goals.Serial
            [v["utc_start_time"]] * n_goals,                 # Goals.EventTime
            [0.0] * n_goals,                                 # Goals.Price
            [0] * n_goals,                                   # Goals.Currency
            # EPurchase
            [],                                              # EPurchase.ID
            [],                                              # EPurchase.Revenue
            1,                                               # Sign
        )
        rows.append(row)
    return rows
