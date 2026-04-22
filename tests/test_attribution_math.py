"""
Unit tests for attribution_math.py.

These tests run entirely in Python — no ClickHouse required.
They verify that the reference implementation produces mathematically
correct results on synthetic data drawn from fixtures.py.

SourceCode values used in assertions (see fixtures.py for full mapping):
  "3_1"   Yandex Direct (trafic_source_id=3, adv_engine_id=1)
  "2_621" Yandex organic (trafic_source_id=2, search_engine_root_id=621)
  "6"     direct / typed URL (trafic_source_id=6)
  "7"     email (trafic_source_id=7)
  "8_1"   VK social (trafic_source_id=8, social_source_network_id=1)
"""

import math
import sys
from datetime import datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from attribution_math import (
    build_chains,
    compute_assisted_conversions,
    compute_first_touch,
    compute_last_significant,
    compute_last_touch,
    compute_linear,
    compute_time_decay,
    compute_transitions,
    derive_source_code,
)
from fixtures import (
    GOAL_ID,
    T0,
    lookback_window_visits,
    multi_client_visits,
    repeat_converter_visits,
    single_touch_visits,
    three_touch_visits,
    two_touch_visits,
)


# ---------------------------------------------------------------------------
# derive_source_code
# ---------------------------------------------------------------------------

class TestDeriveSourceCode:
    def test_organic_search_appends_engine_id(self):
        assert derive_source_code(2, search_engine_root_id=621) == "2_621"
        assert derive_source_code(2, search_engine_root_id=1) == "2_1"

    def test_advertising_appends_adv_engine_id(self):
        assert derive_source_code(3, adv_engine_id=1) == "3_1"   # Yandex Direct
        assert derive_source_code(3, adv_engine_id=2) == "3_2"   # Google Ads

    def test_advertising_with_banner_appends_click_target_type(self):
        result = derive_source_code(
            3, adv_engine_id=1, click_banner_id=12345, click_target_type=11
        )
        assert result == "3_1_11"

    def test_advertising_with_banner_requires_nonzero_banner_id(self):
        # click_banner_id=0 → no banner suffix
        assert derive_source_code(3, adv_engine_id=1, click_banner_id=0) == "3_1"

    def test_social_appends_network_id(self):
        assert derive_source_code(8, social_source_network_id=1) == "8_1"   # VK
        assert derive_source_code(8, social_source_network_id=2) == "8_2"   # Facebook

    def test_recommendation_appends_system_id(self):
        assert derive_source_code(9, recommendation_system_id=3) == "9_3"

    def test_messenger_appends_messenger_id(self):
        assert derive_source_code(10, messenger_id=2) == "10_2"

    def test_direct_no_suffix(self):
        assert derive_source_code(6) == "6"

    def test_email_no_suffix(self):
        assert derive_source_code(7) == "7"

    def test_internal_no_suffix(self):
        assert derive_source_code(4) == "4"

    def test_unknown_no_suffix(self):
        assert derive_source_code(0) == "0"
        assert derive_source_code(-1) == "-1"


# ---------------------------------------------------------------------------
# build_chains
# ---------------------------------------------------------------------------

