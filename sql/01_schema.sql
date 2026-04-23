-- ============================================================
-- SCHEMA: Attribution Analytics for Yandex Metrika
-- ============================================================
--
-- visits_raw reflects the exact table produced by YC Data Transfer
-- for Yandex Metrika visits, as documented in:
--   https://github.com/zhdanchik/yandex_metrika_connector_cases
--
-- Key design points:
--   * VersionedCollapsingMergeTree(Sign, VisitVersion) — Data Transfer uses +1/-1 sign rows
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
    CounterUserIDHash                      UInt64,     -- anonymised visitor ID
    VisitID                                UInt64,
    StartDate                              Date,
    UTCStartTime                           DateTime,
    Duration                               UInt32      DEFAULT 0,
    VisitVersion                           UInt32      DEFAULT 0, -- for argMax deduplication

    -- Traffic source data as a Nested (parallel arrays).
    -- Use indexOf(TrafficSource.Model, 1) to find the primary source.
    -- NOTE: SearchEngineRootID must be included in the YC Data Transfer
    -- visits-table config (it is the parent grouping of SearchEngineID —
    -- e.g. SearchEngineID=621 "Яндекс.Поиск" maps to RootID=2 "Яндекс").
    `TrafficSource.Model`                  Array(UInt8),
    `TrafficSource.ID`                     Array(Int8),
    `TrafficSource.StartTime`              Array(DateTime),
    `TrafficSource.SearchEngineID`         Array(UInt16),
    `TrafficSource.SearchEngineRootID`     Array(UInt16),
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

    -- VersionedCollapsingMergeTree sign: +1 = insert, -1 = cancel
    Sign                                   Int8        DEFAULT 1
)
ENGINE = VersionedCollapsingMergeTree(Sign, VisitVersion)
PARTITION BY toMonday(StartDate)
ORDER BY (CounterID, StartDate, CounterUserIDHash, VisitID)
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
    Conversions     UInt32      DEFAULT 0,  -- count of goal_id occurrences in this visit
    GoalRevenueCur  Float64     DEFAULT 0   -- sum(Goals.Price / 1e6) for goal_id hits in this visit
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
    -- Scalars at the chain's endpoint (values of the last visit in the chain).
    Conversions               Float64,  -- = history.Conversions[-1]
    GoalRevenueCur            Float64   -- = sum(Goals.Price/1e6) for goal_id at the last visit
)
ENGINE = MergeTree
PARTITION BY goal_id
ORDER BY (goal_id, CounterID, UserID)
SETTINGS index_granularity = 8192;


-- ============================================================
-- RESULT TABLES  (rebuilt daily by Cloud Function)
-- ============================================================

-- All attribution models in one table, one row per
-- (goal, model, date, channel).
-- Computed directly from visits_combined by 05_attribution_models.sql.
--
-- attribution_type : 'first_touch' | 'last_touch' | 'last_significant' |
--                    'linear' | 'time_decay'
-- start_date       : date of the chain's endpoint visit (for time-series viz)
--
-- assisted_conversions / assisted_revenue — number of converting chains
-- where this source appeared but was NOT the last touch.  Model-independent
-- metric, populated only on 'last_touch' rows to avoid double-counting when
-- aggregating across models.  For other rows both columns are 0.
CREATE TABLE IF NOT EXISTS attribution_results
(
    goal_id                UInt32,
    attribution_type       LowCardinality(String),
    start_date             Date,
    source_code            String,
    visits                 Float64,
    conversions            Float64,
    revenue                Float64,
    assisted_conversions   Float64     DEFAULT 0,
    assisted_revenue       Float64     DEFAULT 0,
    calculated_at          DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, attribution_type, start_date, source_code)
SETTINGS index_granularity = 8192;


