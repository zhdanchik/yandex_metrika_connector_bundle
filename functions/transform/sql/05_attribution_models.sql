-- ============================================================
-- STEP 3: ATTRIBUTION MODELS
-- ============================================================
-- Computes attribution credit per source_code across four models
-- and three metrics.  Reads visits_combined directly.
--
-- Parameters substituted by handler.py:
--   {goal_id}    UInt32  – target goal ID
--   {half_life}  Float   – time-decay half-life in days (default 7.0)
--
-- metric_type values and their filter / value:
--   'visits'      – all chains,                 value = 1 per chain
--   'conversions' – WHERE Conversions > 0,       value = Conversions
--   'revenue'     – WHERE GoalRevenueCur > 0,    value = GoalRevenueCur
--
-- One DROP PARTITION clears all models and metrics for this goal.
-- ============================================================

ALTER TABLE attribution_results DROP PARTITION {goal_id};


-- ============================================================
-- MODEL 1: First Touch
-- 100% credit to history.SourceCode[1] (oldest touchpoint).
-- ============================================================
INSERT INTO attribution_results (goal_id, attribution_type, metric_type, source_code, value)
SELECT goal_id, 'first_touch', 'visits',      `history.SourceCode`[1], toFloat64(count())
FROM visits_combined WHERE goal_id = {goal_id}
GROUP BY goal_id, source_code
UNION ALL
SELECT goal_id, 'first_touch', 'conversions', `history.SourceCode`[1], sum(Conversions)
FROM visits_combined WHERE goal_id = {goal_id} AND Conversions > 0
GROUP BY goal_id, source_code
UNION ALL
SELECT goal_id, 'first_touch', 'revenue',     `history.SourceCode`[1], sum(GoalRevenueCur)
FROM visits_combined WHERE goal_id = {goal_id} AND GoalRevenueCur > 0
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 2: Last Touch
-- 100% credit to history.SourceCode[-1] (last touchpoint).
-- ============================================================
INSERT INTO attribution_results (goal_id, attribution_type, metric_type, source_code, value)
SELECT goal_id, 'last_touch', 'visits',      `history.SourceCode`[-1], toFloat64(count())
FROM visits_combined WHERE goal_id = {goal_id}
GROUP BY goal_id, source_code
UNION ALL
SELECT goal_id, 'last_touch', 'conversions', `history.SourceCode`[-1], sum(Conversions)
FROM visits_combined WHERE goal_id = {goal_id} AND Conversions > 0
GROUP BY goal_id, source_code
UNION ALL
SELECT goal_id, 'last_touch', 'revenue',     `history.SourceCode`[-1], sum(GoalRevenueCur)
FROM visits_combined WHERE goal_id = {goal_id} AND GoalRevenueCur > 0
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 3: Linear
-- Credit distributed equally (chain_val / chain_length) per touchpoint.
-- ============================================================
INSERT INTO attribution_results (goal_id, attribution_type, metric_type, source_code, value)
SELECT goal_id, 'linear', metric_type, src AS source_code, sum(chain_val / chain_len) AS value
FROM
(
    SELECT goal_id, 'visits'      AS metric_type, toFloat64(1)    AS chain_val, toUInt32(length(`history.SourceCode`)) AS chain_len, `history.SourceCode` AS src_arr FROM visits_combined WHERE goal_id = {goal_id}
    UNION ALL
    SELECT goal_id, 'conversions'             , Conversions                                                            , toUInt32(length(`history.SourceCode`))        , `history.SourceCode`              FROM visits_combined WHERE goal_id = {goal_id} AND Conversions    > 0
    UNION ALL
    SELECT goal_id, 'revenue'                 , GoalRevenueCur                                                         , toUInt32(length(`history.SourceCode`))        , `history.SourceCode`              FROM visits_combined WHERE goal_id = {goal_id} AND GoalRevenueCur > 0
)
ARRAY JOIN src_arr AS src
GROUP BY goal_id, metric_type, source_code;


-- ============================================================
-- MODEL 4: Time Decay
-- Weight per touchpoint: 2^(-days_before_conv / half_life),
-- normalised per chain, then multiplied by chain_val.
-- ============================================================
INSERT INTO attribution_results (goal_id, attribution_type, metric_type, source_code, value)
SELECT goal_id, 'time_decay', metric_type, src AS source_code, sum(w / total_w * chain_val) AS value
FROM
(
    SELECT goal_id, metric_type, chain_val, src_arr, raw_weights, arraySum(raw_weights) AS total_w
    FROM
    (
        SELECT goal_id, 'visits'      AS metric_type, toFloat64(1)    AS chain_val, `history.SourceCode` AS src_arr,
               arrayMap(t -> pow(2.0, -(toFloat64(toUnixTimestamp(`history.UTCStartTime`[-1])) - toFloat64(toUnixTimestamp(t))) / 86400.0 / toFloat64({half_life})), `history.UTCStartTime`) AS raw_weights
        FROM visits_combined WHERE goal_id = {goal_id}
        UNION ALL
        SELECT goal_id, 'conversions'             , Conversions      , `history.SourceCode`,
               arrayMap(t -> pow(2.0, -(toFloat64(toUnixTimestamp(`history.UTCStartTime`[-1])) - toFloat64(toUnixTimestamp(t))) / 86400.0 / toFloat64({half_life})), `history.UTCStartTime`)
        FROM visits_combined WHERE goal_id = {goal_id} AND Conversions    > 0
        UNION ALL
        SELECT goal_id, 'revenue'                 , GoalRevenueCur   , `history.SourceCode`,
               arrayMap(t -> pow(2.0, -(toFloat64(toUnixTimestamp(`history.UTCStartTime`[-1])) - toFloat64(toUnixTimestamp(t))) / 86400.0 / toFloat64({half_life})), `history.UTCStartTime`)
        FROM visits_combined WHERE goal_id = {goal_id} AND GoalRevenueCur > 0
    )
)
ARRAY JOIN src_arr AS src, raw_weights AS w
GROUP BY goal_id, metric_type, source_code;
