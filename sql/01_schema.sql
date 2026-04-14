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
-- DERIVED TABLES
-- ============================================================

-- One row per touchpoint in a conversion chain.
-- Rebuilt daily by the Cloud Function.
--
-- source_code follows the SourceCode convention from
-- analyse_channels_chain.py  (TraficSourceID-based):
--   "2_621"  = Yandex organic (SearchEngineID 621)
--   "2_1"    = Google organic (SearchEngineID 1)
--   "3_1"    = Yandex Direct
--   "3_1_N"  = Yandex Direct with banner (ClickTargetType N)
--   "3_2"    = Google Ads
--   "6"      = direct (typed URL / bookmarks)
--   "8_1"    = VK social
--   "7"      = email
--   etc.
CREATE TABLE IF NOT EXISTS sessions_chains
(
    goal_id             UInt32,
    chain_id            String,     -- '{user_id}_{unix_conversion_time}'
    user_id             UInt64,     -- UserIDHash from visits_raw
    conversion_time     DateTime,
    touchpoint_time     DateTime,
    position            UInt32,     -- 1 = oldest touchpoint in chain
    chain_length        UInt32,
    source_code         String,     -- normalised TraficSourceID-based code
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
