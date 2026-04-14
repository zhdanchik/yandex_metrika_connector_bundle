-- ============================================================
-- STEP 4: ATTRIBUTION MODELS
-- ============================================================
-- Computes weighted conversion credit per source_code using four
-- attribution models against sessions_chains.
-- Run AFTER 04_build_chains.sql has completed for this goal_id.
--
-- Parameters substituted by handler.py before execution:
--   {goal_id}    UInt32  – target goal ID (must match chains)
--   {half_life}  Float   – time-decay half-life in days (default 7.0)
--
-- Each model drops its previous data for goal_id (by partition)
-- before inserting fresh results, making the pipeline idempotent.
-- ============================================================


-- ============================================================
-- MODEL 1: First Touch
-- 100% credit to the FIRST touchpoint (position = 1).
-- Favours discovery / awareness channels.
-- ============================================================
ALTER TABLE attribution_first_touch DROP PARTITION {goal_id};

INSERT INTO attribution_first_touch (goal_id, source_code, conversions)
SELECT
    goal_id,
    source_code,
    toFloat64(count())  AS conversions
FROM sessions_chains FINAL
WHERE goal_id = {goal_id}
  AND position = 1
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 2: Last Touch
-- 100% credit to the LAST (converting) touchpoint (is_converting = 1).
-- Favours retargeting / closing channels.
-- ============================================================
ALTER TABLE attribution_last_touch DROP PARTITION {goal_id};

INSERT INTO attribution_last_touch (goal_id, source_code, conversions)
SELECT
    goal_id,
    source_code,
    toFloat64(count())  AS conversions
FROM sessions_chains FINAL
WHERE goal_id = {goal_id}
  AND is_converting = 1
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 3: Linear
-- Credit distributed equally across all touchpoints.
-- Each touchpoint receives 1 / chain_length of the conversion.
-- ============================================================
ALTER TABLE attribution_linear DROP PARTITION {goal_id};

INSERT INTO attribution_linear (goal_id, source_code, conversions)
SELECT
    goal_id,
    source_code,
    sum(1.0 / chain_length) AS conversions
FROM sessions_chains FINAL
WHERE goal_id = {goal_id}
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 4: Time Decay
-- Touchpoints closer to conversion receive exponentially more
-- credit.  Raw weight per touchpoint:
--
--   w_i = 2 ^ ( -days_before_conv_i / half_life )
--
-- Weights are normalised within each chain (sum = 1), then summed
-- across all chains per source_code.
--
-- Default half_life = 7 days: a touchpoint from 7 days before
-- conversion gets half the weight of one on the day of conversion.
-- ============================================================
ALTER TABLE attribution_time_decay DROP PARTITION {goal_id};

INSERT INTO attribution_time_decay (goal_id, source_code, conversions)
WITH weighted AS (
    SELECT
        goal_id,
        chain_id,
        source_code,
        pow(2.0, -days_before_conv / {half_life})                    AS raw_weight,
        sum(pow(2.0, -days_before_conv / {half_life}))
            OVER (PARTITION BY chain_id)                             AS chain_weight_sum
    FROM sessions_chains FINAL
    WHERE goal_id = {goal_id}
)
SELECT
    goal_id,
    source_code,
    sum(raw_weight / chain_weight_sum)  AS conversions
FROM weighted
GROUP BY goal_id, source_code;
