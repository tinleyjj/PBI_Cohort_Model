-- ==================================================
-- RPT-008-OC: outcomes_OC.csv
-- Open Career program cohort outcomes
-- Grain: one row per student per OC major_code per
--        first non-summer enrolled term under that
--        major declaration in SORLCUR.
-- Output: outcomes_OC.csv via Argos SFTP
-- Refresh cadence: Per term (full rebuild)
--
-- Cohort membership:
--   New/Transfer students (stu_type != C): standard entry
--   Continuing students (stu_type = C): admitted only when
--     they have a confirmed prior OC major (SORLCUR inactive)
--     that differs from the current program — Option 3 logic.
-- cohort_id: student_id-OC-major_code-YYYYTT
--
-- program_entry_type:
--   NEW            = first-time or transfer entry
--   PROGRAM_SWITCH = continuing student from prior OC major
--
-- Two time clocks:
--   cohort_entry_term_id    = first non-summer term in this
--                             program (program clock)
--   inst_entry_term_id      = first non-summer degree-seeking
--                             term at RSCC (institutional clock)
--   time_to_award_terms     = award relative to program clock
--   inst_time_to_award_terms= award relative to inst clock
--
-- Major validation window: 4th non-summer term at RSCC.
--   Late/missing declarations flagged, not excluded.
-- Column order matches master union schema (CLOSED reference).
-- ==================================================

