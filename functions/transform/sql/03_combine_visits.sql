-- ============================================================
-- STEP 2: COMBINE VISITS — SESSION DETECTION
-- ============================================================
-- Reads visits_prepared and builds user-level chain arrays using
-- NULL-sentinel session detection.
--
-- Exactly mirrors metr_combine_insert_final_query from
-- analyse_channels_chain.py.
--
-- Parameters substituted by handler.py:
--   {goal_id}            UInt32  – target goal
--   {visit_max_timediff} UInt64  – session timeout in SECONDS
--                                  (95th percentile of inter-visit gaps,
--                                   computed by handler.py via
--                                   visit_diff_percentile_q)
--
-- Algorithm (identical to original):
--   1. Create '2_VISIT' events for each real visit.
--   2. Find consecutive visit pairs where gap > visit_max_timediff;
--      insert a '0_NULL' sentinel timed at gap_start + visit_max_timediff.
--   3. Insert a final '0_NULL' sentinel at max(UTCStartTime)+visit_max_timediff
--      for every user (closes the last session).
--   4. Sort all events by (UTCStartTime, EventType) — '0_NULL' < '2_VISIT'
--      so sentinels precede same-timestamp visits.
--   5. For each user, for each position i, find the last sentinel at
--      index < i → that is the session boundary.
--   6. Slice the event arrays from (boundary+1) to i → this is the chain.
--   7. Keep only rows where the chain's last element has Conversions > 0
--      (i.e. the visit at position i is a converting visit).
--
-- Note on scalability: the original Python code iterates over user
-- chunks (iter_sample) for memory efficiency. This SQL version processes
-- all users in a single pass. For very large counters (>10M visits/day)
-- consider chunking the INSERT in handler.py.
-- ============================================================

ALTER TABLE visits_combined DROP PARTITION {goal_id};

INSERT INTO visits_combined
    (goal_id, CounterID, UserID,
     `history.VisitID`, `history.SourceCode`, `history.UTCStartTime`,
     `history.EventType`, `history.Conversions`,
     Conversions)

SELECT
    toUInt32({goal_id})                                AS goal_id,
    CounterID,
    UserID,
    `history.VisitID`,
    `history.SourceCode`,
    `history.UTCStartTime`,
    `history.EventType`,
    `history.Conversions`,
    toFloat64(`history.Conversions`[-1])               AS Conversions
