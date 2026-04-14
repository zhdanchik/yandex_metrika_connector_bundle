"""
Pure-Python reference implementation of the attribution models.

This module mirrors the SQL logic in sql/02_build_chains.sql and
sql/03_attribution_models.sql.  It is used exclusively by the unit
test suite so that correctness can be verified without a live
ClickHouse instance.

SourceCode convention matches analyse_channels_chain.py.
Официальные типы источников Яндекс Метрики (TraficSourceID):
  -1  INTERNAL  Внутренние переходы           → "-1"
   0  DIRECT    Прямые заходы                 → "0"
   1  LINK      Переходы по ссылкам на сайтах → "1"
   2  SEARCH    Из поисковых систем           → "2_{SearchEngineID}"
                  e.g. "2_621"=Яндекс, "2_1"=Google, "2_3"=Mail.ru
   3  ADV       Переходы по рекламе           → "3_{AdvEngineID}"
                  + баннер                    → "3_{AdvEngineID}_{ClickTargetType}"
                  e.g. "3_1"=Яндекс Директ, "3_2"=Google Ads
   4  LOCAL     С сохранённых страниц         → "4"
   5  UNKNOW    Не определён                  → "5"
   6  EXTERNAL  По внешним ссылкам            → "6"
   7  MAIL      С почтовых рассылок           → "7"
   8  SOCIAL    Из социальных сетей           → "8_{SocialSourceNetworkID}"
                  e.g. "8_1"=VK, "8_2"=Facebook, "8_3"=OK
   9  RECOMMEND Из рекомендательных систем    → "9_{RecommendationSystemID}"
  10  MESSENGER Из мессенджеров               → "10_{MessengerID}"
  11  QR        По QR коду                    → "11"

Each public function accepts a list of *chains*, where a chain is
a list of touchpoint dicts produced by ``build_chains()``:

    {
        "source_code":      str,    # SourceCode label (e.g. "2_621")
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
# SourceCode derivation  (mirrors the multiIf in 02_build_chains.sql)
# ---------------------------------------------------------------------------

def derive_source_code(
    trafic_source_id: int,
    search_engine_id: int = 0,
    adv_engine_id: int = 0,
    social_source_network_id: int = 0,
    recommendation_system_id: int = 0,
    messenger_id: int = 0,
    click_banner_id: int = 0,
    click_target_type: int = 0,
) -> str:
    """
    Derive a SourceCode string from Yandex Metrika TraficSourceID fields.

    Mirrors the multiIf() expression in 02_build_chains.sql which was
    originally written in analyse_channels_chain.py.
    """
    code = str(trafic_source_id)
    if trafic_source_id == 2:
        return f"{code}_{search_engine_id}"
    if trafic_source_id == 3 and adv_engine_id == 1 and click_banner_id != 0:
        return f"{code}_{adv_engine_id}_{click_target_type}"
    if trafic_source_id == 3:
        return f"{code}_{adv_engine_id}"
    if trafic_source_id == 8:
        return f"{code}_{social_source_network_id}"
    if trafic_source_id == 9:
        return f"{code}_{recommendation_system_id}"
    if trafic_source_id == 10:
        return f"{code}_{messenger_id}"
    return code


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
        user_id           : int
        utc_start_time    : datetime
        goals_id          : list[int]   – goal IDs reached in this visit
        trafic_source_id  : int         (default 0)
        search_engine_id  : int         (default 0)
        adv_engine_id     : int         (default 0)
        social_source_network_id : int  (default 0)
        recommendation_system_id : int  (default 0)
        messenger_id      : int         (default 0)
        click_banner_id   : int         (default 0)
        click_target_type : int         (default 0)

    Returns a list of chains; each chain is a sorted list of
    touchpoint dicts (oldest first, i.e. position 1 first).
    """
    # Find all converting visits
    converting = [
        v for v in visits
        if goal_id in v.get("goals_id", [])
    ]

    chains: List[List[dict]] = []

    for conv in converting:
        conv_time: datetime = conv["utc_start_time"]
        user_id: int = conv["user_id"]
        window_start = conv_time - timedelta(days=lookback_days)

        # Collect touchpoints within the lookback window
        touchpoints = [
            v for v in visits
            if v["user_id"] == user_id
            and window_start <= v["utc_start_time"] <= conv_time
        ]

        if not touchpoints:
            continue

        # Sort chronologically (oldest first = position 1)
        touchpoints.sort(key=lambda v: v["utc_start_time"])
        chain_length = len(touchpoints)

        chain: List[dict] = []
        for pos, tp in enumerate(touchpoints, start=1):
            delta_seconds = (conv_time - tp["utc_start_time"]).total_seconds()
            days_before = delta_seconds / 86400.0
            source_code = derive_source_code(
                trafic_source_id=tp.get("trafic_source_id", 0),
                search_engine_id=tp.get("search_engine_id", 0),
                adv_engine_id=tp.get("adv_engine_id", 0),
                social_source_network_id=tp.get("social_source_network_id", 0),
                recommendation_system_id=tp.get("recommendation_system_id", 0),
                messenger_id=tp.get("messenger_id", 0),
                click_banner_id=tp.get("click_banner_id", 0),
                click_target_type=tp.get("click_target_type", 0),
            )
            chain.append({
                "source_code": source_code,
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

def _accumulate(result: Dict[str, float], source_code: str, weight: float) -> None:
    result[source_code] = result.get(source_code, 0.0) + weight


def compute_first_touch(chains: List[List[dict]]) -> Dict[str, float]:
    """First-touch: 100% credit to position=1 (oldest) touchpoint."""
    result: Dict[str, float] = {}
    for chain in chains:
        if not chain:
            continue
        first = min(chain, key=lambda tp: tp["position"])
        _accumulate(result, first["source_code"], 1.0)
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
        tp = converting[0] if converting else max(chain, key=lambda t: t["position"])
        _accumulate(result, tp["source_code"], 1.0)
    return result


def compute_linear(chains: List[List[dict]]) -> Dict[str, float]:
    """Linear: equal credit (1/N) to every touchpoint in the chain."""
    result: Dict[str, float] = {}
    for chain in chains:
        n = len(chain)
        if n == 0:
            continue
        weight = 1.0 / n
        for tp in chain:
            _accumulate(result, tp["source_code"], weight)
    return result


def compute_time_decay(
    chains: List[List[dict]],
    half_life: float = 7.0,
) -> Dict[str, float]:
    """
    Time decay: weight ∝ 2^(-days_before_conv / half_life).

    Weights normalised within each chain so that each chain contributes
    exactly 1.0 conversion in aggregate.
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
            _accumulate(result, tp["source_code"], w / total)
    return result
