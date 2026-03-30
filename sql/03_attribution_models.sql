-- ============================================================
-- ATTRIBUTION MODELS
-- ============================================================
-- Computes weighted conversion credit for each channel using
-- four attribution models against the sessions_chains table.
-- Run AFTER 02_build_chains.sql has completed for this goal_id.
--
-- Parameters substituted by handler.py before execution:
--   {goal_id}    UInt32  – target goal ID (must match chains)
--   {half_life}  Float   – time-decay half-life in days (default 7.0)
--
-- Each model drops its previous data for goal_id (by partition)
-- before inserting fresh results.
-- ============================================================


-- ============================================================
-- MODEL 1: First Touch
-- 100% of conversion credit goes to the FIRST touchpoint
-- (position = 1, i.e. the oldest visit in the chain).
-- Favours awareness / discovery channels.
-- ============================================================
ALTER TABLE attribution_first_touch DROP PARTITION {goal_id};

INSERT INTO attribution_first_touch (goal_id, channel, conversions)
SELECT
    goal_id,
    channel,
    toFloat64(count())      AS conversions
FROM sessions_chains FINAL
WHERE goal_id = {goal_id}
  AND position = 1
GROUP BY goal_id, channel;


-- ============================================================
-- MODEL 2: Last Touch
-- 100% of conversion credit goes to the LAST touchpoint
-- (is_converting = 1, i.e. the visit that triggered the goal).
-- Favours closing / retargeting channels.
-- ============================================================
ALTER TABLE attribution_last_touch DROP PARTITION {goal_id};

INSERT INTO attribution_last_touch (goal_id, channel, conversions)
SELECT
    goal_id,
    channel,
    toFloat64(count())      AS conversions
FROM sessions_chains FINAL
WHERE goal_id = {goal_id}
  AND is_converting = 1
GROUP BY goal_id, channel;


-- ============================================================
-- MODEL 3: Linear
-- Conversion credit distributed equally across ALL touchpoints.
-- Each touchpoint receives 1 / chain_length of the conversion.
-- Treats every channel as equally important.
-- ============================================================
ALTER TABLE attribution_linear DROP PARTITION {goal_id};

INSERT INTO attribution_linear (goal_id, channel, conversions)
SELECT
    goal_id,
    channel,
    sum(1.0 / chain_length) AS conversions
FROM sessions_chains FINAL
WHERE goal_id = {goal_id}
GROUP BY goal_id, channel;


-- ============================================================
-- MODEL 4: Time Decay
-- Touchpoints closer to the conversion receive exponentially
-- more credit.  Raw weight for each touchpoint:
--
--   w_i = 2 ^ ( -days_before_conv_i / half_life )
--
-- Weights are normalised within each chain so they sum to 1,
-- then summed across all chains per channel.
--
-- half_life = 7 days means a touchpoint 7 days before conversion
-- receives half the weight of one that happens on the same day.
-- ============================================================
ALTER TABLE attribution_time_decay DROP PARTITION {goal_id};

INSERT INTO attribution_time_decay (goal_id, channel, conversions)
WITH weighted AS (
    SELECT
        goal_id,
        chain_id,
        channel,
        -- raw exponential weight
        pow(2.0, -days_before_conv / {half_life})                    AS raw_weight,
        -- denominator: sum of raw weights for the whole chain
        sum(pow(2.0, -days_before_conv / {half_life}))
            OVER (PARTITION BY chain_id)                             AS chain_weight_sum
    FROM sessions_chains FINAL
    WHERE goal_id = {goal_id}
)
SELECT
    goal_id,
    channel,
    -- normalised weight: each chain contributes exactly 1 conversion
    sum(raw_weight / chain_weight_sum)  AS conversions
FROM weighted
GROUP BY goal_id, channel;
