-- ============================================================
-- BUILD TOUCHPOINT CHAINS
-- ============================================================
-- Reads visits_raw, derives a normalised channel per visit,
-- identifies converting visits (those that include goal_id in
-- their GoalsID array), then for each conversion collects all
-- prior visits by the same ClientID within the lookback window
-- and numbers them chronologically.
--
-- Parameters substituted by handler.py before execution:
--   {goal_id}       UInt32  – target goal ID
--   {counter_id}    UInt32  – Yandex Metrika counter
--   {lookback_days} UInt32  – attribution window in days (default 90)
--
-- Requires ClickHouse 21.6+ for window function support.
-- ============================================================

-- Drop the previous run's data for this goal so we get a clean
-- rebuild rather than duplicate rows.
ALTER TABLE sessions_chains DROP PARTITION {goal_id};


INSERT INTO sessions_chains
(goal_id, chain_id, client_id, conversion_time, touchpoint_time,
 position, chain_length, channel, days_before_conv, is_converting)

WITH

-- ----------------------------------------------------------------
-- Step 1: Annotate every visit with a normalised channel label.
--
-- Priority:
--   1. UTM source+medium  -> '{utm_source} / {utm_medium}'
--   2. UTM source only    -> '{utm_source} / organic'
--   3. Paid traffic (no UTM but TrafficSource = ad/banner/direct-ad)
--                         -> 'paid / cpc'
--   4. Organic search     -> 'organic / organic'
--      (TrafficSource = organic, possibly with SearchEngineID)
--   5. Social             -> '{referer_domain} / social'
--   6. Referral           -> '{referer_domain} / referral'
--   7. Direct / unknown   -> 'direct / none'
-- ----------------------------------------------------------------
visits_with_channel AS (
    SELECT
        CounterID,
        VisitID,
        ClientID,
        StartTime,
        GoalsID,
        multiIf(
            UTMSource != '' AND UTMMedium != '',
                concat(UTMSource, ' / ', UTMMedium),

            UTMSource != '' AND UTMMedium = '',
                concat(UTMSource, ' / organic'),

            TrafficSource IN ('ad', 'banner', 'context', 'paid'),
                'paid / cpc',

            TrafficSource = 'organic',
                'organic / organic',

            TrafficSource = 'social' AND RefererDomain != '',
                concat(RefererDomain, ' / social'),

            RefererDomain != '' AND RefererDomain != 'null',
                concat(RefererDomain, ' / referral'),

            'direct / none'
        ) AS channel
    FROM visits_raw
    WHERE CounterID = {counter_id}
      AND Sign = 1
),

-- ----------------------------------------------------------------
-- Step 2: Find all converting visits.
-- A visit converts if goal_id appears in its GoalsID array.
-- ----------------------------------------------------------------
converting_visits AS (
    SELECT
        ClientID,
        VisitID             AS conv_visit_id,
        StartTime           AS conversion_time
    FROM visits_with_channel
    WHERE has(GoalsID, {goal_id})
),

-- ----------------------------------------------------------------
-- Step 3: For each conversion, match every prior touchpoint
-- within the lookback window (inclusive of the converting visit).
-- ----------------------------------------------------------------
touchpoints_raw AS (
    SELECT
        toUInt32({goal_id})                                                  AS goal_id,
        concat(
            toString(cv.ClientID), '_',
            toString(toUnixTimestamp(cv.conversion_time))
        )                                                                    AS chain_id,
        cv.ClientID                                                          AS client_id,
        cv.conversion_time                                                   AS conversion_time,
        vc.StartTime                                                         AS touchpoint_time,
        vc.channel                                                           AS channel,
        toFloat64(
            dateDiff('second', vc.StartTime, cv.conversion_time)
        ) / 86400.0                                                          AS days_before_conv,
        if(vc.VisitID = cv.conv_visit_id, toUInt8(1), toUInt8(0))           AS is_converting
    FROM converting_visits AS cv
    INNER JOIN visits_with_channel AS vc
        ON  vc.ClientID = cv.ClientID
        AND vc.StartTime <= cv.conversion_time
        AND vc.StartTime >= cv.conversion_time - toIntervalDay({lookback_days})
),

-- ----------------------------------------------------------------
-- Step 4: Assign chronological position numbers within each chain.
-- position = 1 for the oldest touchpoint, chain_length for the
-- converting touchpoint.
-- ----------------------------------------------------------------
touchpoints_positioned AS (
    SELECT
        goal_id,
        chain_id,
        client_id,
        conversion_time,
        touchpoint_time,
        channel,
        days_before_conv,
        is_converting,
        toUInt32(
            row_number() OVER (
                PARTITION BY chain_id
                ORDER BY touchpoint_time ASC
            )
        )                                                                    AS position,
        toUInt32(
            count() OVER (PARTITION BY chain_id)
        )                                                                    AS chain_length
    FROM touchpoints_raw
)

SELECT
    goal_id,
    chain_id,
    client_id,
    conversion_time,
    touchpoint_time,
    position,
    chain_length,
    channel,
    days_before_conv,
    is_converting
FROM touchpoints_positioned;
