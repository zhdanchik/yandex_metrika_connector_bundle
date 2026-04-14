-- ============================================================
-- STEP 3: BUILD TOUCHPOINT CHAINS
-- ============================================================
-- Reads visits_combined (produced by 03_combine_visits.sql) and
-- unrolls each user's session chain into one row per touchpoint,
-- populating sessions_chains.
--
-- Parameters substituted by handler.py:
--   {goal_id}  UInt32  – target goal (must match visits_combined partition)
--
-- For each row in visits_combined (one row = one session chain), the
-- history arrays are ARRAY JOINed to yield one row per touchpoint with:
--   position         – 1-based index (oldest = 1, last = chain_length)
--   chain_length     – total touchpoints in this session chain
--   source_code      – SourceCode label for this touchpoint
--   days_before_conv – days between this touchpoint and the last visit
--   is_converting    – 1 if this touchpoint IS the converting visit
--                      (= last in chain AND Conversions > 0)
--
-- chains without any converting touchpoint (is_converting = 0 for all
-- positions) are stored but excluded by the attribution models.
--
-- chain_id is '{user_id}_{last_visit_id}'.
-- ============================================================

ALTER TABLE sessions_chains DROP PARTITION {goal_id};

INSERT INTO sessions_chains
    (goal_id, chain_id, user_id, conversion_time, touchpoint_time,
     position, chain_length, source_code, days_before_conv, is_converting)

SELECT
    goal_id,
    chain_id,
    UserID                                                              AS user_id,
    last_time                                                           AS conversion_time,
    tp_time                                                             AS touchpoint_time,
    tp_pos                                                              AS position,
    chain_len                                                           AS chain_length,
    tp_source                                                           AS source_code,
    toFloat64(dateDiff('second', tp_time, last_time)) / 86400.0        AS days_before_conv,
    -- A touchpoint is "converting" only if it is the last in the chain
    -- AND its own Conversions value is > 0.
    if(tp_pos = chain_len AND tp_conversions > 0,
        toUInt8(1), toUInt8(0))                                        AS is_converting
FROM
(
    -- Pre-compute scalar derivations from arrays before the ARRAY JOIN
    -- so they remain accessible as repeated scalars on each joined row.
    SELECT
        goal_id,
        UserID,
        concat(
            toString(UserID), '_',
            toString(`history.VisitID`[-1])
        )                                                               AS chain_id,
        `history.UTCStartTime`[-1]                                      AS last_time,
        toUInt32(length(`history.SourceCode`))                          AS chain_len,
        `history.SourceCode`                                            AS tp_source,
        `history.UTCStartTime`                                          AS tp_time,
        `history.Conversions`                                           AS tp_conversions,
        arrayEnumerate(`history.SourceCode`)                            AS tp_pos
    FROM visits_combined FINAL
    WHERE goal_id = {goal_id}
)
ARRAY JOIN tp_source, tp_time, tp_conversions, tp_pos;
