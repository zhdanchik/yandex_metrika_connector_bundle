"""
Pure-Python reference implementation of the attribution models.

This module mirrors the SQL logic in sql/02_build_chains.sql and
sql/03_attribution_models.sql.  It is used exclusively by the unit
test suite so that correctness can be verified without a live
ClickHouse instance.

Each public function accepts a list of *chains*, where a chain is
a list of touchpoint dicts produced by ``build_chains()``:

    {
        "channel":          str,    # normalised channel label
        "position":         int,    # 1 = oldest, chain_length = converting
        "chain_length":     int,
        "days_before_conv": float,  # days between this visit and conversion
        "is_converting":    int,    # 1 if this is the converting touchpoint
    }
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta
from typing import Dict, List


# ---------------------------------------------------------------------------
# Channel derivation  (mirrors the multiIf() in 02_build_chains.sql)
# ---------------------------------------------------------------------------

def derive_channel(
    utm_source: str = "",
    utm_medium: str = "",
    traffic_source: str = "",
    referer_domain: str = "",
) -> str:
    """Return a normalised '{source} / {medium}' channel label."""
    if utm_source and utm_medium:
        return f"{utm_source} / {utm_medium}"
    if utm_source:
        return f"{utm_source} / organic"
    if traffic_source in ("ad", "banner", "context", "paid"):
        return "paid / cpc"
    if traffic_source == "organic":
        return "organic / organic"
    if traffic_source == "social" and referer_domain:
        return f"{referer_domain} / social"
    if referer_domain and referer_domain != "null":
        return f"{referer_domain} / referral"
    return "direct / none"


# ---------------------------------------------------------------------------
# Chain building  (mirrors the CTEs in 02_build_chains.sql)
# ---------------------------------------------------------------------------

def build_chains(
    visits: List[dict],
    goal_id: int,
    lookback_days: int = 90,
) -> List[List[dict]]:
    """
    Build conversion chains from a list of visit records.

    Each visit dict must contain:
        client_id   : int
        start_time  : datetime
        goals_id    : list[int]  – goal IDs reached in this visit
        utm_source  : str  (optional, defaults to '')
        utm_medium  : str  (optional)
        traffic_source: str (optional)
        referer_domain: str (optional)

    Returns a list of chains; each chain is a sorted list of
    touchpoint dicts (oldest first).
    """
    # Find all converting visits
    converting = [
        v for v in visits
        if goal_id in v.get("goals_id", [])
    ]

    chains: List[List[dict]] = []

    for conv in converting:
        conv_time: datetime = conv["start_time"]
        client_id: int = conv["client_id"]
        window_start = conv_time - timedelta(days=lookback_days)

        # Collect touchpoints within the lookback window
        touchpoints = [
            v for v in visits
            if v["client_id"] == client_id
            and window_start <= v["start_time"] <= conv_time
        ]

        if not touchpoints:
            continue

        # Sort chronologically (oldest first)
        touchpoints.sort(key=lambda v: v["start_time"])
        chain_length = len(touchpoints)

        chain: List[dict] = []
        for pos, tp in enumerate(touchpoints, start=1):
            delta_seconds = (conv_time - tp["start_time"]).total_seconds()
            days_before = delta_seconds / 86400.0
            channel = derive_channel(
                utm_source=tp.get("utm_source", ""),
                utm_medium=tp.get("utm_medium", ""),
                traffic_source=tp.get("traffic_source", ""),
                referer_domain=tp.get("referer_domain", ""),
            )
            chain.append({
                "channel": channel,
                "position": pos,
                "chain_length": chain_length,
                "days_before_conv": days_before,
                "is_converting": 1 if tp is conv else 0,
            })

        chains.append(chain)

    return chains


# ---------------------------------------------------------------------------
# Attribution models
# ---------------------------------------------------------------------------

def _accumulate(result: Dict[str, float], channel: str, weight: float) -> None:
    result[channel] = result.get(channel, 0.0) + weight


def compute_first_touch(chains: List[List[dict]]) -> Dict[str, float]:
    """
    First-touch: 100% credit to position=1 (oldest) touchpoint.
    """
    result: Dict[str, float] = {}
    for chain in chains:
        if not chain:
            continue
        first = min(chain, key=lambda tp: tp["position"])
        _accumulate(result, first["channel"], 1.0)
    return result


def compute_last_touch(chains: List[List[dict]]) -> Dict[str, float]:
    """
    Last-touch: 100% credit to the converting (is_converting=1) touchpoint.
    Falls back to position=max if no touchpoint is flagged.
    """
    result: Dict[str, float] = {}
    for chain in chains:
        if not chain:
            continue
        converting = [tp for tp in chain if tp.get("is_converting") == 1]
        if converting:
            tp = converting[0]
        else:
            tp = max(chain, key=lambda t: t["position"])
        _accumulate(result, tp["channel"], 1.0)
    return result


def compute_linear(chains: List[List[dict]]) -> Dict[str, float]:
    """
    Linear: equal credit (1/N) to every touchpoint in the chain.
    """
    result: Dict[str, float] = {}
    for chain in chains:
        n = len(chain)
        if n == 0:
            continue
        weight = 1.0 / n
        for tp in chain:
            _accumulate(result, tp["channel"], weight)
    return result


def compute_time_decay(
    chains: List[List[dict]],
    half_life: float = 7.0,
) -> Dict[str, float]:
    """
    Time decay: weight ∝ 2^(-days_before_conv / half_life).

    Weights are normalised within each chain so that each chain
    contributes exactly 1.0 conversion in aggregate.

    ``half_life`` is the number of days at which a touchpoint
    receives half the weight of one on the day of conversion.
    """
    if half_life <= 0:
        raise ValueError(f"half_life must be positive, got {half_life}")

    result: Dict[str, float] = {}
    for chain in chains:
        if not chain:
            continue
        raw_weights = [
            math.pow(2.0, -tp["days_before_conv"] / half_life)
            for tp in chain
        ]
        total = sum(raw_weights)
        if total == 0:
            continue
        for tp, w in zip(chain, raw_weights):
            _accumulate(result, tp["channel"], w / total)
    return result
