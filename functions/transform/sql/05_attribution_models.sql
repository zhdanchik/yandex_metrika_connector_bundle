-- ============================================================
-- STEP 3: ATTRIBUTION MODELS
-- ============================================================
-- Computes weighted conversion credit per source_code using four
-- attribution models.  Reads visits_combined directly — no
-- intermediate row-per-touchpoint table is required.
--
-- Parameters substituted by handler.py before execution:
--   {goal_id}    UInt32  – target goal ID
--   {half_life}  Float   – time-decay half-life in days (default 7.0)
--
-- Only converting chains are counted: WHERE Conversions > 0
-- (Conversions is the scalar = history.Conversions[-1]).
--
-- Each model drops its previous data for goal_id (by partition)
-- before inserting fresh results, making the pipeline idempotent.
-- ============================================================


-- ============================================================
-- MODEL 1: First Touch
-- 100% credit to history.SourceCode[1] (oldest touchpoint).
-- ============================================================
ALTER TABLE attribution_first_touch DROP PARTITION {goal_id};

INSERT INTO attribution_first_touch (goal_id, source_code, conversions)
SELECT
    goal_id,
    `history.SourceCode`[1]      AS source_code,
    toFloat64(count())           AS conversions
FROM visits_combined FINAL
WHERE goal_id = {goal_id}
  AND Conversions > 0
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 2: Last Touch
-- 100% credit to history.SourceCode[-1] (converting touchpoint).
-- ============================================================
ALTER TABLE attribution_last_touch DROP PARTITION {goal_id};

INSERT INTO attribution_last_touch (goal_id, source_code, conversions)
SELECT
    goal_id,
    `history.SourceCode`[-1]     AS source_code,
    toFloat64(count())           AS conversions
FROM visits_combined FINAL
WHERE goal_id = {goal_id}
  AND Conversions > 0
GROUP BY goal_id, source_code;


-- ============================================================
-- MODEL 3: Linear
-- Equal credit (1 / chain_length) to every touchpoint.
-- Uses ARRAY JOIN to expand the SourceCode array per chain.
-- ============================================================
ALTER TABLE attribution_linear DROP PARTITION {goal_id};

INSERT INTO attribution_linear (goal_id, source_code, conversions)
SELECT
    goal_id,
    src                          AS source_code,
    sum(1.0 / chain_len)         AS conversions
FROM
(
    SELECT
        goal_id,
        toUInt32(length(`history.SourceCode`))  AS chain_len,
        `history.SourceCode`                    AS src_arr
    FROM visits_combined FINAL
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
--
-- days_before_conv_i = (UTCStartTime[-1] - UTCStartTime[i]) / 86400
-- ============================================================
ALTER TABLE attribution_time_decay DROP PARTITION {goal_id};

INSERT INTO attribution_time_decay (goal_id, source_code, conversions)
SELECT
    goal_id,
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
        FROM visits_combined FINAL
        WHERE goal_id = {goal_id}
          AND Conversions > 0
    )
)
ARRAY JOIN src_arr AS src, raw_weights AS w
GROUP BY goal_id, source_code;