class TestBuildChains:
    def test_single_touchpoint(self):
        visits = single_touch_visits()
        chains = build_chains(visits, goal_id=GOAL_ID)
        assert len(chains) == 1
        assert len(chains[0]) == 1
        tp = chains[0][0]
        assert tp["position"] == 1
        assert tp["chain_length"] == 1
        assert tp["is_converting"] == 1
        assert tp["days_before_conv"] == pytest.approx(0.0)
        assert tp["source_code"] == "3_1"

    def test_two_touchpoints_order(self):
        visits = two_touch_visits()
        chains = build_chains(visits, goal_id=GOAL_ID)
        assert len(chains) == 1
        chain = chains[0]
        assert len(chain) == 2
        assert chain[0]["position"] == 1
        assert chain[1]["position"] == 2
        assert chain[0]["days_before_conv"] == pytest.approx(5.0)
        assert chain[1]["days_before_conv"] == pytest.approx(0.0)

    def test_two_touchpoints_source_codes(self):
        chains = build_chains(two_touch_visits(), GOAL_ID)
        chain = chains[0]
        assert chain[0]["source_code"] == "2_621"   # Yandex organic
        assert chain[1]["source_code"] == "6"        # direct

    def test_is_converting_flag(self):
        chains = build_chains(two_touch_visits(), GOAL_ID)
        chain = chains[0]
        assert chain[0]["is_converting"] == 0
        assert chain[1]["is_converting"] == 1

    def test_three_touchpoints_chain_length(self):
        visits = three_touch_visits()
        chains = build_chains(visits, goal_id=GOAL_ID)
        assert len(chains) == 1
        chain = chains[0]
        assert len(chain) == 3
        assert all(tp["chain_length"] == 3 for tp in chain)

    def test_three_touchpoints_source_codes(self):
        chains = build_chains(three_touch_visits(), GOAL_ID)
        chain = chains[0]
        assert chain[0]["source_code"] == "2_621"   # Yandex organic
        assert chain[1]["source_code"] == "3_1"      # Yandex Direct
        assert chain[2]["source_code"] == "6"         # direct

    def test_no_goals_no_chains(self):
        visits = [
            {"user_id": 99, "visit_id": 1, "counter_id": 1,
             "utc_start_time": datetime(2024, 1, 1), "goals_id": [],
             "trafic_source_id": 6},
        ]
        chains = build_chains(visits, goal_id=GOAL_ID)
        assert chains == []

    def test_different_goal_id_no_chains(self):
        visits = single_touch_visits()
        chains = build_chains(visits, goal_id=9999)
        assert chains == []

    def test_lookback_window_excludes_old_visit(self):
        visits = lookback_window_visits(lookback_days=90)
        chains = build_chains(visits, goal_id=GOAL_ID, lookback_days=90)
        assert len(chains) == 1
        chain = chains[0]
        source_codes = [tp["source_code"] for tp in chain]
        assert "3_2" not in source_codes   # 100-day-old Google Ads visit excluded
        assert len(chain) == 2             # only Yandex organic + direct

    def test_repeat_converter_produces_two_chains(self):
        chains = build_chains(repeat_converter_visits(), goal_id=GOAL_ID)
        assert len(chains) == 2

    def test_multi_client_produces_three_chains(self):
        chains = build_chains(multi_client_visits(), goal_id=GOAL_ID)
        assert len(chains) == 3


# ---------------------------------------------------------------------------
# First-touch model
# ---------------------------------------------------------------------------

class TestFirstTouch:
    def test_single_touch_all_credit(self):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        result = compute_first_touch(chains)
        assert result == {"3_1": 1.0}

    def test_two_touch_first_gets_all(self):
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_first_touch(chains)
        assert result.get("2_621", 0.0) == pytest.approx(1.0)   # Yandex organic is first
        assert result.get("6", 0.0) == pytest.approx(0.0)

    def test_total_equals_number_of_chains(self):
        chains = build_chains(multi_client_visits(), GOAL_ID)
        result = compute_first_touch(chains)
        assert sum(result.values()) == pytest.approx(len(chains))

    def test_empty_chains(self):
        assert compute_first_touch([]) == {}


# ---------------------------------------------------------------------------
# Last-touch model
# ---------------------------------------------------------------------------

class TestLastTouch:
    def test_single_touch_all_credit(self):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        result = compute_last_touch(chains)
        assert result == {"3_1": 1.0}

    def test_two_touch_last_gets_all(self):
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_last_touch(chains)
        assert result.get("6", 0.0) == pytest.approx(1.0)        # direct is last
        assert result.get("2_621", 0.0) == pytest.approx(0.0)

    def test_total_equals_number_of_chains(self):
        chains = build_chains(multi_client_visits(), GOAL_ID)
        result = compute_last_touch(chains)
        assert sum(result.values()) == pytest.approx(len(chains))

    def test_empty_chains(self):
        assert compute_last_touch([]) == {}


# ---------------------------------------------------------------------------
# Linear model
# ---------------------------------------------------------------------------

class TestLinear:
    def test_single_touch_full_credit(self):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        result = compute_linear(chains)
        assert sum(result.values()) == pytest.approx(1.0)
        assert result["3_1"] == pytest.approx(1.0)

    def test_two_touch_equal_split(self):
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_linear(chains)
        assert sum(result.values()) == pytest.approx(1.0)
        for credit in result.values():
            assert credit == pytest.approx(0.5)

    def test_three_touch_equal_thirds(self):
        chains = build_chains(three_touch_visits(), GOAL_ID)
        result = compute_linear(chains)
        assert sum(result.values()) == pytest.approx(1.0)
        for credit in result.values():
            assert credit == pytest.approx(1 / 3)

    def test_total_equals_number_of_chains(self):
        chains = build_chains(multi_client_visits(), GOAL_ID)
        result = compute_linear(chains)
        assert sum(result.values()) == pytest.approx(len(chains))

    def test_empty_chains(self):
        assert compute_linear([]) == {}


# ---------------------------------------------------------------------------
# Time-decay model
# ---------------------------------------------------------------------------

