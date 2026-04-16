-- ============================================================
-- STEP 3: ATTRIBUTION MODELS
-- ============================================================
-- Computes attribution credit per (source_code, start_date) across
-- four models.  Reads visits_combined directly.
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
-- MODEL 2: Last Touch
-- 100% credit to history.SourceCode[-1] (endpoint touchpoint).
-- ============================================================
INSERT INTO attribution_results
    (goal_id, attribution_type, start_date, source_code, visits, conversions, revenue)
SELECT
    goal_id,
    'last_touch'                                        AS attribution_type,
    toDate(`history.UTCStartTime`[-1])                  AS start_date,
    `history.SourceCode`[-1]                            AS source_code,
    toFloat64(count())                                  AS visits,
    sum(Conversions)                                    AS conversions,
    sum(GoalRevenueCur)                                 AS revenue
FROM visits_combined
WHERE goal_id = {goal_id}
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
