-- ============================================================
-- BUILD TOUCHPOINT CHAINS
-- ============================================================
-- Reads visits_raw (YC Data Transfer format), flattens and
-- deduplicates visits, derives a SourceCode per visit using the
-- TraficSourceID convention from analyse_channels_chain.py, then
-- builds chronologically-ordered touchpoint chains for every
-- conversion of the target goal within the lookback window.
--
-- Parameters substituted by handler.py before execution:
--   {goal_id}       UInt32  – target goal ID
--   {counter_id}    UInt32  – Yandex Metrika counter
--   {lookback_days} UInt32  – attribution window in days (default 90)
--
-- SourceCode convention (mirrors analyse_channels_chain.py):
--   TraficSourceID values:
--     -1 / 0  : unknown / other referral
--     2       : organic search  → "2_{SearchEngineID}"
--               (e.g. 2_621 = Yandex, 2_1 = Google, 2_3 = Mail.ru)
--     3       : advertising     → "3_{AdvEngineID}"
--               + banner case   → "3_{AdvEngineID}_{ClickTargetType}"
--               (e.g. 3_1 = Yandex Direct, 3_2 = Google Ads)
--     4       : internal link   → "4"
--     5       : bookmarks/saved → "5"
--     6       : direct / typed  → "6"
--     7       : email           → "7"
--     8       : social network  → "8_{SocialSourceNetworkID}"
--               (e.g. 8_1 = VK, 8_2 = Facebook, 8_3 = OK)
--     9       : recommendation  → "9_{RecommendationSystemID}"
--     10      : messenger       → "10_{MessengerID}"
--
-- Requires ClickHouse 21.6+ for window function support.
-- ============================================================

-- Drop the previous run's data for this goal before rebuilding.
ALTER TABLE sessions_chains DROP PARTITION {goal_id};


INSERT INTO sessions_chains
(goal_id, chain_id, user_id, conversion_time, touchpoint_time,
 position, chain_length, source_code, days_before_conv, is_converting)

WITH

