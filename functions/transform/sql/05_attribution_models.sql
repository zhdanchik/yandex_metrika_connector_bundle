-- ============================================================
-- STEP 3: ATTRIBUTION MODELS + ASSISTED + TRANSITION MATRIX
-- ============================================================
-- Computes attribution credit per (source_code, start_date) across
-- five models, plus assisted conversions and a pairwise transition
-- matrix.  Reads visits_combined directly.
--
-- Parameters substituted by handler.py:
--   {goal_id}    UInt32  – target goal ID
--   {half_life}  Float   – time-decay half-life in days (default 7.0)
--
-- start_date = date of the chain's endpoint visit.  Including it in
-- GROUP BY enables time-series breakdowns in downstream visualisations.
--
-- All three metrics are computed in a single pass per model:
--   visits      – 1 per chain  (Conversions/GoalRevenueCur = 0 in
--   conversions – Conversions    non-relevant chains, sum() is safe)
--   revenue     – GoalRevenueCur
--
-- One DROP PARTITION clears all models for this goal at once.
--
-- "Non-significant" TraficSourceIDs (for last_significant model):
--    0 DIRECT    Прямые заходы
--   -1 INTERNAL  Внутренние переходы
--    4 LOCAL     С сохранённых страниц
--    5 UNKNOW    Не определён
--    6 EXTERNAL  По внешним ссылкам
-- Last-significant picks the most-recent touchpoint whose root ID is
-- NOT in that set; if all are non-significant, it falls back to
-- last-touch.  The root ID is parsed from the SourceCode string via
-- splitByChar('_', source_code)[1].
-- ============================================================



-- ============================================================
-- MODEL 1: First Touch
-- 100% credit to history.SourceCode[1] (oldest touchpoint).
-- ============================================================
INSERT INTO attribution_results
    (goal_id, attribution_type, start_date, source_code, visits, conversions, revenue)
SELECT
    goal_id,
    'first_touch'                                       AS attribution_type,
    toDate(`history.UTCStartTime`[-1])                  AS start_date,
    `history.SourceCode`[1]                             AS source_code,
    toFloat64(count())                                  AS visits,
    sum(Conversions)                                    AS conversions,
    sum(GoalRevenueCur)                                 AS revenue
FROM visits_combined
WHERE goal_id = {goal_id}
GROUP BY goal_id, start_date, source_code;


-- ============================================================
-- MODEL 2: Last Touch (+ assisted_conversions / assisted_revenue)
-- 100% credit to history.SourceCode[-1] (endpoint touchpoint).
--
-- Last-touch rows also carry assisted_conversions / assisted_revenue
-- for their source_code.  Assisted = sum of chain.Conversions over
-- converting chains where this source appeared anywhere EXCEPT the
-- last position.  Multiple non-last appearances in the same chain
-- count once (arrayDistinct), matching GA-style semantics.
-- ============================================================
INSERT INTO attribution_results
    (goal_id, attribution_type, start_date, source_code, visits, conversions, revenue,
     assisted_conversions, assisted_revenue)
WITH
    -- Per-source assisted totals, one row per (goal, date, source).
    assisted AS (
        SELECT
            goal_id,
            start_date,
            src                                         AS source_code,
            sum(Conversions)                            AS assisted_conversions,
            sum(GoalRevenueCur)                         AS assisted_revenue
        FROM (
            SELECT
                goal_id,
                toDate(`history.UTCStartTime`[-1])      AS start_date,
                Conversions,
                GoalRevenueCur,
                arrayDistinct(
                    arraySlice(`history.SourceCode`, 1, length(`history.SourceCode`) - 1)
                )                                       AS non_last_sources
            FROM visits_combined
            WHERE goal_id = {goal_id}
              AND length(`history.SourceCode`) > 1
              AND Conversions > 0
        )
        ARRAY JOIN non_last_sources AS src
        GROUP BY goal_id, start_date, source_code
    ),
    -- Last-touch aggregation (the "base" half of the INSERT).
    lt AS (
        SELECT
            goal_id,
            toDate(`history.UTCStartTime`[-1])          AS start_date,
            `history.SourceCode`[-1]                    AS source_code,
            toFloat64(count())                          AS visits,
            sum(Conversions)                            AS conversions,
            sum(GoalRevenueCur)                         AS revenue
        FROM visits_combined
        WHERE goal_id = {goal_id}
        GROUP BY goal_id, start_date, source_code
    )
SELECT
    lt.goal_id,
    'last_touch'                                        AS attribution_type,
    lt.start_date,
    lt.source_code,
    lt.visits,
    lt.conversions,
    lt.revenue,
    coalesce(a.assisted_conversions, 0.0)               AS assisted_conversions,
    coalesce(a.assisted_revenue,     0.0)               AS assisted_revenue
FROM lt
LEFT JOIN assisted AS a
    ON  a.goal_id     = lt.goal_id
    AND a.start_date  = lt.start_date
    AND a.source_code = lt.source_code;


-- ============================================================
-- MODEL 2b: Last Significant
-- 100% credit to the LAST touchpoint whose root TraficSourceID
-- is NOT in (0, -1, 4, 5, 6).  Falls back to last-touch when every
-- touchpoint in the chain is non-significant.
-- ============================================================
INSERT INTO attribution_results
    (goal_id, attribution_type, start_date, source_code, visits, conversions, revenue)