WITH
term_dim AS (
    SELECT
        t.STVTERM_CODE                              AS term_id,
        ROW_NUMBER() OVER (ORDER BY t.STVTERM_CODE) AS term_sequence,
        b.SOBPTRM_START_DATE                        AS term_start_date,
        b.SOBPTRM_END_DATE                          AS term_end_date
    FROM STVTERM t
    LEFT JOIN SOBPTRM b
        ON  b.SOBPTRM_TERM_CODE = t.STVTERM_CODE
        AND b.SOBPTRM_PTRM_CODE = '1'
    WHERE SUBSTR(t.STVTERM_CODE, 5, 2) IN ('10','50','80')
),
max_term AS (
    SELECT MAX(term_sequence) AS max_seq FROM term_dim
),
current_fs_term AS (
    SELECT MAX(STVTERM_CODE) AS fs_term_id
    FROM STVTERM
    WHERE STVTERM_CODE <= F_RSCC_GET_TERM('TERM1')
    AND   SUBSTR(STVTERM_CODE, 5, 2) IN ('10','80')
),
oc_major_codes AS (
    SELECT 'BUSN' AS major_code FROM DUAL UNION ALL
    SELECT 'BMT'               FROM DUAL UNION ALL
    SELECT 'CET'               FROM DUAL UNION ALL
    SELECT 'CITC'              FROM DUAL UNION ALL
    SELECT 'CMGT'              FROM DUAL UNION ALL
    SELECT 'CRJT'              FROM DUAL UNION ALL
    SELECT 'ECED'              FROM DUAL UNION ALL
    SELECT 'ENVH'              FROM DUAL UNION ALL
    SELECT 'FINC'              FROM DUAL UNION ALL
    SELECT 'GIS'               FROM DUAL UNION ALL
    SELECT 'HIMT'              FROM DUAL UNION ALL
    SELECT 'HEAS'              FROM DUAL UNION ALL
    SELECT 'LEGL'              FROM DUAL UNION ALL
    SELECT 'MECT'              FROM DUAL UNION ALL
    SELECT 'MINF'              FROM DUAL UNION ALL
    SELECT 'NUKE'              FROM DUAL UNION ALL
    SELECT 'AOPT'              FROM DUAL UNION ALL
    SELECT 'SLPA'              FROM DUAL UNION ALL
    SELECT 'VECT'              FROM DUAL
),
-- ========================================================
-- OPTIMIZATION 2: Consolidated credit calculations
-- Single pass through SHRTGPA for both prior_cum and
-- credit_milestones (earned_12cr, earned_24cr).
-- Avoids duplicate window function execution.
-- ========================================================
gpa_cumulative AS (
    SELECT
        g.SHRTGPA_PIDM      AS pidm,
        g.SHRTGPA_TERM_CODE AS term_id,
        SUM(g.SHRTGPA_HOURS_EARNED) OVER (
            PARTITION BY g.SHRTGPA_PIDM
            ORDER BY g.SHRTGPA_TERM_CODE
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                   AS cum_earned,
        SUM(g.SHRTGPA_HOURS_EARNED) OVER (
            PARTITION BY g.SHRTGPA_PIDM
            ORDER BY g.SHRTGPA_TERM_CODE
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        )                   AS prior_cum_hrs
    FROM SHRTGPA g
    WHERE g.SHRTGPA_LEVL_CODE    = 'UG'
      AND g.SHRTGPA_GPA_TYPE_IND = 'I'
),
prior_cum AS (
    SELECT pidm, term_id, prior_cum_hrs
    FROM gpa_cumulative
),
-- --------------------------------------------------------
-- Unified major + concentration per student per enrolled term.
-- One row per pidm per TERM_CODE_CONTEXT (SFVRCRS term).
-- Ordering: most recent effective SORLCUR term first, then
-- lowest priority number, then highest sequence — matches
-- proven pattern from existing RSCC queries.
-- Covers both sorlcur_at_term and sorlfos_at_term roles.
-- ========================================================
-- OPTIMIZATION 3: Materialized dedup of major per student/term.
-- Filters to rank=1 early (in subquery) before LEFT JOINs,
-- reducing downstream join cardinality.
-- ========================================================
major_at_term AS (
    SELECT pidm, term_code_context, major_code, concentration_code
    FROM (
        SELECT
            d.SORLCUR_PIDM         AS pidm,
            d.SORLCUR_PROGRAM      AS major_code,
            lf.SORLFOS_MAJR_CODE   AS concentration_code,
            sf.TERM_CODE_A3        AS term_code_context,
            ROW_NUMBER() OVER (
                PARTITION BY d.SORLCUR_PIDM, sf.TERM_CODE_A3
                ORDER BY d.SORLCUR_TERM_CODE  DESC,
                         d.SORLCUR_PRIORITY_NO ASC,
                         d.SORLCUR_SEQNO       DESC
            )                      AS row_1
        FROM SORLCUR d
        JOIN SFVRCRS sf
            ON  sf.PIDM_A3      = d.SORLCUR_PIDM
            AND sf.TOT_CRHRS_A3 > 0
            AND sf.TERM_CODE_A3 >= :Term
            AND sf.TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
        LEFT JOIN SORLFOS lf
            ON  lf.SORLFOS_PIDM      = d.SORLCUR_PIDM
            AND lf.SORLFOS_LCUR_SEQNO = d.SORLCUR_SEQNO
            AND lf.SORLFOS_LFST_CODE = 'CONCENTRATION'
            AND lf.SORLFOS_CSTS_CODE = 'INPROGRESS'
        WHERE d.SORLCUR_LMOD_CODE = 'LEARNER'
          AND d.SORLCUR_CACT_CODE = 'ACTIVE'
          AND d.SORLCUR_TERM_CODE <= sf.TERM_CODE_A3
    )
    WHERE row_1 = 1
),
-- --------------------------------------------------------
-- sorlcur_history: major per pidm per enrolled term —
-- derived from major_at_term for cohort anchor logic.
-- --------------------------------------------------------
sorlcur_history AS (
    SELECT
        pidm,
        major_code,
        term_code_context AS enrolled_term
    FROM major_at_term
),
birth_dates AS (
    SELECT
        SPBPERS_PIDM       AS pidm,
        SPBPERS_BIRTH_DATE AS birth_date
    FROM SPBPERS
),
-- ========================================================
-- OPTIMIZATION 4: Age calculation extracted to CTE.
-- Eliminates 3x repetition of MONTHS_BETWEEN calculation
-- in SELECT clause. Also pre-computes age_group logic.
-- ========================================================
student_ages AS (
    SELECT
        c.pidm,
        c.cohort_id,
        td_e.term_start_date,
        c.birth_date,
        TRUNC(MONTHS_BETWEEN(td_e.term_start_date, c.birth_date) / 12) AS age_at_entry,
        CASE
            WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date, c.birth_date) / 12) < 18  THEN '0-17'
            WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date, c.birth_date) / 12) <= 20 THEN '18-20'
            WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date, c.birth_date) / 12) <= 24 THEN '21-24'
            WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date, c.birth_date) / 12) <= 34 THEN '25-34'
            WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date, c.birth_date) / 12) <= 49 THEN '35-49'
            WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date, c.birth_date) / 12) <= 65 THEN '50-65'
            WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date, c.birth_date) / 12) > 65  THEN '65+'
            ELSE NULL
        END AS age_group
    FROM cohort_temp c
    LEFT JOIN term_dim td_e ON td_e.term_id = c.cohort_entry_term_id
),
-- --------------------------------------------------------
-- 4th non-summer term per student (major validation deadline)
-- --------------------------------------------------------
student_fourth_term AS (
    SELECT pidm, term_id AS fourth_nonsummer_term
    FROM (
        SELECT
            PIDM_A3      AS pidm,
            TERM_CODE_A3 AS term_id,
            ROW_NUMBER() OVER (
                PARTITION BY PIDM_A3
                ORDER BY TERM_CODE_A3
            )            AS rscc_term_seq
        FROM SFVRCRS
        WHERE TOT_CRHRS_A3  > 0
          AND SUBSTR(TERM_CODE_A3, 5, 2) != '50'
          AND TERM_CODE_A3 >= :Term
          AND TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
    )
    WHERE rscc_term_seq = 4
),
-- --------------------------------------------------------
-- Degree-seeking enrollment terms per student.
-- Batch SGBSTDN join — avoids per-row F_GET_SGBSTDN_ROWID
-- calls across all SFVRCRS history.
-- Excludes summers, NDUG, and zero-credit terms.
-- --------------------------------------------------------
degree_seeking_terms AS (
    SELECT
        sf.PIDM_A3      AS pidm,
        sf.TERM_CODE_A3 AS term_id
    FROM SFVRCRS sf
    JOIN SGBSTDN sg
        ON  sg.ROWID = F_GET_SGBSTDN_ROWID(sf.PIDM_A3, sf.TERM_CODE_A3)
    WHERE sf.TOT_CRHRS_A3  > 0
      AND SUBSTR(sf.TERM_CODE_A3, 5, 2) != '50'
      AND sf.TERM_CODE_A3 >= :Term
      AND sf.TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
      AND NVL(sg.SGBSTDN_DEGC_CODE_1, 'X') != 'NDUG'
      AND NVL(sg.SGBSTDN_STYP_CODE, 'X')   != 'C'
          OR (
              NVL(sg.SGBSTDN_STYP_CODE, 'X') = 'C'
          AND NVL(sg.SGBSTDN_DEGC_CODE_1, 'X') != 'NDUG'
          )
),
-- --------------------------------------------------------
-- First degree-seeking non-summer term per student
-- (institutional clock anchor)
-- --------------------------------------------------------
inst_entry_term AS (
    SELECT
        pidm,
        MIN(term_id) AS inst_entry_term_id
    FROM degree_seeking_terms
    GROUP BY pidm
),
-- --------------------------------------------------------
-- Prior OC majors per student: SORLCUR records that are
-- no longer active (CACT_CODE != 'ACTIVE') for an OC major.
-- Used to qualify continuing students for a new OC cohort.
-- --------------------------------------------------------
prior_oc_majors AS (
    SELECT DISTINCT
        d.SORLCUR_PIDM    AS pidm,
        d.SORLCUR_PROGRAM AS prior_major_code
    FROM SORLCUR d
    JOIN oc_major_codes mc
        ON  mc.major_code = d.SORLCUR_PROGRAM
    WHERE d.SORLCUR_LMOD_CODE = 'LEARNER'
      AND d.SORLCUR_CACT_CODE != 'ACTIVE'
),
-- --------------------------------------------------------
-- Cohort anchor: first non-summer enrolled term per student
-- per OC major from deduped sorlcur_history
-- --------------------------------------------------------
oc_first_declared_term AS (
    SELECT
        sh.pidm,
        sh.major_code,
        MIN(sh.enrolled_term) AS first_declared_term
    FROM sorlcur_history sh
    JOIN oc_major_codes mc
        ON  mc.major_code = sh.major_code
    WHERE SUBSTR(sh.enrolled_term, 5, 2) != '50'
    GROUP BY sh.pidm, sh.major_code
),
-- --------------------------------------------------------
-- Major validation window check
-- --------------------------------------------------------
oc_major_validation AS (
    SELECT
        fd.pidm,
        fd.major_code,
        fd.first_declared_term,
        MAX(
            CASE
                WHEN sh.major_code    = fd.major_code
                 AND sh.enrolled_term <= NVL(ft.fourth_nonsummer_term, 'ZZZ')
                THEN 1
                ELSE 0
            END
        )            AS declared_by_window
    FROM oc_first_declared_term fd
    LEFT JOIN student_fourth_term ft ON ft.pidm = fd.pidm
    LEFT JOIN sorlcur_history sh     ON sh.pidm = fd.pidm
    GROUP BY fd.pidm, fd.major_code, fd.first_declared_term
),
-- ========================================================
-- Temp cohort table for student_ages CTE dependency.
-- Note: student_ages CTE references this; in production,
-- both should be combined into single cohort CTE.
-- ========================================================
cohort_temp AS (
    SELECT
        spr.SPRIDEN_ID
            || '-OC-' || mv.major_code
            || '-'    || mv.first_declared_term       AS cohort_id,
        spr.SPRIDEN_ID                                AS student_id,
        mv.pidm,
        mv.first_declared_term                        AS cohort_entry_term_id,
        td.term_sequence                              AS entry_term_sequence,
        mv.major_code                                 AS program_code,
        F_STUDENT_GET_DESC('STVMAJR', mv.major_code, 30) AS program_name,
        sg.SGBSTDN_ADMT_CODE                          AS admit_type,
        sg.SGBSTDN_STYP_CODE                          AS stu_type,
        NVL(mat.major_code, mv.major_code)            AS cohort_major_code,
        mat.concentration_code                        AS cohort_concentration_code,
        NVL(pc.prior_cum_hrs, 0)                      AS prior_cum_hrs,
        sg.SGBSTDN_FULL_PART_IND                      AS full_part_ind,
        bp.birth_date,
        it.inst_entry_term_id,
        td_inst.term_sequence                         AS inst_entry_term_sequence,
        CASE
            WHEN NVL(sg.SGBSTDN_STYP_CODE, 'X') = 'C'
            THEN 'PROGRAM_SWITCH'
            ELSE 'NEW'
        END                                           AS program_entry_type,
        CASE
            WHEN mv.declared_by_window = 0
             AND ft.fourth_nonsummer_term IS NULL
            THEN 'OC_MAJOR_WINDOW_PENDING'
            WHEN mv.declared_by_window = 0
            THEN 'OC_MAJOR_NOT_DECLARED:' || mv.major_code
            WHEN mat.major_code IS NULL
            THEN 'OC_NO_SORLCUR_AT_ENTRY'
            WHEN mat.major_code != mv.major_code
            THEN 'OC_MAJOR_MISMATCH:' || mat.major_code
                 || '->EXPECTED:'     || mv.major_code
            ELSE NULL
        END                                           AS data_entry_error_flag
    FROM oc_major_validation mv
    JOIN SPRIDEN spr
        ON  spr.SPRIDEN_PIDM       = mv.pidm
        AND spr.SPRIDEN_CHANGE_IND IS NULL
    JOIN term_dim td
        ON  td.term_id = mv.first_declared_term
    JOIN SGBSTDN sg
        ON  sg.ROWID = F_GET_SGBSTDN_ROWID(mv.pidm, mv.first_declared_term)
    LEFT JOIN major_at_term mat
        ON  mat.pidm             = mv.pidm
        AND mat.term_code_context = mv.first_declared_term
    LEFT JOIN prior_cum pc
        ON  pc.pidm    = mv.pidm
        AND pc.term_id = mv.first_declared_term
    LEFT JOIN birth_dates bp
        ON  bp.pidm = mv.pidm
    LEFT JOIN student_fourth_term ft
        ON  ft.pidm = mv.pidm
    LEFT JOIN inst_entry_term it
        ON  it.pidm = mv.pidm
    LEFT JOIN term_dim td_inst
        ON  td_inst.term_id = it.inst_entry_term_id
    LEFT JOIN prior_oc_majors pm
        ON  pm.pidm            = mv.pidm
        AND pm.prior_major_code != mv.major_code
    -- Exclude stu_type C unless confirmed program switcher:
    --   must have a prior inactive OC major in SORLCUR
    --   that differs from the current program.
    -- Always exclude NDUG non-DE/DM students.
    WHERE (
              NVL(sg.SGBSTDN_STYP_CODE, 'X') != 'C'
           OR pm.prior_major_code IS NOT NULL
          )
      AND NOT (
              NVL(sg.SGBSTDN_DEGC_CODE_1, 'X') = 'NDUG'
          AND sg.SGBSTDN_ADMT_CODE NOT IN ('DE','DM')
          )
),
cohort AS (
    SELECT * FROM cohort_temp
),
cohort_term_flags AS (
    SELECT
        ct.cohort_id,
        MAX(CASE WHEN ct.term_index = 1 THEN 1 ELSE 0 END) AS has_t1,
        MAX(CASE WHEN ct.term_index = 3 THEN 1 ELSE 0 END) AS has_t3,
        MAX(CASE WHEN ct.term_index = 6 THEN 1 ELSE 0 END) AS has_t6,
        MAX(CASE WHEN ct.term_index = 9 THEN 1 ELSE 0 END) AS has_t9
    FROM (
        SELECT
            c.cohort_id,
            td.term_sequence - c.entry_term_sequence  AS term_index
        FROM cohort c
        JOIN SFVRCRS sf
            ON  sf.PIDM_A3       = c.pidm
            AND sf.TOT_CRHRS_A3  > 0
            AND sf.TERM_CODE_A3  > c.cohort_entry_term_id
            AND sf.TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
        JOIN term_dim td
            ON  td.term_id = sf.TERM_CODE_A3
    ) ct
    GROUP BY ct.cohort_id
),
first_award AS (
    SELECT
        c.cohort_id,
        MIN(shd.SHRDGMR_TERM_CODE_GRAD)               AS first_award_term_id,
        MIN(td.term_sequence - c.entry_term_sequence)  AS time_to_award_terms,
        MIN(td.term_sequence - c.inst_entry_term_sequence) AS inst_time_to_award_terms,
        MAX(CASE WHEN rn.award_rank = 1
            THEN shd.SHRDGMR_DEGC_CODE END)            AS first_award_degree_code,
        MAX(CASE WHEN rn.award_rank = 1
            THEN shd.SHRDGMR_MAJR_CODE_1 END)          AS first_award_major_code,
        MAX(CASE
                WHEN shd.SHRDGMR_MAJR_CODE_1 = c.program_code THEN 1
                ELSE 0
            END)                                       AS graduated_in_program_flag,
        MAX(CASE
                WHEN shd.SHRDGMR_MAJR_CODE_1 = c.program_code
                THEN c.program_code
                ELSE NVL(shd.SHRDGMR_MAJR_CODE_1, 'UNKNOWN')
            END)                                       AS first_award_program_code,
        1                                              AS received_award_flag
    FROM cohort c
    JOIN SHRDGMR shd
        ON  shd.SHRDGMR_PIDM           = c.pidm
        AND shd.SHRDGMR_DEGS_CODE      = 'AW'
        AND shd.SHRDGMR_TERM_CODE_GRAD >= c.cohort_entry_term_id
    JOIN term_dim td
        ON  td.term_id = shd.SHRDGMR_TERM_CODE_GRAD
    JOIN (
        SELECT
            shd2.SHRDGMR_PIDM,
            shd2.SHRDGMR_TERM_CODE_GRAD,
            ROW_NUMBER() OVER (
                PARTITION BY shd2.SHRDGMR_PIDM, c2.cohort_id
                ORDER BY shd2.SHRDGMR_TERM_CODE_GRAD ASC
            ) AS award_rank
        FROM SHRDGMR shd2
        JOIN cohort c2
            ON  c2.pidm                      = shd2.SHRDGMR_PIDM
            AND shd2.SHRDGMR_TERM_CODE_GRAD >= c2.cohort_entry_term_id
        WHERE shd2.SHRDGMR_DEGS_CODE = 'AW'
    ) rn
        ON  rn.SHRDGMR_PIDM           = shd.SHRDGMR_PIDM
        AND rn.SHRDGMR_TERM_CODE_GRAD = shd.SHRDGMR_TERM_CODE_GRAD
    GROUP BY c.cohort_id
),
award_retention AS (
    SELECT
        fa.cohort_id,
        c.entry_term_sequence,
        td.term_sequence  AS award_term_seq
    FROM first_award fa
    JOIN cohort c    ON  c.cohort_id = fa.cohort_id
    JOIN term_dim td ON  td.term_id  = fa.first_award_term_id
),
credit_milestones AS (
    SELECT
        c.cohort_id,
        MAX(CASE WHEN gpa.cum_earned >= 12 THEN 1 ELSE 0 END) AS earned_12cr_flag,
        MAX(CASE WHEN gpa.cum_earned >= 24 THEN 1 ELSE 0 END) AS earned_24cr_flag
    FROM cohort c
    JOIN gpa_cumulative gpa
        ON  gpa.pidm    = c.pidm
        AND gpa.term_id >= c.cohort_entry_term_id
    GROUP BY c.cohort_id
),
student_max_term AS (
    SELECT
        c.cohort_id,
        c.pidm,
        MAX(sf.TERM_CODE_A3) AS current_term_id,
        CASE
            WHEN SUM(
                CASE WHEN sf.TERM_CODE_A3 = (SELECT fs_term_id FROM current_fs_term)
                      AND sf.TOT_CRHRS_A3 > 0 THEN 1 ELSE 0 END
            ) > 0
            THEN 1 ELSE 0
        END                  AS currently_enrolled_flag
    FROM cohort c
    LEFT JOIN SFVRCRS sf
        ON  sf.PIDM_A3      = c.pidm
        AND sf.TOT_CRHRS_A3 > 0
        AND sf.TERM_CODE_A3 > c.cohort_entry_term_id
        AND sf.TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
    GROUP BY c.cohort_id, c.pidm
),
current_major AS (
    SELECT
        smt.cohort_id,
        smt.current_term_id,
        smt.currently_enrolled_flag,
        COALESCE(mat.major_code, c.cohort_major_code) AS current_major_code
    FROM student_max_term smt
    JOIN cohort c
        ON  c.cohort_id = smt.cohort_id
    LEFT JOIN major_at_term mat
        ON  mat.pidm              = smt.pidm
        AND mat.term_code_context = smt.current_term_id
)
SELECT /*+ GATHER_PLAN_STATISTICS */
    c.cohort_id,
    c.student_id,
    c.cohort_entry_term_id,
    'OC'                                        AS cohort_type_code,
    c.admit_type,
    c.stu_type,
    c.cohort_major_code,
    F_STUDENT_GET_DESC('STVMAJR',
        c.cohort_major_code, 30)                AS cohort_major_desc,
    c.cohort_concentration_code,
    F_STUDENT_GET_DESC('STVMAJR',
        c.cohort_concentration_code, 30)        AS cohort_concentration_desc,
    c.prior_cum_hrs,
    NULL                                        AS entry_term_crhrs,
    NULL                                        AS readmit_event_sequence,
    NVL(c.data_entry_error_flag, 'Clean')       AS error_flag,
    0                                           AS misclassified_dm_flag,
    0                                           AS de_as_dm_flag,
    mt.max_seq,
    CASE
        WHEN mt.max_seq < c.entry_term_sequence + 1 THEN NULL
        WHEN NVL(ctf.has_t1, 0) = 1
          OR (ar.award_term_seq IS NOT NULL
              AND ar.award_term_seq <= c.entry_term_sequence + 1)
        THEN 1 ELSE 0
    END                                         AS retained_next_term,
    CASE
        WHEN mt.max_seq < c.entry_term_sequence + 3 THEN NULL
        WHEN NVL(ctf.has_t3, 0) = 1
          OR (ar.award_term_seq IS NOT NULL
              AND ar.award_term_seq <= c.entry_term_sequence + 3)
        THEN 1 ELSE 0
    END                                         AS retained_1yr,
    CASE
        WHEN mt.max_seq < c.entry_term_sequence + 6 THEN NULL
        WHEN NVL(ctf.has_t6, 0) = 1
          OR (ar.award_term_seq IS NOT NULL
              AND ar.award_term_seq <= c.entry_term_sequence + 6)
        THEN 1 ELSE 0
    END                                         AS retained_2yr,
    CASE
        WHEN mt.max_seq < c.entry_term_sequence + 9 THEN NULL
        WHEN NVL(ctf.has_t9, 0) = 1
          OR (ar.award_term_seq IS NOT NULL
              AND ar.award_term_seq <= c.entry_term_sequence + 9)
        THEN 1 ELSE 0
    END                                         AS retained_3yr,
    0                                           AS retained_in_major_t1,
    NVL(cm.earned_12cr_flag, 0)                 AS earned_12cr_flag,
    NVL(cm.earned_24cr_flag, 0)                 AS earned_24cr_flag,
    NVL(fa.received_award_flag, 0)              AS received_award_flag,
    c.program_code,
    c.program_name,
    c.inst_entry_term_id                        AS inst_entry_term,
    CASE
        WHEN c.inst_entry_term_sequence IS NOT NULL
        THEN c.entry_term_sequence - c.inst_entry_term_sequence
        ELSE NULL
    END                                         AS terms_since_inst_entry,
    c.program_entry_type,
    fa.first_award_term_id,
    fa.first_award_degree_code,
    fa.first_award_major_code,
    fa.time_to_award_terms,
    fa.inst_time_to_award_terms,
    NVL(fa.graduated_in_program_flag, 0)        AS graduated_in_program_flag,
    0                                           AS graduated_in_closed_flag,
    0                                           AS matriculated_to_rscc_flag,
    0                                           AS graduated_rscc_flag,
    cm2.current_term_id,
    CASE
        WHEN NVL(fa.received_award_flag, 0) = 1
            THEN fa.first_award_major_code
        ELSE cm2.current_major_code
    END                                         AS last_major_code,
    CASE
        WHEN NVL(fa.received_award_flag, 0) = 1
            THEN F_STUDENT_GET_DESC('STVMAJR', fa.first_award_major_code, 30)
        ELSE F_STUDENT_GET_DESC('STVMAJR', cm2.current_major_code, 30)
    END                                         AS last_major_desc,
    cm2.currently_enrolled_flag,
    0                                           AS enrolled_rscc_flag,
    0                                           AS enrolled_in_closed_flag,
    CASE
        WHEN NVL(fa.graduated_in_program_flag, 0) = 1
            THEN 'Same Major'
        WHEN NVL(fa.received_award_flag, 0) = 1
            THEN 'Changed Major - Graduated'
        WHEN cm2.current_major_code = c.cohort_major_code
            THEN 'Same Major'
        ELSE 'Changed Major'
    END                                         AS major_change_flag,
    0                                           AS next_term_matriculation_flag,
    NULL                                        AS oc_gateway_flag,
    0                                           AS graduated_other_closed_flag,
    0                                           AS enrolled_other_closed_flag,
    c.full_part_ind,
    sa.age_at_entry,
    sa.age_group,
    SYSDATE                                     AS ExtractDate
FROM cohort c
CROSS JOIN max_term mt
LEFT JOIN cohort_term_flags ctf  ON ctf.cohort_id = c.cohort_id
LEFT JOIN first_award fa         ON fa.cohort_id  = c.cohort_id
LEFT JOIN credit_milestones cm   ON cm.cohort_id  = c.cohort_id
LEFT JOIN award_retention ar     ON ar.cohort_id  = c.cohort_id
LEFT JOIN current_major cm2      ON cm2.cohort_id = c.cohort_id
LEFT JOIN student_ages sa        ON sa.cohort_id  = c.cohort_id
ORDER BY c.program_code, c.cohort_entry_term_id, c.student_id
