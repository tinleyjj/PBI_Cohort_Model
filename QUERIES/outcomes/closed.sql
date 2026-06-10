-- ==================================================
-- RPT-008-CL: outcomes_CL.csv
-- Closed-admission program cohort outcomes
-- Grain: one row per student per program per first
--        gateway course enrollment term
-- Output: outcomes_CL.csv via Argos SFTP
-- Refresh cadence: Per term (full rebuild)
-- Union schema: 51 columns (v1)
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
),
max_term AS (
    SELECT MAX(term_sequence) AS max_seq FROM term_dim
),
current_fs_term AS (
    -- Most recent Fall or Spring term up to TERM1.
    -- Used for currently_enrolled_flag to avoid summer enrollment artifacts.
    SELECT MAX(STVTERM_CODE) AS fs_term_id
    FROM STVTERM
    WHERE STVTERM_CODE <= F_RSCC_GET_TERM('TERM1')
    AND   SUBSTR(STVTERM_CODE, 5, 2) IN ('10', '80')
),
program_codes AS (
    SELECT 'ADHT' AS major_code, 'DENTAL_HYG'  AS program_code, 'Dental Hygiene'                AS program_name FROM DUAL UNION ALL
    SELECT 'DHTH', 'DENTAL_HYG',  'Dental Hygiene'                FROM DUAL UNION ALL
    SELECT 'NURT', 'NURSING',     'Nursing'                       FROM DUAL UNION ALL
    SELECT 'NURH', 'NURSING',     'Nursing'                       FROM DUAL UNION ALL
    SELECT 'NURL', 'NURS_BRIDGE', 'Nursing - RN Bridge Option'    FROM DUAL UNION ALL
    SELECT 'AOTA', 'OTA',         'Occupational Therapy Assistant' FROM DUAL UNION ALL
    SELECT 'OTAH', 'OTA',         'Occupational Therapy Assistant' FROM DUAL UNION ALL
    SELECT 'APTA', 'PTA',         'Physical Therapist Assistant'   FROM DUAL UNION ALL
    SELECT 'PTAH', 'PTA',         'Physical Therapist Assistant'   FROM DUAL UNION ALL
    SELECT 'ARDT', 'RAD_TECH',    'Radiologic Technology'          FROM DUAL UNION ALL
    SELECT 'RDTH', 'RAD_TECH',    'Radiologic Technology'          FROM DUAL UNION ALL
    SELECT 'ARSP', 'RESP_CARE',   'Respiratory Care'               FROM DUAL UNION ALL
    SELECT 'ARTT', 'RESP_CARE',   'Respiratory Care'               FROM DUAL UNION ALL
    SELECT 'RTTH', 'RESP_CARE',   'Respiratory Care'               FROM DUAL UNION ALL
    SELECT 'ASRG', 'SURG_TECH',   'Surgical Technology'            FROM DUAL UNION ALL
    SELECT 'SRGH', 'SURG_TECH',   'Surgical Technology'            FROM DUAL
),
gateway_courses AS (
    SELECT 'NRSG' AS subj, '1360' AS crse, NULL         AS program_code FROM DUAL UNION ALL
    SELECT 'DHYG', '111',                  'DENTAL_HYG'                 FROM DUAL UNION ALL
    SELECT 'OTAP', '1210',                 'OTA'                        FROM DUAL UNION ALL
    SELECT 'PTAT', '2460',                 'PTA'                        FROM DUAL UNION ALL
    SELECT 'RADT', '1215',                 'RAD_TECH'                   FROM DUAL UNION ALL
    SELECT 'RESP', '1410',                 'RESP_CARE'                  FROM DUAL UNION ALL
    SELECT 'SURG', '1410',                 'SURG_TECH'                  FROM DUAL
),
prior_cum AS (
    SELECT
        g.SHRTGPA_PIDM      AS pidm,
        g.SHRTGPA_TERM_CODE AS term_id,
        SUM(g.SHRTGPA_HOURS_EARNED) OVER (
            PARTITION BY g.SHRTGPA_PIDM
            ORDER BY g.SHRTGPA_TERM_CODE
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        )                   AS prior_cum_hrs
    FROM SHRTGPA g
    WHERE g.SHRTGPA_LEVL_CODE   = 'UG'
      AND g.SHRTGPA_GPA_TYPE_IND = 'I'
),
sorlcur_at_term AS (
    -- Current-state SORLCUR lookup using full validated ordering:
    -- most recent effective term first, then lowest priority,
    -- then highest sequence number.
    SELECT pidm, term_id, major_code
    FROM (
        SELECT
            SORLCUR_PIDM          AS pidm,
            SORLCUR_TERM_CODE     AS term_id,
            SORLCUR_PROGRAM       AS major_code,
            ROW_NUMBER() OVER (
                PARTITION BY SORLCUR_PIDM, SORLCUR_TERM_CODE
                ORDER BY SORLCUR_TERM_CODE   DESC,
                         SORLCUR_PRIORITY_NO  ASC,
                         SORLCUR_SEQNO        DESC
            )                     AS rn
        FROM SORLCUR
        WHERE SORLCUR_LMOD_CODE   = 'LEARNER'
          AND SORLCUR_CACT_CODE   = 'ACTIVE'
          AND SORLCUR_TERM_CODE   >= '202080'
          AND SORLCUR_TERM_CODE   <= F_RSCC_GET_TERM('TERM1')
    )
    WHERE rn = 1
),
enrollment_spine AS (
    SELECT
        ri.SFVSTMS_PIDM,
        ri.SFVSTMS_TERM_CODE,
        ri.SFVSTMS_SUBJ_CODE,
        ri.SFVSTMS_CRSE_NUMB,
        ri.SFVSTMS_GRADABLE_IND
    FROM (
        SELECT /*+ MATERIALIZE */
            SFVSTMS_PIDM,
            SFVSTMS_TERM_CODE,
            SFVSTMS_SUBJ_CODE,
            SFVSTMS_CRSE_NUMB,
            SFVSTMS_GRADABLE_IND,
            SFVSTMS_PRIMARY_IND,
            ROW_NUMBER() OVER (
                PARTITION BY SFVSTMS_TERM_CODE, SFVSTMS_CRN, SFVSTMS_PIDM
                ORDER BY SFVSTMS_PRIMARY_IND NULLS LAST
            ) AS row_num
        FROM SFVSTMS
        WHERE SFVSTMS_TERM_CODE >= '202080'
          AND SFVSTMS_TERM_CODE <= F_RSCC_GET_TERM('TERM1')
    ) ri
    WHERE ri.row_num = 1
),
cohort AS (
    SELECT
        spr.SPRIDEN_ID
            || '-CL-'
            || CASE
                   WHEN gc.program_code IS NOT NULL      THEN gc.program_code
                   WHEN pc_sorl.program_code IS NOT NULL THEN pc_sorl.program_code
                   ELSE 'NURSING'
               END
            || '-' || es.SFVSTMS_TERM_CODE               AS cohort_id,
        spr.SPRIDEN_ID                                    AS student_id,
        es.SFVSTMS_PIDM                                   AS pidm,
        es.SFVSTMS_TERM_CODE                              AS cohort_entry_term_id,
        td.term_sequence                                  AS entry_term_sequence,
        CASE
            WHEN gc.program_code IS NOT NULL              THEN gc.program_code
            WHEN pc_sorl.program_code IS NOT NULL         THEN pc_sorl.program_code
            ELSE 'NURSING'
        END                                               AS program_code,
        CASE
            WHEN gc.program_code IS NOT NULL
            THEN pc_gc.program_name
            WHEN pc_sorl.program_code IS NOT NULL
            THEN pc_sorl.program_name
            ELSE 'Nursing'
        END                                               AS program_name,
        sm.major_code                                     AS cohort_major_code,
        sg.SGBSTDN_ADMT_CODE                              AS admit_type,
        sg.SGBSTDN_STYP_CODE                              AS stu_type,
        NVL(pc.prior_cum_hrs, 0)                          AS prior_cum_hrs,
        CASE
            WHEN sm.major_code IS NULL
             AND gc.program_code IS NULL
            THEN 'NRSG_NO_SORLCUR'
            WHEN sm.major_code IS NULL
            THEN 'NO_SORLCUR_RECORD'
            WHEN pc_sorl.program_code IS NULL
            THEN 'UNKNOWN_MAJOR:' || sm.major_code
            WHEN gc.program_code IS NOT NULL
             AND pc_sorl.program_code != gc.program_code
            THEN 'MAJOR_MISMATCH:'  || sm.major_code
                 || '->EXPECTED:'   || gc.program_code
            WHEN gc.program_code IS NULL
             AND pc_sorl.program_code NOT IN ('NURSING','NURS_BRIDGE')
            THEN 'NRSG_MAJOR_MISMATCH:' || sm.major_code
            ELSE NULL
        END                                               AS data_entry_error_flag
    FROM (
        SELECT
            es2.SFVSTMS_PIDM,
            es2.SFVSTMS_TERM_CODE,
            es2.SFVSTMS_SUBJ_CODE,
            es2.SFVSTMS_CRSE_NUMB,
            es2.SFVSTMS_GRADABLE_IND,
            ROW_NUMBER() OVER (
                PARTITION BY es2.SFVSTMS_PIDM,
                             NVL(gc2.program_code, 'NRSG_NURSING')
                ORDER BY es2.SFVSTMS_TERM_CODE
            ) AS attempt_num
        FROM enrollment_spine es2
        JOIN gateway_courses gc2
            ON  gc2.subj = es2.SFVSTMS_SUBJ_CODE
            AND gc2.crse = es2.SFVSTMS_CRSE_NUMB
        WHERE es2.SFVSTMS_GRADABLE_IND != 'E'
    ) es
    JOIN gateway_courses gc
        ON  gc.subj = es.SFVSTMS_SUBJ_CODE
        AND gc.crse = es.SFVSTMS_CRSE_NUMB
    JOIN SPRIDEN spr
        ON  spr.SPRIDEN_PIDM       = es.SFVSTMS_PIDM
        AND spr.SPRIDEN_CHANGE_IND IS NULL
    JOIN term_dim td
        ON  td.term_id = es.SFVSTMS_TERM_CODE
    JOIN SGBSTDN sg
        ON  sg.ROWID = F_GET_SGBSTDN_ROWID(es.SFVSTMS_PIDM, es.SFVSTMS_TERM_CODE)
    LEFT JOIN prior_cum pc
        ON  pc.pidm    = es.SFVSTMS_PIDM
        AND pc.term_id = es.SFVSTMS_TERM_CODE
    LEFT JOIN sorlcur_at_term sm
        ON  sm.pidm    = es.SFVSTMS_PIDM
        AND sm.term_id = es.SFVSTMS_TERM_CODE
    LEFT JOIN program_codes pc_sorl
        ON  pc_sorl.major_code = sm.major_code
    LEFT JOIN program_codes pc_gc
        ON  pc_gc.program_code = gc.program_code
        AND pc_gc.major_code   = (
            SELECT MIN(p2.major_code)
            FROM program_codes p2
            WHERE p2.program_code = gc.program_code
        )
    WHERE es.attempt_num = 1
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
            td.term_sequence - c.entry_term_sequence   AS term_index
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
        MIN(shd.SHRDGMR_TERM_CODE_GRAD)              AS first_award_term_id,
        MIN(td.term_sequence - c.entry_term_sequence) AS time_to_award_terms,
        -- Use award_rank = 1 to correlate degree and major from the same
        -- earliest award row. MIN() on independent columns can pull from
        -- different rows when a student has multiple awards.
        MAX(CASE WHEN rn.award_rank = 1
            THEN shd.SHRDGMR_DEGC_CODE END)           AS first_award_degree_code,
        MAX(CASE WHEN rn.award_rank = 1
            THEN shd.SHRDGMR_MAJR_CODE_1 END)         AS first_award_major_code,
        MAX(CASE
                WHEN pc2.program_code = c.program_code THEN 1
                ELSE 0
            END)                                      AS graduated_in_program_flag,
        MAX(CASE
                WHEN pc2.program_code = c.program_code
                THEN c.program_code
                ELSE NVL(pc2.program_code, 'UNKNOWN')
            END)                                      AS first_award_program_code,
        1                                             AS received_award_flag
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
    LEFT JOIN program_codes pc2
        ON  pc2.major_code = shd.SHRDGMR_MAJR_CODE_1
    GROUP BY c.cohort_id
),
award_retention AS (
    SELECT
        fa.cohort_id,
        c.entry_term_sequence,
        td.term_sequence    AS award_term_seq
    FROM first_award fa
    JOIN cohort c    ON  c.cohort_id  = fa.cohort_id
    JOIN term_dim td ON  td.term_id   = fa.first_award_term_id
),
-- --------------------------------------------------------
-- Credit milestones offset by prior_cum_hrs so transfer
-- credits do not trigger flags before the student has
-- earned anything in the program.
-- --------------------------------------------------------
credit_milestones AS (
    SELECT
        c.cohort_id,
        MAX(CASE WHEN cum.cum_earned - c.prior_cum_hrs >= 12 THEN 1 ELSE 0 END) AS earned_12cr_flag,
        MAX(CASE WHEN cum.cum_earned - c.prior_cum_hrs >= 24 THEN 1 ELSE 0 END) AS earned_24cr_flag
    FROM cohort c
    JOIN (
        SELECT
            g.SHRTGPA_PIDM      AS pidm,
            g.SHRTGPA_TERM_CODE AS term_id,
            SUM(g.SHRTGPA_HOURS_EARNED) OVER (
                PARTITION BY g.SHRTGPA_PIDM
                ORDER BY g.SHRTGPA_TERM_CODE
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )                   AS cum_earned
        FROM SHRTGPA g
        WHERE g.SHRTGPA_LEVL_CODE   = 'UG'
          AND g.SHRTGPA_GPA_TYPE_IND = 'I'
    ) cum
        ON  cum.pidm    = c.pidm
        AND cum.term_id >= c.cohort_entry_term_id
    GROUP BY c.cohort_id
),
-- ============================================================
-- Current state CTEs
-- ============================================================
student_max_term AS (
    SELECT
        c.cohort_id,
        c.pidm,
        MAX(sf.TERM_CODE_A3)    AS current_term_id,
        CASE
            WHEN SUM(CASE WHEN sf.TERM_CODE_A3 = (SELECT fs_term_id FROM current_fs_term)
                              AND sf.TOT_CRHRS_A3 > 0 THEN 1 ELSE 0 END) > 0
            THEN 1 ELSE 0
        END                     AS currently_enrolled_flag
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
        COALESCE(sm.major_code, c.cohort_major_code) AS current_major_code
    FROM student_max_term smt
    JOIN cohort c
        ON  c.cohort_id = smt.cohort_id
    LEFT JOIN sorlcur_at_term sm
        ON  sm.pidm    = smt.pidm
        AND sm.term_id = smt.current_term_id
)
SELECT /*+ GATHER_PLAN_STATISTICS */
    c.cohort_id,
    c.student_id,
    c.cohort_entry_term_id,
    'CL'                                        AS cohort_type_code,
    c.admit_type,
    c.stu_type,
    c.cohort_major_code,
    F_STUDENT_GET_DESC('STVMAJR',
        c.cohort_major_code, 30)                AS cohort_major_desc,
    NULL                                        AS cohort_concentration_code,
    NULL                                        AS cohort_concentration_desc,
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
    NULL                                        AS inst_entry_term,
    NULL                                        AS terms_since_inst_entry,
    NULL                                        AS program_entry_type,
    fa.first_award_term_id,
    fa.first_award_degree_code,
    fa.first_award_major_code,
    fa.time_to_award_terms,
    NULL                                        AS inst_time_to_award_terms,
    NVL(fa.graduated_in_program_flag, 0)        AS graduated_in_program_flag,
    0                                           AS graduated_in_closed_flag,
    0                                           AS matriculated_to_rscc_flag,
    0                                           AS graduated_rscc_flag,
    -- ============================================================
    -- Current state fields
    -- ============================================================
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
    -- enrolled_in_closed_flag: currently enrolled in ANY closed program
    -- enrolled_other_closed_flag: currently enrolled in a DIFFERENT closed program
    CASE
        WHEN cm2.currently_enrolled_flag = 1
            AND cm2.current_major_code IN (
                SELECT DISTINCT major_code FROM program_codes
            )
        THEN 1 ELSE 0
    END                                         AS enrolled_in_closed_flag,
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
    -- ============================================================
    -- CL-specific outcome flags
    -- ============================================================
    CASE
        WHEN NVL(fa.received_award_flag, 0) = 1
            AND NVL(fa.graduated_in_program_flag, 0) = 0
            AND fa.first_award_program_code IN (
                SELECT DISTINCT program_code FROM program_codes
            )
        THEN 1 ELSE 0
    END                                         AS graduated_other_closed_flag,
    CASE
        WHEN cm2.currently_enrolled_flag = 1
            AND cm2.current_major_code != c.cohort_major_code
            AND cm2.current_major_code IN (
                SELECT DISTINCT major_code FROM program_codes
            )
        THEN 1 ELSE 0
    END                                         AS enrolled_other_closed_flag,
    NULL                                        AS oc_gateway_flag,
    SYSDATE                                     AS ExtractDate
FROM cohort c
CROSS JOIN max_term mt
LEFT JOIN cohort_term_flags ctf  ON ctf.cohort_id = c.cohort_id
LEFT JOIN first_award fa         ON fa.cohort_id  = c.cohort_id
LEFT JOIN credit_milestones cm   ON cm.cohort_id  = c.cohort_id
LEFT JOIN award_retention ar     ON ar.cohort_id  = c.cohort_id
LEFT JOIN current_major cm2      ON cm2.cohort_id = c.cohort_id
ORDER BY c.program_code, c.cohort_entry_term_id, c.student_id