-- Source-to-source transition matrix.  One row per
-- (goal, date, prev_source, next_source) aggregated from consecutive
-- pairs in visits_combined chains.  Powers the "poor man's Sankey" —
-- a heatmap of channel transitions in DataLens.
--
-- transitions        : count of such pair occurrences (chain-weighted)
-- converting_chains  : sum of the pair's chain.Conversions (same pair in
--                      a 3-hop converting chain counts once; 0 in a chain
--                      that did not convert on the endpoint visit).
CREATE TABLE IF NOT EXISTS source_transitions
(
    goal_id             UInt32,
    start_date          Date,
    prev_source_code    String,
    next_source_code    String,
    transitions         Float64,
    converting_chains   Float64,
    calculated_at       DateTime    DEFAULT now()
)
ENGINE = ReplacingMergeTree(calculated_at)
PARTITION BY goal_id
ORDER BY (goal_id, start_date, prev_source_code, next_source_code)
SETTINGS index_granularity = 8192;


-- ============================================================
-- LOOKUP TABLES  (rebuilt by handler.py from dicts/*.csv on every run)
-- ============================================================
-- Simple (id → human-readable Russian name) maps for the five
-- Yandex-Metrika sub-source vocabularies used in SourceCode.
--
-- Populated by handler.py: TRUNCATE + bulk-INSERT from the five CSV
-- files in dicts/ (bundled into the function ZIP).  Thin regular tables
-- keep DataLens free to LEFT JOIN without CH-dictionary machinery.
--
-- See dicts/README.md for the CSV format and v_attribution_results
-- below for how these tables become human-readable source_name.

CREATE TABLE IF NOT EXISTS dict_search_engine_roots
(
    id       UInt16,
    name_ru  String
) ENGINE = MergeTree ORDER BY id;

CREATE TABLE IF NOT EXISTS dict_adv_engines
(
    id       UInt8,
    name_ru  String
) ENGINE = MergeTree ORDER BY id;

CREATE TABLE IF NOT EXISTS dict_social_networks
(
    id       UInt8,
    name_ru  String
) ENGINE = MergeTree ORDER BY id;

CREATE TABLE IF NOT EXISTS dict_recommendation_systems
(
    id       UInt8,
    name_ru  String
) ENGINE = MergeTree ORDER BY id;

CREATE TABLE IF NOT EXISTS dict_messengers
(
    id       UInt8,
    name_ru  String
) ENGINE = MergeTree ORDER BY id;


-- ============================================================
-- VIEWS: human-readable attribution_results & source_transitions
-- ============================================================
-- Resolve source_code → source_name (Russian) via the dict_* tables.
-- Names for TraficSourceID roots are hardcoded (12 stable values) —
-- sub-IDs are resolved via LEFT JOIN.
--
-- Fallback when a sub-ID is missing from the dict: "Родитель: код N"
-- so data is never silently lost.  Fill the CSVs in dicts/ and the
-- fallbacks disappear.
--
-- v_attribution_results   — attribution_results + source_name
-- v_source_transitions    — source_transitions   + prev_source_name
--                                                 + next_source_name

CREATE OR REPLACE VIEW v_attribution_results AS
WITH
    parts AS (
        SELECT
            goal_id,
            attribution_type,
            start_date,
            source_code,
            visits,
            conversions,
            revenue,
            assisted_conversions,
            assisted_revenue,
            calculated_at,
            toInt16OrNull(splitByChar('_', source_code)[1])       AS root_id,
            toInt32OrZero(splitByChar('_', source_code)[2])       AS sub_id
        FROM attribution_results
    )
SELECT
    goal_id,
    attribution_type,
    start_date,
    source_code,
    visits,
    conversions,
    revenue,
    assisted_conversions,
    assisted_revenue,
    calculated_at,
    multiIf(
        root_id = -1, 'Внутренние переходы',
        root_id =  0, 'Прямые заходы',
        root_id =  1, 'Переходы по ссылкам на сайтах',
        root_id =  2, concat('Поиск: ', coalesce(nullIf(se.name_ru, ''), concat('код ', toString(sub_id)))),
        root_id =  3, concat('Реклама: ', coalesce(nullIf(ad.name_ru, ''), concat('код ', toString(sub_id)))),
        root_id =  4, 'С сохранённых страниц',
        root_id =  5, 'Источник не определён',
        root_id =  6, 'По внешним ссылкам',
        root_id =  7, 'Почтовые рассылки',
        root_id =  8, concat('Соцсети: ', coalesce(nullIf(sn.name_ru, ''), concat('код ', toString(sub_id)))),
        root_id =  9, concat('Рекомендации: ', coalesce(nullIf(rs.name_ru, ''), concat('код ', toString(sub_id)))),
        root_id = 10, concat('Мессенджеры: ', coalesce(nullIf(ms.name_ru, ''), concat('код ', toString(sub_id)))),
        root_id = 11, 'QR-код',
        source_code
    ) AS source_name
FROM parts
LEFT JOIN dict_search_engine_roots    AS se ON root_id = 2  AND toUInt16(sub_id) = se.id
LEFT JOIN dict_adv_engines            AS ad ON root_id = 3  AND toUInt8(sub_id)  = ad.id
LEFT JOIN dict_social_networks        AS sn ON root_id = 8  AND toUInt8(sub_id)  = sn.id
LEFT JOIN dict_recommendation_systems AS rs ON root_id = 9  AND toUInt8(sub_id)  = rs.id
LEFT JOIN dict_messengers             AS ms ON root_id = 10 AND toUInt8(sub_id)  = ms.id;


-- Same resolution applied to both ends of every transition.  Ten
-- LEFT JOINs (5 dicts × 2 sides) against tiny lookup tables — trivial
-- for the typical transition-matrix row count.
CREATE OR REPLACE VIEW v_source_transitions AS
WITH
    t AS (
        SELECT
            goal_id,
            start_date,
            prev_source_code,
            next_source_code,
            transitions,
            converting_chains,
            calculated_at,
            toInt16OrNull(splitByChar('_', prev_source_code)[1])  AS prev_root_id,
            toInt32OrZero(splitByChar('_', prev_source_code)[2])  AS prev_sub_id,
            toInt16OrNull(splitByChar('_', next_source_code)[1])  AS next_root_id,
            toInt32OrZero(splitByChar('_', next_source_code)[2])  AS next_sub_id
        FROM source_transitions
    )
SELECT
    goal_id,
    start_date,
    prev_source_code,
    next_source_code,
    transitions,
    converting_chains,
    calculated_at,
    multiIf(
        prev_root_id = -1, 'Внутренние переходы',
        prev_root_id =  0, 'Прямые заходы',
        prev_root_id =  1, 'Переходы по ссылкам на сайтах',
        prev_root_id =  2, concat('Поиск: ', coalesce(nullIf(p_se.name_ru, ''), concat('код ', toString(prev_sub_id)))),
        prev_root_id =  3, concat('Реклама: ', coalesce(nullIf(p_ad.name_ru, ''), concat('код ', toString(prev_sub_id)))),
        prev_root_id =  4, 'С сохранённых страниц',
        prev_root_id =  5, 'Источник не определён',
        prev_root_id =  6, 'По внешним ссылкам',
        prev_root_id =  7, 'Почтовые рассылки',
        prev_root_id =  8, concat('Соцсети: ', coalesce(nullIf(p_sn.name_ru, ''), concat('код ', toString(prev_sub_id)))),
        prev_root_id =  9, concat('Рекомендации: ', coalesce(nullIf(p_rs.name_ru, ''), concat('код ', toString(prev_sub_id)))),
        prev_root_id = 10, concat('Мессенджеры: ', coalesce(nullIf(p_ms.name_ru, ''), concat('код ', toString(prev_sub_id)))),
        prev_root_id = 11, 'QR-код',
        prev_source_code
    ) AS prev_source_name,
    multiIf(
        next_root_id = -1, 'Внутренние переходы',
        next_root_id =  0, 'Прямые заходы',
        next_root_id =  1, 'Переходы по ссылкам на сайтах',
        next_root_id =  2, concat('Поиск: ', coalesce(nullIf(n_se.name_ru, ''), concat('код ', toString(next_sub_id)))),
        next_root_id =  3, concat('Реклама: ', coalesce(nullIf(n_ad.name_ru, ''), concat('код ', toString(next_sub_id)))),
        next_root_id =  4, 'С сохранённых страниц',
        next_root_id =  5, 'Источник не определён',
        next_root_id =  6, 'По внешним ссылкам',
        next_root_id =  7, 'Почтовые рассылки',
        next_root_id =  8, concat('Соцсети: ', coalesce(nullIf(n_sn.name_ru, ''), concat('код ', toString(next_sub_id)))),
        next_root_id =  9, concat('Рекомендации: ', coalesce(nullIf(n_rs.name_ru, ''), concat('код ', toString(next_sub_id)))),
        next_root_id = 10, concat('Мессенджеры: ', coalesce(nullIf(n_ms.name_ru, ''), concat('код ', toString(next_sub_id)))),
        next_root_id = 11, 'QR-код',
        next_source_code
    ) AS next_source_name
FROM t
LEFT JOIN dict_search_engine_roots    AS p_se ON prev_root_id = 2  AND toUInt16(prev_sub_id) = p_se.id
LEFT JOIN dict_adv_engines            AS p_ad ON prev_root_id = 3  AND toUInt8(prev_sub_id)  = p_ad.id
LEFT JOIN dict_social_networks        AS p_sn ON prev_root_id = 8  AND toUInt8(prev_sub_id)  = p_sn.id
LEFT JOIN dict_recommendation_systems AS p_rs ON prev_root_id = 9  AND toUInt8(prev_sub_id)  = p_rs.id
LEFT JOIN dict_messengers             AS p_ms ON prev_root_id = 10 AND toUInt8(prev_sub_id)  = p_ms.id
LEFT JOIN dict_search_engine_roots    AS n_se ON next_root_id = 2  AND toUInt16(next_sub_id) = n_se.id
LEFT JOIN dict_adv_engines            AS n_ad ON next_root_id = 3  AND toUInt8(next_sub_id)  = n_ad.id
LEFT JOIN dict_social_networks        AS n_sn ON next_root_id = 8  AND toUInt8(next_sub_id)  = n_sn.id
LEFT JOIN dict_recommendation_systems AS n_rs ON next_root_id = 9  AND toUInt8(next_sub_id)  = n_rs.id
LEFT JOIN dict_messengers             AS n_ms ON next_root_id = 10 AND toUInt8(next_sub_id)  = n_ms.id;


-- ============================================================
-- VIEW: long-format assisted vs direct conversions
-- ============================================================
-- Reshapes the "last_touch" rows of v_attribution_results so that
-- "прямые" (direct) and "ассоциированные" (assisted) conversions
-- become SEPARATE ROWS rather than two columns.  Lets DataLens draw
-- a grouped bar chart without fighting Measure Names / stacking
-- defaults: you just use (source_name, metric_type) as two X axes
-- and a single measure — bars sit side by side naturally.
CREATE OR REPLACE VIEW v_assisted_long AS
SELECT
    goal_id,
    start_date,
    source_code,
    source_name,
    'Прямые'              AS metric_type,
    conversions           AS value,
    revenue               AS value_money
FROM v_attribution_results
WHERE attribution_type = 'last_touch'
UNION ALL
SELECT
    goal_id,
    start_date,
    source_code,
    source_name,
    'Ассоциированные'     AS metric_type,
    assisted_conversions  AS value,
    assisted_revenue      AS value_money
FROM v_attribution_results
WHERE attribution_type = 'last_touch';