class TestTimeDecay:
    def test_single_touch_full_credit(self):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        result = compute_time_decay(chains, half_life=7.0)
        assert sum(result.values()) == pytest.approx(1.0)

    def test_total_equals_number_of_chains(self):
        chains = build_chains(multi_client_visits(), GOAL_ID)
        result = compute_time_decay(chains, half_life=7.0)
        assert sum(result.values()) == pytest.approx(len(chains))

    def test_recent_touchpoint_higher_weight(self):
        """direct (0 days before conv) must outweigh Yandex organic (5 days)."""
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_time_decay(chains, half_life=7.0)
        assert result.get("6", 0.0) > result.get("2_621", 0.0)

    def test_weights_sum_to_one_per_chain(self):
        chains = build_chains(three_touch_visits(), GOAL_ID)
        chain = chains[0]
        half_life = 7.0
        raws = [math.pow(2.0, -tp["days_before_conv"] / half_life) for tp in chain]
        total = sum(raws)
        assert sum(r / total for r in raws) == pytest.approx(1.0)

    def test_all_same_time_approximately_equal_weights(self):
        """Visits seconds apart → weights almost equal."""
        visits = [
            {"user_id": 10, "visit_id": 101, "counter_id": 1,
             "utc_start_time": datetime(2024, 6, 1, 10, 0), "goals_id": [],
             "trafic_source_id": 3, "adv_engine_id": 1},
            {"user_id": 10, "visit_id": 102, "counter_id": 1,
             "utc_start_time": datetime(2024, 6, 1, 11, 0), "goals_id": [],
             "trafic_source_id": 2, "search_engine_root_id": 621},
            {"user_id": 10, "visit_id": 103, "counter_id": 1,
             "utc_start_time": datetime(2024, 6, 1, 12, 0), "goals_id": [GOAL_ID],
             "trafic_source_id": 6},
        ]
        chains = build_chains(visits, goal_id=GOAL_ID)
        result = compute_time_decay(chains, half_life=7.0)
        credits = list(result.values())
        assert max(credits) - min(credits) < 0.01

    def test_invalid_half_life_raises(self):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        with pytest.raises(ValueError):
            compute_time_decay(chains, half_life=0.0)
        with pytest.raises(ValueError):
            compute_time_decay(chains, half_life=-1.0)

    def test_empty_chains(self):
        assert compute_time_decay([]) == {}


# ---------------------------------------------------------------------------
# Cross-model invariants
# ---------------------------------------------------------------------------

class TestCrossModelInvariants:

    @pytest.mark.parametrize("model_fn", [
        compute_first_touch,
        compute_last_touch,
        compute_last_significant,
        compute_linear,
        lambda chains: compute_time_decay(chains, half_life=7.0),
    ])
    def test_total_conversions_equals_chain_count(self, model_fn):
        chains = build_chains(multi_client_visits(), GOAL_ID)
        result = model_fn(chains)
        assert sum(result.values()) == pytest.approx(len(chains), abs=1e-9)

    @pytest.mark.parametrize("model_fn", [
        compute_first_touch,
        compute_last_touch,
        compute_last_significant,
        compute_linear,
        lambda chains: compute_time_decay(chains, half_life=7.0),
    ])
    def test_single_channel_chain_full_credit(self, model_fn):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        result = model_fn(chains)
        assert sum(result.values()) == pytest.approx(1.0)

    def test_first_and_last_differ_on_multi_touch(self):
        chains = build_chains(two_touch_visits(), GOAL_ID)
        first = compute_first_touch(chains)
        last = compute_last_touch(chains)
        assert first != last

    def test_linear_between_first_and_last_for_first_channel(self):
        """
        Chain: 2_621 (5d) → 6 (0d, converts).
        For channel "2_621":
          first-touch → 1.0, linear → 0.5, last-touch → 0.0
        """
        chains = build_chains(two_touch_visits(), GOAL_ID)
        first = compute_first_touch(chains)
        last = compute_last_touch(chains)
        linear = compute_linear(chains)

        assert linear["2_621"] == pytest.approx(0.5)
        assert first["2_621"] > linear["2_621"]
        assert last.get("2_621", 0.0) < linear["2_621"]


# ---------------------------------------------------------------------------
# Last-significant model
# ---------------------------------------------------------------------------