FROM
(
    -- --------------------------------------------------------
    -- For each user × position i: slice arrays from the last
    -- NULL sentinel before i up to position i.
    -- --------------------------------------------------------
    SELECT
        CounterID,
        UserID,
        -- Index of the last NULL sentinel strictly before position i.
        -- arrayFilter returns a subset of the index array [1..N];
        -- [-1] gives the last matching element, or 0 if none found
        -- (meaning the chain starts from the beginning of the array).
        arrayFilter(
            (x, src) -> src = 'null' AND x < i,
            arrayEnumerate(history_SourceCode),
            history_SourceCode
        )[-1]                                          AS indx,

        arraySlice(history_VisitID,
            toInt64(indx) + 1,
            toInt64(i) - toInt64(indx))                AS `history.VisitID`,

        arraySlice(history_SourceCode,
            toInt64(indx) + 1,
            toInt64(i) - toInt64(indx))                AS `history.SourceCode`,

        arraySlice(history_UTCStartTime,
            toInt64(indx) + 1,
            toInt64(i) - toInt64(indx))                AS `history.UTCStartTime`,

        arraySlice(history_EventType,
            toInt64(indx) + 1,
            toInt64(i) - toInt64(indx))                AS `history.EventType`,

        arraySlice(history_Conversions,
            toInt64(indx) + 1,
            toInt64(i) - toInt64(indx))                AS `history.Conversions`

    FROM
    (
        -- --------------------------------------------------------
        -- Aggregate all events (visits + sentinels) per user
        -- into sorted arrays.
        -- --------------------------------------------------------
        SELECT
            CounterID,
            UserID,
            arrayMap(t -> t.1,  sorted_events)         AS history_UTCStartTime,
            arrayMap(t -> t.2,  sorted_events)         AS history_VisitID,
            arrayMap(t -> t.3,  sorted_events)         AS history_SourceCode,
            arrayMap(t -> t.4,  sorted_events)         AS history_EventType,
            arrayMap(t -> t.5,  sorted_events)         AS history_Conversions,
            arrayEnumerate(sorted_events)              AS cnt
        FROM
        (
            SELECT
                CounterID,
                UserID,
                -- Sort by (UTCStartTime, EventType):
                -- '0_NULL' < '2_VISIT' alphabetically, so sentinels
                -- naturally precede same-timestamp real visits.
                arraySort(
                    t -> (t.1, t.4),
                    groupArray((
                        UTCStartTime,
                        VisitID,
                        SourceCode,
                        EventType,
                        toFloat64(Conversions)
                    ))
                )                                      AS sorted_events
            FROM
            (
                -- ------------------------------------------------
                -- Stream 1: real visits
                -- ------------------------------------------------
                SELECT
                    CounterID, UTCStartTime, UserID, VisitID,
                    SourceCode,
                    '2_VISIT'           AS EventType,
                    Conversions
                FROM visits_prepared

                UNION ALL

                -- ------------------------------------------------
                -- Stream 2: NULL sentinels at session gaps.
                -- For each pair of consecutive visits where the
                -- UTCStartTime gap > visit_max_timediff seconds,
                -- insert a sentinel at (earlier_visit + timeout).
                -- ------------------------------------------------
                SELECT
                    CounterID,
                    utc_time + toUInt64({visit_max_timediff})   AS UTCStartTime,
                    UserID,
                    toUInt64(0)         AS VisitID,
                    'null'              AS SourceCode,
                    '0_NULL'            AS EventType,
                    toUInt32(0)         AS Conversions
                FROM
                (
                    SELECT
                        CounterID,
                        UserID,
                        arraySort(groupArray(UTCStartTime))      AS utc_times,
                        arrayEnumerate(utc_times)                AS indexes,
                        -- Gaps between consecutive visits (seconds)
                        arraySlice(
                            arrayMap(
                                y -> if(y = 1,
                                    toUInt64(0),
                                    toUInt64(utc_times[y]) - toUInt64(utc_times[y - 1])
                                ),
                                indexes
                            ),
                            2   -- skip the first element (always 0)
                        )                                        AS diffs,
                        -- The earlier visit's timestamp for each gap
                        arraySlice(
                            arrayMap(y -> utc_times[y - 1], indexes),
                            2
                        )                                        AS cut_utc_times
                    FROM visits_prepared
                    GROUP BY CounterID, UserID
                    HAVING length(utc_times) > 1
                )
                ARRAY JOIN diffs AS diff, cut_utc_times AS utc_time
                WHERE diff > {visit_max_timediff}

                UNION ALL

                -- ------------------------------------------------
                -- Stream 3: final NULL sentinel at the end of each
                -- user's history (closes the last open session).
                -- ------------------------------------------------
                SELECT
                    CounterID,
                    max(UTCStartTime) + toUInt64({visit_max_timediff})  AS UTCStartTime,
                    UserID,
                    toUInt64(0)         AS VisitID,
                    'null'              AS SourceCode,
                    '0_NULL'            AS EventType,
                    toUInt32(0)         AS Conversions
                FROM visits_prepared
                GROUP BY CounterID, UserID
            )
            GROUP BY CounterID, UserID
        )
    )
    -- Unroll: one row per (user, position i)
    ARRAY JOIN cnt AS i
)
-- All session chains are stored regardless of whether they convert.
-- Conversion filtering happens downstream in 05_attribution_models.sql.
-- Rows whose last element is a NULL sentinel (SourceCode = 'null') are
-- excluded — they are session-boundary markers, not real touchpoints.
WHERE `history.SourceCode`[-1] != 'null';
