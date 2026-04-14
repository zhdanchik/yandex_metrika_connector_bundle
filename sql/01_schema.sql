-- ============================================================
-- SCHEMA: Attribution Analytics for Yandex Metrika
-- ============================================================
--
-- visits_raw reflects the exact table produced by YC Data Transfer
-- for Yandex Metrika visits, as documented in:
--   https://github.com/zhdanchik/yandex_metrika_connector_cases
--
-- Key design points:
--   * CollapsingMergeTree(Sign) — Data Transfer uses +1/-1 sign rows
--   * VisitVersion — Data Transfer may re-send the same VisitID with
--     corrections; argMax(field, VisitVersion) picks the latest value
--   * TrafficSource — Nested array; Model=1 marks the primary source
--   * Goals.ID — Array of goal IDs reached during this visit
--
-- Requires Managed ClickHouse 21.6+ (window function support).
-- ============================================================


-- ============================================================
-- RAW TABLE  (populated by YC Data Transfer)
-- ============================================================

CREATE TABLE IF NOT EXISTS visits_raw
(
    CounterID                              UInt32,
    UserIDHash                             UInt64,     -- anonymised visitor ID
    VisitID                                UInt64,
    StartDate                              Date,
    UTCStartTime                           DateTime,
    Duration                               UInt32      DEFAULT 0,
    VisitVersion                           UInt32      DEFAULT 0, -- for argMax deduplication

    -- Traffic source data as a Nested (parallel arrays).
    -- Use indexOf(TrafficSource.Model, 1) to find the primary source.
    `TrafficSource.Model`                  Array(UInt8),
    `TrafficSource.ID`                     Array(Int8),
    `TrafficSource.StartTime`              Array(DateTime),
    `TrafficSource.SearchEngineID`         Array(UInt16),
    `TrafficSource.AdvEngineID`            Array(UInt8),
    `TrafficSource.SocialSourceNetworkID`  Array(UInt8),
    `TrafficSource.RecommendationSystemID` Array(UInt8),
    `TrafficSource.MessengerID`            Array(UInt8),
    `TrafficSource.ClickBannerID`          Array(UInt64),
    `TrafficSource.ClickTargetType`        Array(UInt16),

    -- Goals reached during this visit (Nested parallel arrays).
    `Goals.ID`                             Array(UInt32),
    `Goals.Serial`                         Array(UInt32),
    `Goals.EventTime`                      Array(DateTime),
    `Goals.Price`                          Array(Float64),
    `Goals.Currency`                       Array(Int32),

    -- E-commerce purchase events (optional, used for revenue).
    `EPurchase.ID`                         Array(UInt64),
    `EPurchase.Revenue`                    Array(Float64),

    -- CollapsingMergeTree sign: +1 = insert, -1 = cancel
    Sign                                   Int8        DEFAULT 1
)
ENGINE = CollapsingMergeTree(Sign)
PARTITION BY toYYYYMM(StartDate)
ORDER BY (CounterID, UserIDHash, StartDate, VisitID)
SETTINGS index_granularity = 8192;


-- ============================================================
-- INTERMEDIATE TABLES  (rebuilt by Cloud Function each run)
-- ============================================================

-- Step 1 output: one row per visit with flat SourceCode and Conversions.
-- Counter-specific and goal-specific; fully truncated each run.
-- Mirrors metr_raw from analyse_channels_chain.py.
CREATE TABLE IF NOT EXISTS visits_prepared
(
    CounterID       UInt32,
    UserID          UInt64,
    VisitID         UInt64,
    StartDate       Date,
    UTCStartTime    DateTime,
    Duration        UInt32      DEFAULT 0,
    SourceCode      String,     -- TraficSourceID-based code (see 02_prepare_visits.sql)
    Conversions     UInt32      DEFAULT 0   -- count of goal_id occurrences in this visit
)
ENGINE = MergeTree
ORDER BY (CounterID, UserID, UTCStartTime, VisitID)
SETTINGS index_granularity = 8192;


-- Step 2 output: one row per (user × converting-visit-position).
-- Each row stores the full chain as arrays, from the last session
-- break (NULL sentinel) up to and including the converting visit.
-- Mirrors metr_combined from analyse_channels_chain.py.
-- Partitioned by goal_id so multiple goals can coexist.
CREATE TABLE IF NOT EXISTS visits_combined
(
    goal_id                   UInt32,
    CounterID                 UInt32,
    UserID                    UInt64,
    -- Parallel arrays: one element per touchpoint in the chain.
    `history.VisitID`         Array(UInt64),
    `history.SourceCode`      Array(String),
    `history.UTCStartTime`    Array(DateTime),
    `history.EventType`       Array(String),
    `history.Conversions`     Array(Float64),
    -- Scalar: conversion count at the chain's endpoint (= history.Conversions[-1])
    Conversions               Float64
)
ENGINE = MergeTree
PARTITION BY goal_id
ORDER BY (goal_id, CounterID, UserID)
SETTINGS index_granularity = 8192;


-- ============================================================
-- RESULT TABLES  (rebuilt daily by Cloud Function)
-- ============================================================

-- All four attribution models × three metrics in one table.
-- Computed directly from visits_combined by 05_attribution_models.sql.
--
-- attribution_type : 'first_touch' | 'last_touch' | 'linear' | 'time_decay'
-- metric_type      : 'visits' | 'conversions' | 'revenue'
CREATE TABLE IF NOT EXISTS attribution_results
(
    goal_id             UInt32,
    attribution_type    LowCardinality(String),
    metric_type         LowCardinality(String),
    source_code         String,
    value               Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, attribution_type, metric_type, source_code)
SETTINGS index_granularity = 8192;
