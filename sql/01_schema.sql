-- ============================================================
-- SCHEMA: Attribution Analytics for Yandex Metrika
-- ============================================================
--
-- NOTE: visits_raw and hits_raw are created by YC Data Transfer.
-- Their exact schema depends on the connector version and may
-- differ from the DDL below. Verify against your Data Transfer
-- endpoint configuration before running.
--
-- Based on Yandex Metrika Logs API v2 field mapping.
-- Requires Managed ClickHouse 21.6+ (window function support).
-- ============================================================


-- ============================================================
-- RAW TABLES  (populated by YC Data Transfer)
-- ============================================================

CREATE TABLE IF NOT EXISTS visits_raw
(
    -- Identifiers
    CounterID           UInt32,
    VisitID             UInt64,
    ClientID            UInt64,

    -- Timing
    StartTime           DateTime,
    Duration            UInt32      DEFAULT 0,

    -- Session quality
    Bounce              UInt8       DEFAULT 0,
    PageViews           Int32       DEFAULT 0,

    -- UTM campaign parameters
    UTMSource           String      DEFAULT '',
    UTMMedium           String      DEFAULT '',
    UTMCampaign         String      DEFAULT '',
    UTMContent          String      DEFAULT '',
    UTMTerm             String      DEFAULT '',

    -- Traffic source classification (organic / ad / direct / referral / social)
    TrafficSource       String      DEFAULT '',
    SearchEngineID      UInt16      DEFAULT 0,
    SearchPhrase        String      DEFAULT '',
    AdvEngineID         UInt8       DEFAULT 0,

    -- Referer
    Referer             String      DEFAULT '',
    RefererDomain       String      DEFAULT '',

    -- Entry URL
    StartURL            String      DEFAULT '',

    -- Goals reached during this visit
    -- Array index N corresponds to the N-th goal event in the visit
    GoalsID             Array(UInt32),
    GoalsSerial         Array(UInt32),
    GoalsEventTime      Array(DateTime),
    GoalsCurrencyID     Array(UInt32),
    GoalsPrice          Array(Float64),

    -- Yandex internal "from" parameter
    FromParam           String      DEFAULT '',

    -- CollapsingMergeTree deduplication sign (-1 = cancel, +1 = keep)
    Sign                Int8        DEFAULT 1,

    -- Materialised partition column
    StartDate           Date        MATERIALIZED toDate(StartTime)
)
ENGINE = CollapsingMergeTree(Sign)
PARTITION BY toYYYYMM(StartDate)
ORDER BY (CounterID, ClientID, StartTime, VisitID)
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS hits_raw
(
    -- Identifiers
    CounterID           UInt32,
    WatchID             UInt64,
    ClientID            UInt64,
    VisitID             UInt64,

    -- Timing
    DateTime            DateTime,

    -- Page
    URL                 String      DEFAULT '',
    Title               String      DEFAULT '',

    -- Referer
    Referer             String      DEFAULT '',
    RefererDomain       String      DEFAULT '',

    -- UTM campaign parameters
    UTMSource           String      DEFAULT '',
    UTMMedium           String      DEFAULT '',
    UTMCampaign         String      DEFAULT '',
    UTMContent          String      DEFAULT '',
    UTMTerm             String      DEFAULT '',

    -- Goal event on this hit (0 = none)
    GoalID              UInt32      DEFAULT 0,

    Sign                Int8        DEFAULT 1,

    HitDate             Date        MATERIALIZED toDate(DateTime)
)
ENGINE = CollapsingMergeTree(Sign)
PARTITION BY toYYYYMM(HitDate)
ORDER BY (CounterID, ClientID, DateTime, WatchID)
SETTINGS index_granularity = 8192;


-- ============================================================
-- DERIVED TABLES
-- ============================================================

-- One row per touchpoint in a conversion chain.
-- Rebuilt daily by the Cloud Function.
CREATE TABLE IF NOT EXISTS sessions_chains
(
    goal_id             UInt32,
    chain_id            String,     -- '{client_id}_{unix_conversion_time}'
    client_id           UInt64,
    conversion_time     DateTime,
    touchpoint_time     DateTime,
    position            UInt32,     -- 1 = oldest touchpoint
    chain_length        UInt32,     -- total touchpoints in chain
    channel             String,     -- normalised channel label
    days_before_conv    Float64,    -- days between touchpoint and conversion
    is_converting       UInt8       -- 1 if this touchpoint IS the converting visit
)
ENGINE = ReplacingMergeTree()
PARTITION BY goal_id
ORDER BY (goal_id, chain_id, position)
SETTINGS index_granularity = 8192;


-- Attribution results per model.
-- Each model table has the same structure; rebuilt daily.

CREATE TABLE IF NOT EXISTS attribution_first_touch
(
    goal_id             UInt32,
    channel             String,
    conversions         Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, channel)
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS attribution_last_touch
(
    goal_id             UInt32,
    channel             String,
    conversions         Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, channel)
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS attribution_linear
(
    goal_id             UInt32,
    channel             String,
    conversions         Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, channel)
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS attribution_time_decay
(
    goal_id             UInt32,
    channel             String,
    conversions         Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, channel)
SETTINGS index_granularity = 8192;
