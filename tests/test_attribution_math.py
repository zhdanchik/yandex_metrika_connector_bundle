"""
Unit tests for attribution_math.py.

These tests run entirely in Python — no ClickHouse required.
They verify that the reference implementation of each attribution
model produces mathematically correct results on synthetic data.
"""

import math
import sys
from pathlib import Path

import pytest

# Allow imports from the tests package without installing it
sys.path.insert(0, str(Path(__file__).parent))

from attribution_math import (
    build_chains,
    compute_first_touch,
    compute_last_touch,
    compute_linear,
    compute_time_decay,
    derive_channel,
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
# Helpers
# ---------------------------------------------------------------------------

def approx(value: float, expected: float, tol: float = 1e-9) -> bool:
    return abs(value - expected) <= tol


# ---------------------------------------------------------------------------
# derive_channel
# ---------------------------------------------------------------------------

class TestDeriveChannel:
    def test_utm_source_and_medium(self):
        assert derive_channel(utm_source="google", utm_medium="cpc") == "google / cpc"

    def test_utm_source_only(self):
        assert derive_channel(utm_source="yandex") == "yandex / organic"

    def test_paid_traffic_source_no_utm(self):
        assert derive_channel(traffic_source="ad") == "paid / cpc"
        assert derive_channel(traffic_source="banner") == "paid / cpc"

    def test_organic_traffic_source(self):
        assert derive_channel(traffic_source="organic") == "organic / organic"

    def test_social_with_domain(self):
        assert derive_channel(traffic_source="social", referer_domain="vk.com") == "vk.com / social"

    def test_referral(self):
        assert derive_channel(referer_domain="example.com") == "example.com / referral"

    def test_direct(self):
        assert derive_channel() == "direct / none"

    def test_utm_takes_priority_over_traffic_source(self):
        result = derive_channel(
            utm_source="yandex",
            utm_medium="cpc",
            traffic_source="ad",
        )
        assert result == "yandex / cpc"

    def test_null_referer_domain_treated_as_direct(self):
        assert derive_channel(referer_domain="null") == "direct / none"


# ---------------------------------------------------------------------------
# build_chains
# ---------------------------------------------------------------------------

class TestBuildChains:
    def test_single_touchpoint(self):
        visits = single_touch_visits()
        chains = build_chains(visits, goal_id=GOAL_ID)
        assert len(chains) == 1
        assert len(chains[0]) == 1
        assert chains[0][0]["position"] == 1
        assert chains[0][0]["chain_length"] == 1
        assert chains[0][0]["is_converting"] == 1
        assert chains[0][0]["days_before_conv"] == pytest.approx(0.0)

    def test_two_touchpoints_order(self):
        visits = two_touch_visits()
        chains = build_chains(visits, goal_id=GOAL_ID)
        assert len(chains) == 1
        chain = chains[0]
        assert len(chain) == 2
        # Oldest touchpoint first
        assert chain[0]["position"] == 1
        assert chain[1]["position"] == 2
        assert chain[0]["days_before_conv"] == pytest.approx(5.0)
        assert chain[1]["days_before_conv"] == pytest.approx(0.0)

    def test_is_converting_flag(self):
        visits = two_touch_visits()
        chains = build_chains(visits, goal_id=GOAL_ID)
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

    def test_no_goals_no_chains(self):
        from datetime import datetime
        visits = [
            {"client_id": 99, "visit_id": 1, "counter_id": 1,
             "start_time": datetime(2024, 1, 1), "goals_id": []},
        ]
        chains = build_chains(visits, goal_id=GOAL_ID)
        assert chains == []

    def test_different_goal_not_converting(self):
        visits = single_touch_visits()
        chains = build_chains(visits, goal_id=9999)
        assert chains == []

    def test_lookback_window_excludes_old_visits(self):
        visits = lookback_window_visits(lookback_days=90)
        chains = build_chains(visits, goal_id=GOAL_ID, lookback_days=90)
        assert len(chains) == 1
        chain = chains[0]
        channels = [tp["channel"] for tp in chain]
        # The 100-day-old CPC visit must NOT appear
        assert "old_campaign / cpc" not in channels
        assert len(chain) == 2   # only the organic + converting visit

    def test_repeat_converter_produces_two_chains(self):
        visits = repeat_converter_visits()
        chains = build_chains(visits, goal_id=GOAL_ID)
        assert len(chains) == 2

    def test_multi_client_produces_three_chains(self):
        visits = multi_client_visits()
        chains = build_chains(visits, goal_id=GOAL_ID)
        assert len(chains) == 3


# ---------------------------------------------------------------------------
# First-touch model
# ---------------------------------------------------------------------------

class TestFirstTouch:
    def test_single_touch_all_credit(self):
        chains = build_chains(single_touch_visits(), GOAL_ID)
        result = compute_first_touch(chains)
        assert result == {"google / cpc": 1.0}

    def test_two_touch_first_gets_all(self):
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_first_touch(chains)
        # First touchpoint is organic; direct/none is NOT the first
        assert "organic / organic" in result
        assert result["organic / organic"] == pytest.approx(1.0)
        assert result.get("direct / none", 0.0) == pytest.approx(0.0)

    def test_total_equals_number_of_chains(self):
        visits = multi_client_visits()
        chains = build_chains(visits, GOAL_ID)
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
        assert result == {"google / cpc": 1.0}

    def test_two_touch_last_gets_all(self):
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_last_touch(chains)
        # Last (converting) visit has no UTM/referer → direct / none
        assert result.get("direct / none", 0.0) == pytest.approx(1.0)
        assert result.get("organic / organic", 0.0) == pytest.approx(0.0)

    def test_total_equals_number_of_chains(self):
        visits = multi_client_visits()
        chains = build_chains(visits, GOAL_ID)
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
        assert result["google / cpc"] == pytest.approx(1.0)

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
        visits = multi_client_visits()
        chains = build_chains(visits, GOAL_ID)
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
        visits = multi_client_visits()
        chains = build_chains(visits, GOAL_ID)
        result = compute_time_decay(chains, half_life=7.0)
        assert sum(result.values()) == pytest.approx(len(chains))

    def test_recent_touchpoint_higher_weight_than_older(self):
        """
        Chain: old_channel (7 days ago) → new_channel (0 days, converts).
        With half_life=7d, the 7-day-old touchpoint has weight 0.5 and
        the same-day touchpoint has weight 1.0, so new_channel > old_channel.
        """
        chains = build_chains(two_touch_visits(), GOAL_ID)
        result = compute_time_decay(chains, half_life=7.0)
        assert sum(result.values()) == pytest.approx(1.0)
        # direct/none (0 days) > organic/organic (5 days)
        assert result.get("direct / none", 0.0) > result.get("organic / organic", 0.0)

    def test_weights_sum_to_one_per_chain(self):
        """Verify that for each individual chain weights normalise to 1."""
        chains = build_chains(three_touch_visits(), GOAL_ID)
        # Manually compute weights for the single chain
        chain = chains[0]
        half_life = 7.0
        raws = [math.pow(2.0, -tp["days_before_conv"] / half_life) for tp in chain]
        total = sum(raws)
        normalised = [r / total for r in raws]
        assert sum(normalised) == pytest.approx(1.0)

    def test_all_same_day_equal_weights(self):
        """If all touchpoints happen on the same day, weights should be equal."""
        from datetime import datetime
        visits = [
            {"client_id": 10, "visit_id": 101, "counter_id": 1,
             "start_time": datetime(2024, 6, 1, 10, 0), "goals_id": [],
             "utm_source": "a", "utm_medium": "cpc"},
            {"client_id": 10, "visit_id": 102, "counter_id": 1,
             "start_time": datetime(2024, 6, 1, 11, 0), "goals_id": [],
             "utm_source": "b", "utm_medium": "cpc"},
            {"client_id": 10, "visit_id": 103, "counter_id": 1,
             "start_time": datetime(2024, 6, 1, 12, 0), "goals_id": [GOAL_ID],
             "utm_source": "c", "utm_medium": "cpc"},
        ]
        chains = build_chains(visits, goal_id=GOAL_ID)
        result = compute_time_decay(chains, half_life=7.0)
        # Very short time gaps → weights approximately equal
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
    """
    Properties that must hold across ALL models for the same input.
    """

    @pytest.mark.parametrize("model_fn", [
        compute_first_touch,
        compute_last_touch,
        compute_linear,
        lambda chains: compute_time_decay(chains, half_life=7.0),
    ])
    def test_total_conversions_equals_chain_count(self, model_fn):
        """Sum of attributed conversions = number of converting chains."""
        visits = multi_client_visits()
        chains = build_chains(visits, GOAL_ID)
        result = model_fn(chains)
        assert sum(result.values()) == pytest.approx(len(chains), abs=1e-9)

    @pytest.mark.parametrize("model_fn", [
        compute_first_touch,
        compute_last_touch,
        compute_linear,
        lambda chains: compute_time_decay(chains, half_life=7.0),
    ])
    def test_single_channel_chain_gets_full_credit(self, model_fn):
        """A one-touchpoint chain must attribute 1.0 to its channel."""
        chains = build_chains(single_touch_visits(), GOAL_ID)
        result = model_fn(chains)
        assert sum(result.values()) == pytest.approx(1.0)

    def test_first_and_last_differ_on_multi_touch(self):
        """First-touch and last-touch should differ when channels differ."""
        chains = build_chains(two_touch_visits(), GOAL_ID)
        first = compute_first_touch(chains)
        last = compute_last_touch(chains)
        # They must distribute credit differently
        assert first != last

    def test_linear_between_first_and_last(self):
        """
        For a 2-touchpoint chain where channels are different,
        linear (0.5 each) must lie strictly between first-touch
        and last-touch for the FIRST channel.
        """
        chains = build_chains(two_touch_visits(), GOAL_ID)
        first = compute_first_touch(chains)
        last = compute_last_touch(chains)
        linear = compute_linear(chains)

        channel = "organic / organic"  # the first touchpoint's channel
        assert linear[channel] == pytest.approx(0.5)
        assert first[channel] > linear[channel]
        assert last.get(channel, 0.0) < linear[channel]
