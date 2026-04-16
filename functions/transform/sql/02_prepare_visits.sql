-- ============================================================
-- STEP 1: PREPARE VISITS
-- ============================================================
-- Reads visits_raw (YC Data Transfer CollapsingMergeTree format),
-- deduplicates and flattens into one row per visit, and derives
-- the SourceCode channel label.
--
-- Mirrors metr_raw_create_query + metr_raw_insert_query from
-- analyse_channels_chain.py.
--
-- Parameters substituted by handler.py:
--   {counter_id}  UInt32  – Yandex Metrika counter
--   {goal_id}     UInt32  – target goal (for Conversions count)
--
-- Deduplication strategy (from analyse_channels_chain.py):
--   * sum(Sign) > 0 in HAVING discards CollapsingMergeTree cancels
--   * argMax(field, VisitVersion) picks the latest corrected value
--     when the same VisitID is re-delivered with updates
--
-- SourceCode convention (TraficSourceID-based, official types):
--   -1 INTERNAL  Внутренние переходы           → "-1"
--    0 DIRECT    Прямые заходы                 → "0"
--    1 LINK      Переходы по ссылкам на сайтах → "1"
--    2 SEARCH    Из поисковых систем           → "2_{SearchEngineID}"
--    3 ADV       Переходы по рекламе           → "3_{AdvEngineID}"
--                + баннер                      → "3_{AdvEngineID}_{ClickTargetType}"
--    4 LOCAL     С сохранённых страниц         → "4"
--    5 UNKNOW    Не определён                  → "5"
--    6 EXTERNAL  По внешним ссылкам            → "6"
--    7 MAIL      С почтовых рассылок           → "7"
--    8 SOCIAL    Из социальных сетей           → "8_{SocialSourceNetworkID}"
--    9 RECOMMEND Из рекомендательных систем    → "9_{RecommendationSystemID}"
--   10 MESSENGER Из мессенджеров               → "10_{MessengerID}"
--   11 QR        По QR коду                    → "11"
-- ============================================================

INSERT INTO visits_prepared
    (CounterID, UserID, VisitID, StartDate, UTCStartTime, Duration, SourceCode, Conversions, GoalRevenueCur)

WITH

-- Flatten Nested arrays and pick the latest version of each field.
-- The primary traffic source is the element where TrafficSource.Model = 1.
flat AS (
    SELECT
        CounterID,
        CounterUserIDHash                                                                AS UserID,
        VisitID,
        StartDate,
        argMax(UTCStartTime, VisitVersion)                                               AS UTCStartTime,
        argMax(Duration, VisitVersion)                                                   AS Duration,
        toInt8(argMax(
            `TrafficSource.ID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        ))                                                                               AS trafic_source_id,
        argMax(
            `TrafficSource.SearchEngineID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                                AS search_engine_id,
        argMax(
            `TrafficSource.AdvEngineID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                                AS adv_engine_id,
        argMax(
            `TrafficSource.SocialSourceNetworkID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                                AS social_source_network_id,
        argMax(
            `TrafficSource.RecommendationSystemID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                                AS recommendation_system_id,
        argMax(
            `TrafficSource.MessengerID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                                AS messenger_id,
        argMax(
            `TrafficSource.ClickBannerID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                                AS click_banner_id,
        argMax(
            `TrafficSource.ClickTargetType`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                                AS click_target_type,
        -- Count how many times goal_id was reached in this visit.
        -- Mirrors conversion_formula() in DataPreparer for a single goal:
        --   length(arrayFilter(x -> has([goal_id], x), Goals.ID))
        toUInt32(length(arrayFilter(
            x -> x = toUInt32({goal_id}),
            argMax(`Goals.ID`, VisitVersion)
        )))                                                                              AS Conversions,
        -- Sum of Goals.Price / 1e6 for goal_id occurrences in this visit.
        -- Goals.Price stores values pre-multiplied by 1e6 in Goals.Currency units.
        toFloat64(arraySum(arrayFilter(
            (price, id) -> id = toUInt32({goal_id}),
            argMax(`Goals.Price`, VisitVersion),
            argMax(`Goals.ID`,    VisitVersion)
        ))) / 1e6                                                                        AS GoalRevenueCur
    FROM visits_raw
    WHERE CounterID = {counter_id}
    GROUP BY CounterID, CounterUserIDHash, VisitID, StartDate
    HAVING sum(Sign) > 0
)

SELECT
    CounterID,
    UserID,
    VisitID,
    StartDate,
    UTCStartTime,
    Duration,
    -- SourceCode derivation mirrors the multiIf() in
    -- metr_combine_insert_final_query (analyse_channels_chain.py)
    toString(trafic_source_id) || multiIf(
        trafic_source_id = 2,
            '_' || toString(search_engine_id),
        trafic_source_id = 3 AND adv_engine_id = 1 AND click_banner_id != 0,
            '_' || toString(adv_engine_id) || '_' || toString(click_target_type),
        trafic_source_id = 3,
            '_' || toString(adv_engine_id),
        trafic_source_id = 8,
            '_' || toString(social_source_network_id),
        trafic_source_id = 9,
            '_' || toString(recommendation_system_id),
        trafic_source_id = 10,
            '_' || toString(messenger_id),
        ''
    )                                                                                    AS SourceCode,
    Conversions,
    GoalRevenueCur
FROM flat;