-- ----------------------------------------------------------------
-- Step 1: Flatten and deduplicate visits_raw.
--
-- YC Data Transfer uses CollapsingMergeTree(Sign):
--   sum(Sign) > 0 in HAVING discards cancelled records.
--
-- The same VisitID can be re-delivered with corrections;
--   argMax(field, VisitVersion) picks the latest value for each field.
--
-- TrafficSource is a Nested (parallel arrays); Model=1 marks the
--   primary traffic source for the visit.
-- ----------------------------------------------------------------
visits_flat AS (
    SELECT
        UserIDHash                                                                  AS user_id,
        VisitID,
        argMax(UTCStartTime, VisitVersion)                                          AS utc_start_time,
        toInt8(argMax(
            `TrafficSource.ID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        ))                                                                          AS trafic_source_id,
        argMax(
            `TrafficSource.SearchEngineID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                           AS search_engine_id,
        argMax(
            `TrafficSource.AdvEngineID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                           AS adv_engine_id,
        argMax(
            `TrafficSource.SocialSourceNetworkID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                           AS social_source_network_id,
        argMax(
            `TrafficSource.RecommendationSystemID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                           AS recommendation_system_id,
        argMax(
            `TrafficSource.MessengerID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                           AS messenger_id,
        argMax(
            `TrafficSource.ClickBannerID`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                           AS click_banner_id,
        argMax(
            `TrafficSource.ClickTargetType`[indexOf(`TrafficSource.Model`, toUInt8(1))],
            VisitVersion
        )                                                                           AS click_target_type,
        -- Goals.ID array for the latest version of this visit
        argMax(`Goals.ID`, VisitVersion)                                            AS goals_id
    FROM visits_raw
    WHERE CounterID = {counter_id}
    GROUP BY UserIDHash, VisitID, StartDate
    HAVING sum(Sign) > 0
),

-- ----------------------------------------------------------------
-- Step 2: Derive SourceCode.
--
-- Exactly mirrors the SourceCode expression in
-- analyse_channels_chain.py (metr_combine_insert_final_query).
-- ----------------------------------------------------------------
visits_with_source AS (
    SELECT
        user_id,
        VisitID,
        utc_start_time,
        goals_id,
        toString(trafic_source_id) || multiIf(
            -- Organic search: append SearchEngineID
            trafic_source_id = 2,
                '_' || toString(search_engine_id),
            -- Advertising with Yandex Direct banner: append AdvEngineID + ClickTargetType
            trafic_source_id = 3 AND adv_engine_id = 1 AND click_banner_id != 0,
                '_' || toString(adv_engine_id) || '_' || toString(click_target_type),
            -- Advertising (other): append AdvEngineID
            trafic_source_id = 3,
                '_' || toString(adv_engine_id),
            -- Social network: append SocialSourceNetworkID
            trafic_source_id = 8,
                '_' || toString(social_source_network_id),
            -- Recommendation system: append RecommendationSystemID
            trafic_source_id = 9,
                '_' || toString(recommendation_system_id),
            -- Messenger: append MessengerID
            trafic_source_id = 10,
                '_' || toString(messenger_id),
            -- Direct, email, internal, bookmarks, unknown: no suffix
            ''
        )                                                                           AS source_code
    FROM visits_flat
),

-- ----------------------------------------------------------------
-- Step 3: Find all converting visits.
-- A visit converts when goal_id is present in its Goals.ID array.
-- ----------------------------------------------------------------
converting_visits AS (
    SELECT
        user_id,
        VisitID                                                                     AS conv_visit_id,
        utc_start_time                                                              AS conversion_time
    FROM visits_with_source
    WHERE has(goals_id, toUInt32({goal_id}))
),

-- ----------------------------------------------------------------
-- Step 4: Collect all touchpoints within the lookback window for
-- each conversion, including the converting visit itself.
-- ----------------------------------------------------------------
touchpoints_raw AS (
    SELECT
        toUInt32({goal_id})                                                         AS goal_id,
        concat(
            toString(cv.user_id), '_',
            toString(toUnixTimestamp(cv.conversion_time))
        )                                                                           AS chain_id,
        cv.user_id                                                                  AS user_id,
        cv.conversion_time                                                          AS conversion_time,
        vc.utc_start_time                                                           AS touchpoint_time,
        vc.source_code                                                              AS source_code,
        toFloat64(dateDiff('second', vc.utc_start_time, cv.conversion_time))
            / 86400.0                                                               AS days_before_conv,
        if(vc.VisitID = cv.conv_visit_id, toUInt8(1), toUInt8(0))                  AS is_converting
    FROM converting_visits AS cv
    INNER JOIN visits_with_source AS vc
        ON  vc.user_id = cv.user_id
        AND vc.utc_start_time <= cv.conversion_time
        AND vc.utc_start_time >= cv.conversion_time - toIntervalDay({lookback_days})
),

-- ----------------------------------------------------------------
-- Step 5: Assign chronological position numbers within each chain.
-- position = 1 for the oldest touchpoint (first touch),
-- chain_length for the most recent (converting touch).
-- ----------------------------------------------------------------
touchpoints_positioned AS (
    SELECT
        goal_id,
        chain_id,
        user_id,
        conversion_time,
        touchpoint_time,
        source_code,
        days_before_conv,
        is_converting,
        toUInt32(
            row_number() OVER (PARTITION BY chain_id ORDER BY touchpoint_time ASC)
        )                                                                           AS position,
        toUInt32(count() OVER (PARTITION BY chain_id))                              AS chain_length
    FROM touchpoints_raw
)

SELECT
    goal_id, chain_id, user_id, conversion_time, touchpoint_time,
    position, chain_length, source_code, days_before_conv, is_converting
FROM touchpoints_positioned;