WITH
    non_significant_roots AS (SELECT arrayJoin([-1, 0, 4, 5, 6]) AS r),
    per_chain AS (
        SELECT
            goal_id,
            toDate(`history.UTCStartTime`[-1])                     AS start_date,
            `history.SourceCode`                                   AS src_arr,
            arrayMap(
                s -> toInt16OrNull(splitByChar('_', s)[1]),
                `history.SourceCode`
            )                                                      AS root_ids,
            Conversions,
            GoalRevenueCur
        FROM visits_combined
        WHERE goal_id = {goal_id}
    ),
    picked AS (
        SELECT
            goal_id,
            start_date,
            Conversions,
            GoalRevenueCur,
            -- Last index i where root_ids[i] is significant; 0 if none.
            arrayLast(
                i -> root_ids[i] IS NOT NULL
                     AND root_ids[i] NOT IN (-1, 0, 4, 5, 6),
                arrayEnumerate(src_arr)
            )                                                      AS sig_idx,
            -- Fallback to last index if no significant element.
            length(src_arr)                                        AS last_idx,
            src_arr
        FROM per_chain
    )
SELECT
    goal_id,
    'last_significant'                                             AS attribution_type,
    start_date,
    if(sig_idx > 0, src_arr[sig_idx], src_arr[last_idx])           AS source_code,
    toFloat64(count())                                             AS visits,
    sum(Conversions)                                               AS conversions,
    sum(GoalRevenueCur)                                            AS revenue
FROM picked
GROUP BY goal_id, start_date, source_code;


-- ============================================================
-- MODEL 3: Linear
-- Each touchpoint receives chain_val / chain_length credit.
-- ============================================================
INSERT INTO attribution_results
    (goal_id, attribution_type, start_date, source_code, visits, conversions, revenue)
SELECT
    goal_id,
    'linear'                                            AS attribution_type,
    start_date,
    src                                                 AS source_code,
    sum(1.0         / chain_len)                        AS visits,
    sum(Conversions / chain_len)                        AS conversions,
    sum(GoalRevenueCur / chain_len)                     AS revenue
FROM
(
    SELECT
        goal_id,
        toDate(`history.UTCStartTime`[-1])              AS start_date,
        toUInt32(length(`history.SourceCode`))          AS chain_len,
        Conversions,
        GoalRevenueCur,
        `history.SourceCode`                            AS src_arr
    FROM visits_combined
    WHERE goal_id = {goal_id}
)
ARRAY JOIN src_arr AS src
GROUP BY goal_id, start_date, source_code;


-- ============================================================
-- MODEL 4: Time Decay
-- Weight per touchpoint: 2^(-days_before_endpoint / half_life),
-- normalised per chain, then multiplied by each metric's value.
-- ============================================================
INSERT INTO attribution_results
    (goal_id, attribution_type, start_date, source_code, visits, conversions, revenue)
SELECT
    goal_id,
    'time_decay'                                        AS attribution_type,
    start_date,
    src                                                 AS source_code,
    sum(w / total_w)                                    AS visits,
    sum(w / total_w * Conversions)                      AS conversions,
    sum(w / total_w * GoalRevenueCur)                   AS revenue
FROM
(
    SELECT
        goal_id, start_date, Conversions, GoalRevenueCur,
        src_arr, raw_weights,
        arraySum(raw_weights)                           AS total_w
    FROM
    (
        SELECT
            goal_id,
            toDate(`history.UTCStartTime`[-1])          AS start_date,
            Conversions,
            GoalRevenueCur,
            `history.SourceCode`                        AS src_arr,
            arrayMap(
                t -> pow(2.0,
                    -(  toFloat64(toUnixTimestamp(`history.UTCStartTime`[-1]))
                      - toFloat64(toUnixTimestamp(t))
                    ) / 86400.0 / toFloat64({half_life})
                ),
                `history.UTCStartTime`
            )                                           AS raw_weights
        FROM visits_combined
        WHERE goal_id = {goal_id}
    )
)
ARRAY JOIN src_arr AS src, raw_weights AS w
GROUP BY goal_id, start_date, source_code;


-- ============================================================
-- TRANSITION MATRIX
-- One row per (goal, date, prev_source, next_source) collected
-- from consecutive-pair positions in each chain of length ≥ 2.
--
--   transitions        – chain-count weight (every chain containing
--                        the pair contributes 1)
--   converting_chains  – sum of chain.Conversions over chains that
--                        contained the pair; = transitions-weighted
--                        count of conversions that flowed through
--                        this prev→next edge.
-- ============================================================
INSERT INTO source_transitions
    (goal_id, start_date, prev_source_code, next_source_code, transitions, converting_chains)
SELECT
    goal_id,
    start_date,
    pair.1                                              AS prev_source_code,
    pair.2                                              AS next_source_code,
    toFloat64(count())                                  AS transitions,
    sum(Conversions)                                    AS converting_chains
FROM (
    SELECT
        goal_id,
        toDate(`history.UTCStartTime`[-1])              AS start_date,
        Conversions,
        arrayZip(
            arraySlice(`history.SourceCode`, 1, length(`history.SourceCode`) - 1),
            arraySlice(`history.SourceCode`, 2)
        )                                               AS pairs
    FROM visits_combined
    WHERE goal_id = {goal_id}
      AND length(`history.SourceCode`) > 1
)
ARRAY JOIN pairs AS pair
GROUP BY goal_id, start_date, prev_source_code, next_source_code;
