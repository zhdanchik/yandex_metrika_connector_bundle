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
    Conversions     UInt32      DEFAULT 0  -- count of goal_id occurrences in this visit
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
    -- Last element [-1] is always the converting visit.
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

-- One row per touchpoint in a conversion chain.
-- source_code follows the SourceCode convention from
-- analyse_channels_chain.py (TraficSourceID-based):
--   "-1" INTERNAL  Внутренние переходы
--   "0"  DIRECT    Прямые заходы
--   "1"  LINK      Переходы по ссылкам на сайтах
--   "2_N" SEARCH   Из поисковых систем  (N=SearchEngineID: 621=Яндекс, 1=Google)
--   "3_N" ADV      По рекламе           (N=AdvEngineID: 1=Яндекс Директ, 2=Google Ads)
--   "3_1_N"        Яндекс Директ с баннером (N=ClickTargetType)
--   "4"  LOCAL     С сохранённых страниц
--   "5"  UNKNOW    Не определён
--   "6"  EXTERNAL  По внешним ссылкам
--   "7"  MAIL      С почтовых рассылок
--   "8_N" SOCIAL   Из соцсетей         (N=SocialSourceNetworkID: 1=VK, 2=FB, 3=OK)
--   "9_N" RECOMMEND Из рекомендательных систем
--   "10_N" MESSENGER Из мессенджеров
--   "11" QR        По QR коду
CREATE TABLE IF NOT EXISTS sessions_chains
(
    goal_id             UInt32,
    chain_id            String,     -- '{user_id}_{conv_visit_id}'
    user_id             UInt64,
    conversion_time     DateTime,
    touchpoint_time     DateTime,
    position            UInt32,     -- 1 = oldest touchpoint in chain
    chain_length        UInt32,
    source_code         String,
    days_before_conv    Float64,
    is_converting       UInt8       -- 1 if this touchpoint IS the converting visit
)
ENGINE = ReplacingMergeTree()
PARTITION BY goal_id
ORDER BY (goal_id, chain_id, position)
SETTINGS index_granularity = 8192;


-- Attribution results per model (same structure for all four models).

CREATE TABLE IF NOT EXISTS attribution_first_touch
(
    goal_id             UInt32,
    source_code         String,
    conversions         Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, source_code)
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS attribution_last_touch
(
    goal_id             UInt32,
    source_code         String,
    conversions         Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, source_code)
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS attribution_linear
(
    goal_id             UInt32,
    source_code         String,
    conversions         Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, source_code)
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS attribution_time_decay
(
    goal_id             UInt32,
    source_code         String,
    conversions         Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, source_code)
SETTINGS index_granularity = 8192;