class TestLastSignificant:
    """
    Non-significant roots are TraficSourceID ∈ (-1, 0, 4, 5, 6).
    Last-significant credits the most-recent *significant* touchpoint,
    falling back to last-touch if none exist.
    """

    def test_two_touch_skips_non_significant_last(self):
        # Chain: 2_621 (significant) → 6 (non-significant, converts)
        # last_significant should credit 2_621.
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_last_significant(chains)
        assert result == {"2_621": 1.0}

    def test_three_touch_picks_latest_significant(self):
        # Chain: 2_621 → 3_1 → 6.  Last non-significant is 6; the
        # latest significant is 3_1.
        chains = build_chains(three_touch_visits(), GOAL_ID)
        result = compute_last_significant(chains)
        assert result == {"3_1": 1.0}

    def test_falls_back_to_last_touch_when_all_non_significant(self):
        visits = [
            {"user_id": 20, "visit_id": 201, "counter_id": 1,
             "utc_start_time": datetime(2024, 6, 1, 10, 0), "goals_id": [],
             "trafic_source_id": 0},                                    # direct
            {"user_id": 20, "visit_id": 202, "counter_id": 1,
             "utc_start_time": datetime(2024, 6, 1, 11, 0), "goals_id": [GOAL_ID],
             "trafic_source_id": 6},                                    # external
        ]
        chains = build_chains(visits, goal_id=GOAL_ID)
        result = compute_last_significant(chains)
        assert result == {"6": 1.0}

    def test_single_significant_touch_full_credit(self):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        result = compute_last_significant(chains)
        assert result == {"3_1": 1.0}

    def test_empty_chains(self):
        assert compute_last_significant([]) == {}

    def test_differs_from_last_touch_when_last_is_direct(self):
        """
        When the last touch is in (0, -1, 4, 5, 6), last_significant ≠ last_touch.
        """
        chains = build_chains(two_touch_visits(), GOAL_ID)
        assert compute_last_touch(chains) != compute_last_significant(chains)


# ---------------------------------------------------------------------------
# Assisted conversions
# ---------------------------------------------------------------------------

class TestAssistedConversions:
    def test_single_touch_no_assists(self):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        assert compute_assisted_conversions(chains) == {}

    def test_two_touch_first_assists(self):
        # "2_621" (first) assists for the conversion credited to "6" (last).
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_assisted_conversions(chains)
        assert result == {"2_621": 1.0}

    def test_three_touch_first_two_assist(self):
        # Chain 2_621 → 3_1 → 6 (converts).  Both 2_621 and 3_1 assist.
        chains = build_chains(three_touch_visits(), GOAL_ID)
        result = compute_assisted_conversions(chains)
        assert result == {"2_621": 1.0, "3_1": 1.0}

    def test_duplicate_non_last_source_counts_once_per_chain(self):
        # 2_621 → 2_621 → 6.  Duplicate non-last appearances count as one assist.
        visits = [
            {"user_id": 30, "visit_id": 301, "counter_id": 1,
             "utc_start_time": datetime(2024, 6, 1, 8, 0), "goals_id": [],
             "trafic_source_id": 2, "search_engine_root_id": 621},
            {"user_id": 30, "visit_id": 302, "counter_id": 1,
             "utc_start_time": datetime(2024, 6, 1, 9, 0), "goals_id": [],
             "trafic_source_id": 2, "search_engine_root_id": 621},
            {"user_id": 30, "visit_id": 303, "counter_id": 1,
             "utc_start_time": datetime(2024, 6, 1, 10, 0), "goals_id": [GOAL_ID],
             "trafic_source_id": 6},
        ]
        chains = build_chains(visits, goal_id=GOAL_ID)
        result = compute_assisted_conversions(chains)
        assert result == {"2_621": 1.0}

    def test_last_touch_source_gets_no_self_assist(self):
        # The last-touch source itself never receives assist credit for its own chain.
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_assisted_conversions(chains)
        assert "6" not in result  # last-touch source
        assert result.get("2_621", 0.0) == 1.0

    def test_empty_chains(self):
        assert compute_assisted_conversions([]) == {}


# ---------------------------------------------------------------------------
# Transition matrix
# ---------------------------------------------------------------------------

class TestTransitions:
    def test_single_touch_no_transitions(self):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        assert compute_transitions(chains) == {}

    def test_two_touch_one_transition(self):
        chains = build_chains(two_touch_visits(), GOAL_ID)
        assert compute_transitions(chains) == {("2_621", "6"): 1.0}

    def test_three_touch_two_transitions(self):
        chains = build_chains(three_touch_visits(), GOAL_ID)
        assert compute_transitions(chains) == {
            ("2_621", "3_1"): 1.0,
            ("3_1", "6"): 1.0,
        }

    def test_multi_client_aggregates(self):
        chains = build_chains(multi_client_visits(), GOAL_ID)
        result = compute_transitions(chains)
        # client 5: 8_1 → 7 ; client 6: 3_1 → 6 ; client 4: single-touch, nothing.
        assert result == {
            ("8_1", "7"): 1.0,
            ("3_1", "6"): 1.0,
        }

    def test_empty_chains(self):
        assert compute_transitions([]) == {}
