-- ============================================================
-- STEP 3: ATTRIBUTION MODELS
-- ============================================================
-- Computes weighted conversion credit per source_code using four
-- attribution models.  Reads visits_combined directly.
-- Results go into a single attribution_results table partitioned
-- by goal_id; attribution_type distinguishes the models.
--
-- Parameters substituted by handler.py before execution:
--   {goal_id}    UInt32  – target goal ID
--   {half_life}  Float   – time-decay half-life in days (default 7.0)
--
-- Only converting chains are counted: WHERE Conversions > 0.
-- One DROP PARTITION clears all models for this goal at once.
-- ============================================================

ALTER TABLE attribution_results DROP PARTITION {goal_id};


-- ============================================================
-- MODEL 1: First Touch
-- 100% credit to history.SourceCode[1] (oldest touchpoint).
-- ============================================================
INSERT INTO attribution_results (goal_id, attribution_type, source_code, conversions)
SELECT
    goal_id,
    'first_touch'                AS attribution_type,
    `history.SourceCode`[1]      AS source_code,
    toFloat64(count())           AS conversions
FROM visits_combined
WHERE goal_id = {goal_id}
  AND Conversions > 0
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 2: Last Touch
-- 100% credit to history.SourceCode[-1] (converting touchpoint).
-- ============================================================
INSERT INTO attribution_results (goal_id, attribution_type, source_code, conversions)
SELECT
    goal_id,
    'last_touch'                 AS attribution_type,
    `history.SourceCode`[-1]     AS source_code,
    toFloat64(count())           AS conversions
FROM visits_combined
WHERE goal_id = {goal_id}
  AND Conversions > 0
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 3: Linear
-- Equal credit (1 / chain_length) to every touchpoint.
-- ============================================================
INSERT INTO attribution_results (goal_id, attribution_type, source_code, conversions)
SELECT
    goal_id,
    'linear'                     AS attribution_type,
    src                          AS source_code,
    sum(1.0 / chain_len)         AS conversions
FROM
(
    SELECT
        goal_id,
        toUInt32(length(`history.SourceCode`))  AS chain_len,
        `history.SourceCode`                    AS src_arr
    FROM visits_combined
    WHERE goal_id = {goal_id}
      AND Conversions > 0
)
ARRAY JOIN src_arr AS src
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 4: Time Decay
-- Weight per touchpoint: 2 ^ (-days_before_conv / half_life).
-- Weights normalised within each chain so it contributes exactly
-- 1.0 conversion in aggregate.
-- ============================================================
INSERT INTO attribution_results (goal_id, attribution_type, source_code, conversions)
SELECT
    goal_id,
    'time_decay'                 AS attribution_type,
    src                          AS source_code,
    sum(w / total_w)             AS conversions
FROM
(
    SELECT
        goal_id,
        `history.SourceCode`     AS src_arr,
        raw_weights,
        arraySum(raw_weights)    AS total_w
    FROM
    (
        SELECT
            goal_id,
            `history.SourceCode` AS src_arr,
            arrayMap(
                t -> pow(2.0,
                    -(toFloat64(toUnixTimestamp(`history.UTCStartTime`[-1]))
                      - toFloat64(toUnixTimestamp(t)))
                    / 86400.0 / toFloat64({half_life})
                ),
                `history.UTCStartTime`
            )                    AS raw_weights
        FROM visits_combined
        WHERE goal_id = {goal_id}
          AND Conversions > 0
    )
)
ARRAY JOIN src_arr AS src, raw_weights AS w
GROUP BY goal_id, source_code;
