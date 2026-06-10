-- ==================================================
-- RPT-008-NF: outcomes_NF.csv
-- New Freshman cohort outcomes -- all terms from 202080
-- Grain: one row per student per cohort entry term
-- Output: outcomes_NF.csv via Argos SFTP
-- Refresh cadence: Per term (full rebuild)
-- Union schema: 51 columns (v1)
--
-- Cohort rule: SORLCUR_ADMT_CODE = 'FR' (as-of term)
--   + SGBSTDN_STYP_CODE IN ('N','B').
-- Admission gate is SORLCUR (matches RPT-004 profile
--   StudentClass definition for First Time Freshman).
-- SGBSTDN provides stu_type and degree code only.
-- B students (summer starters) shift cohort_entry_term_id
--   to following Fall; entry_seq joins on shifted term
--   so retention window arithmetic is correct.
-- ==================================================

WITH

term_dim AS (
    SELECT
        t.STVTERM_CODE                               AS term_id,
        ROW_NUMBER() OVER (ORDER BY t.STVTERM_CODE)  AS term_sequence
    FROM STVTERM t
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

-- Closed program major codes for graduated_in_closed / enrolled_in_closed flags
program_codes AS (
    SELECT 'ADHT' AS major_code FROM DUAL UNION ALL
    SELECT 'DHTH'               FROM DUAL UNION ALL
    SELECT 'NURT'               FROM DUAL UNION ALL
    SELECT 'NURH'               FROM DUAL UNION ALL
    SELECT 'NURL'               FROM DUAL UNION ALL
    SELECT 'AOTA'               FROM DUAL UNION ALL
    SELECT 'OTAH'               FROM DUAL UNION ALL
    SELECT 'APTA'               FROM DUAL UNION ALL
    SELECT 'PTAH'               FROM DUAL UNION ALL
    SELECT 'ARDT'               FROM DUAL UNION ALL
    SELECT 'RDTH'               FROM DUAL UNION ALL
    SELECT 'ARSP'               FROM DUAL UNION ALL
    SELECT 'ARTT'               FROM DUAL UNION ALL
    SELECT 'RTTH'               FROM DUAL UNION ALL
    SELECT 'ASRG'               FROM DUAL UNION ALL
    SELECT 'SRGH'               FROM DUAL
),

nf_raw AS (
    SELECT
        spr.SPRIDEN_ID                               AS student_id,
        sf.PIDM_A3                                   AS pidm,
        CASE
            WHEN sg.SGBSTDN_STYP_CODE = 'B'
            THEN SUBSTR(sf.TERM_CODE_A3, 1, 4) || '80'
            ELSE sf.TERM_CODE_A3
        END                                          AS cohort_entry_term_id,
        sf.TERM_CODE_A3                              AS raw_enrollment_term,
        lae.SORLCUR_ADMT_CODE                        AS admit_type,
        sg.SGBSTDN_STYP_CODE                         AS stu_type,
        lae.SORLCUR_PROGRAM                          AS major_code,
        lae.SORLFOS_MAJR_CODE                        AS concentration_code,
        sf.TOT_CRHRS_A3                              AS entry_term_crhrs,
        ROW_NUMBER() OVER (
            PARTITION BY sf.PIDM_A3
            ORDER BY sf.TERM_CODE_A3
        )                                            AS rn
    FROM SFVRCRS sf
    JOIN SPRIDEN spr
        ON  spr.SPRIDEN_PIDM       = sf.PIDM_A3
        AND spr.SPRIDEN_CHANGE_IND IS NULL
    LEFT JOIN SGBSTDN sg
        ON  sg.ROWID = F_GET_SGBSTDN_ROWID(sf.PIDM_A3, sf.TERM_CODE_A3)
    -- SORLCUR: most recent active curriculum record as-of enrollment term.
    -- Mirrors RPT-004 STU_MAJOR and outcomes_DE_DM lae pattern:
    --   SORLCUR_TERM_CODE <= enrollment term (as-of filter)
    --   ORDER BY term DESC, priority ASC, seqno DESC
    -- No ADMT_CODE filter inside subquery; FR gate applied in WHERE below.
    JOIN (
        SELECT
            major.*,
            ROW_NUMBER() OVER (
                PARTITION BY major.SORLCUR_PIDM, major.TERM_CODE_CONTEXT
                ORDER BY major.SORLCUR_TERM_CODE   DESC,
                         major.SORLCUR_PRIORITY_NO ASC,
                         major.SORLCUR_SEQNO       DESC
            ) AS ROW_1
        FROM (
            SELECT
                d.SORLCUR_PIDM,
                d.SORLCUR_TERM_CODE,
                d.SORLCUR_SEQNO,
                d.SORLCUR_PRIORITY_NO,
                d.SORLCUR_ADMT_CODE,
                d.SORLCUR_PROGRAM,
                d.SORLCUR_LMOD_CODE,
                d.SORLCUR_CACT_CODE,
                f.SORLFOS_MAJR_CODE,
                sf_inner.TERM_CODE_A3                AS TERM_CODE_CONTEXT
            FROM SORLCUR d
            JOIN SFVRCRS sf_inner
                ON  sf_inner.PIDM_A3       = d.SORLCUR_PIDM
                AND sf_inner.TERM_CODE_A3 >= :Term
                AND sf_inner.TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
                AND sf_inner.TOT_CRHRS_A3  > 0
            LEFT JOIN SORLFOS f
                ON  f.SORLFOS_PIDM       = d.SORLCUR_PIDM
                AND f.SORLFOS_LCUR_SEQNO = d.SORLCUR_SEQNO
                AND f.SORLFOS_LFST_CODE  = 'CONCENTRATION'
                AND f.SORLFOS_CSTS_CODE  = 'INPROGRESS'
        ) major
        WHERE major.SORLCUR_LMOD_CODE  = 'LEARNER'
        AND   major.SORLCUR_CACT_CODE  = 'ACTIVE'
        AND   major.SORLCUR_TERM_CODE <= major.TERM_CODE_CONTEXT
    ) lae
        ON  lae.SORLCUR_PIDM      = sf.PIDM_A3
        AND lae.TERM_CODE_CONTEXT  = sf.TERM_CODE_A3
        AND lae.ROW_1              = 1
    WHERE sf.TERM_CODE_A3        >= :Term
    AND   sf.TERM_CODE_A3        <= F_RSCC_GET_TERM('TERM1')
    AND   sf.TOT_CRHRS_A3         > 0
    -- Admission gate on SORLCUR: matches RPT-004 StudentClass definition.
    -- stu_type gate on SGBSTDN: N = standard entry, B = summer starter.
    AND   lae.SORLCUR_ADMT_CODE                  = 'FR'
    AND   NVL(sg.SGBSTDN_STYP_CODE, 'X')        IN ('N', 'B')
    AND   NVL(sg.SGBSTDN_DEGC_CODE_1, 'X')      != 'NDUG'
),

master_cohort AS (
    -- Deduplicate to first enrollment event per student.
    -- Join term_dim on cohort_entry_term_id (shifted Fall for B students)
    -- so entry_seq is correct for all retention window arithmetic.
    SELECT
        nr.student_id,
        nr.pidm,
        nr.cohort_entry_term_id,
        td.term_sequence                             AS entry_seq,
        nr.admit_type,
        nr.stu_type,
        nr.major_code,
        nr.concentration_code,
        nr.entry_term_crhrs
    FROM nf_raw nr
    JOIN term_dim td
        ON  td.term_id = nr.cohort_entry_term_id
    WHERE nr.rn = 1
),

all_outcomes AS (
    SELECT
        mc.pidm,
        MAX(NVL((
            SELECT SUM(g.SHRTGPA_HOURS_EARNED)
            FROM   SHRTGPA g
            WHERE  g.SHRTGPA_PIDM         = mc.pidm
            AND    g.SHRTGPA_TERM_CODE    < mc.cohort_entry_term_id
            AND    g.SHRTGPA_LEVL_CODE    = 'UG'
            AND    g.SHRTGPA_GPA_TYPE_IND = 'I'
        ), 0))                                                          AS prior_cum_hrs,
        MAX(CASE WHEN td.term_sequence = mc.entry_seq + 1 THEN 1 ELSE 0 END) AS has_t1,
        MAX(CASE WHEN td.term_sequence = mc.entry_seq + 3 THEN 1 ELSE 0 END) AS has_t3,
        MAX(CASE WHEN td.term_sequence = mc.entry_seq + 6 THEN 1 ELSE 0 END) AS has_t6,
        MAX(CASE WHEN td.term_sequence = mc.entry_seq + 9 THEN 1 ELSE 0 END) AS has_t9,
        MAX(CASE WHEN g_cum.cum_earned >= 12 THEN 1 ELSE 0 END)         AS earned_12cr,
        MAX(CASE WHEN g_cum.cum_earned >= 24 THEN 1 ELSE 0 END)         AS earned_24cr,
        MIN(shd.SHRDGMR_TERM_CODE_GRAD)                                 AS award_term,
        MIN(td_aw.term_sequence)                                        AS award_seq,
        -- Use award_rank = 1 to correlate degree and major from the same
        -- earliest award row. MIN() on independent columns can pull from
        -- different rows when a student has multiple awards.
        MAX(CASE WHEN shd.award_rank = 1
            THEN shd.SHRDGMR_DEGC_CODE END)                             AS award_degree,
        MAX(CASE WHEN shd.award_rank = 1
            THEN shd.SHRDGMR_MAJR_CODE_1 END)                          AS award_major
    FROM master_cohort mc
    LEFT JOIN SFVRCRS sf_post
        ON  sf_post.PIDM_A3      = mc.pidm
        AND sf_post.TOT_CRHRS_A3 > 0
        AND sf_post.TERM_CODE_A3 > mc.cohort_entry_term_id
    LEFT JOIN term_dim td
        ON  td.term_id = sf_post.TERM_CODE_A3
    LEFT JOIN (
        SELECT
            SHRTGPA_PIDM,
            SHRTGPA_TERM_CODE,
            SUM(SHRTGPA_HOURS_EARNED) OVER (
                PARTITION BY SHRTGPA_PIDM
                ORDER BY SHRTGPA_TERM_CODE
            )                                        AS cum_earned
        FROM SHRTGPA
        WHERE SHRTGPA_LEVL_CODE    = 'UG'
        AND   SHRTGPA_GPA_TYPE_IND = 'I'
    ) g_cum
        ON  g_cum.SHRTGPA_PIDM      = mc.pidm
        AND g_cum.SHRTGPA_TERM_CODE >= mc.cohort_entry_term_id
    LEFT JOIN (
        SELECT
            shd2.SHRDGMR_PIDM,
            shd2.SHRDGMR_TERM_CODE_GRAD,
            shd2.SHRDGMR_DEGC_CODE,
            shd2.SHRDGMR_MAJR_CODE_1,
            ROW_NUMBER() OVER (
                PARTITION BY shd2.SHRDGMR_PIDM
                ORDER BY shd2.SHRDGMR_TERM_CODE_GRAD ASC
            ) AS award_rank
        FROM SHRDGMR shd2
        JOIN master_cohort mc2
            ON  mc2.pidm                     = shd2.SHRDGMR_PIDM
            AND shd2.SHRDGMR_TERM_CODE_GRAD >= mc2.cohort_entry_term_id
        WHERE shd2.SHRDGMR_DEGS_CODE = 'AW'
    ) shd
        ON  shd.SHRDGMR_PIDM = mc.pidm
    LEFT JOIN term_dim td_aw
        ON  td_aw.term_id = shd.SHRDGMR_TERM_CODE_GRAD
    GROUP BY mc.pidm
),

-- ============================================================
-- Current state CTEs
-- ============================================================
sorlcur_current AS (
    -- Standalone current-term SORLCUR for last_major_code lookup.
    -- Separate from nf_raw lae subquery (which uses as-of-term logic).
    -- Uses full validated ordering: most recent effective term first,
    -- then lowest priority, then highest sequence number.
    SELECT pidm, term_id, major_code
    FROM (
        SELECT
            SORLCUR_PIDM        AS pidm,
            SORLCUR_TERM_CODE   AS term_id,
            SORLCUR_PROGRAM     AS major_code,
            ROW_NUMBER() OVER (
                PARTITION BY SORLCUR_PIDM, SORLCUR_TERM_CODE
                ORDER BY SORLCUR_TERM_CODE   DESC,
                         SORLCUR_PRIORITY_NO  ASC,
                         SORLCUR_SEQNO        DESC
            )                   AS rn
        FROM SORLCUR
        WHERE SORLCUR_LMOD_CODE   = 'LEARNER'
        AND   SORLCUR_CACT_CODE   = 'ACTIVE'
        AND   SORLCUR_TERM_CODE  >= :Term
        AND   SORLCUR_TERM_CODE  <= F_RSCC_GET_TERM('TERM1')
    )
    WHERE rn = 1
),

student_max_term AS (
    SELECT
        mc.pidm,
        MAX(sf.TERM_CODE_A3)    AS current_term_id,
        CASE
            WHEN SUM(CASE
                WHEN sf.TERM_CODE_A3 = (SELECT fs_term_id FROM current_fs_term)
                     AND sf.TOT_CRHRS_A3 > 0 THEN 1 ELSE 0
            END) > 0
            THEN 1 ELSE 0
        END                     AS currently_enrolled_flag
    FROM master_cohort mc
    LEFT JOIN SFVRCRS sf
        ON  sf.PIDM_A3      = mc.pidm
        AND sf.TOT_CRHRS_A3 > 0
        AND sf.TERM_CODE_A3 > mc.cohort_entry_term_id
        AND sf.TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
    GROUP BY mc.pidm
),

current_major AS (
    SELECT
        smt.pidm,
        smt.current_term_id,
        smt.currently_enrolled_flag,
        COALESCE(sc.major_code, mc.major_code)  AS current_major_code
    FROM student_max_term smt
    LEFT JOIN sorlcur_current sc
        ON  sc.pidm    = smt.pidm
        AND sc.term_id = smt.current_term_id
    LEFT JOIN master_cohort mc
        ON  mc.pidm    = smt.pidm
)

SELECT
    mc.student_id || '-NF-' || mc.cohort_entry_term_id          AS cohort_id,
    mc.student_id,
    mc.cohort_entry_term_id,
    'NF'                                                         AS cohort_type_code,
    mc.admit_type,
    'N'                                                          AS stu_type,
    mc.major_code                                                AS cohort_major_code,
    F_STUDENT_GET_DESC('STVMAJR', mc.major_code, 30)             AS cohort_major_desc,
    mc.concentration_code                                        AS cohort_concentration_code,
    F_STUDENT_GET_DESC('STVMAJR', mc.concentration_code, 30)     AS cohort_concentration_desc,
    o.prior_cum_hrs,
    mc.entry_term_crhrs,
    NULL                                                         AS readmit_event_sequence,
    CASE
        WHEN mc.stu_type     = 'B' THEN 'Process Error: Fall Bridge recoded to New'
        WHEN o.prior_cum_hrs > 12  THEN 'Data Integrity: NF with Prior Inst Credits'
        ELSE 'Clean'
    END                                                          AS error_flag,
    0                                                            AS misclassified_dm_flag,
    0                                                            AS de_as_dm_flag,
    mt.max_seq,
    CASE WHEN mt.max_seq < mc.entry_seq + 1 THEN NULL
         WHEN o.has_t1 = 1 OR o.award_seq <= mc.entry_seq + 1 THEN 1 ELSE 0
    END                                                          AS retained_next_term,
    CASE WHEN mt.max_seq < mc.entry_seq + 3 THEN NULL
         WHEN o.has_t3 = 1 OR o.award_seq <= mc.entry_seq + 3 THEN 1 ELSE 0
    END                                                          AS retained_1yr,
    CASE WHEN mt.max_seq < mc.entry_seq + 6 THEN NULL
         WHEN o.has_t6 = 1 OR o.award_seq <= mc.entry_seq + 6 THEN 1 ELSE 0
    END                                                          AS retained_2yr,
    CASE WHEN mt.max_seq < mc.entry_seq + 9 THEN NULL
         WHEN o.has_t9 = 1 OR o.award_seq <= mc.entry_seq + 9 THEN 1 ELSE 0
    END                                                          AS retained_3yr,
    0                                                            AS retained_in_major_t1,
    NVL(o.earned_12cr, 0)                                        AS earned_12cr_flag,
    NVL(o.earned_24cr, 0)                                        AS earned_24cr_flag,
    CASE WHEN o.award_term IS NOT NULL THEN 1 ELSE 0 END         AS received_award_flag,
    NULL                                                         AS program_code,
    NULL                                                         AS program_name,
    NULL                                                         AS inst_entry_term,
    NULL                                                         AS terms_since_inst_entry,
    NULL                                                         AS program_entry_type,
    o.award_term                                                 AS first_award_term_id,
    o.award_degree                                               AS first_award_degree_code,
    o.award_major                                                AS first_award_major_code,
    (o.award_seq - mc.entry_seq)                                 AS time_to_award_terms,
    NULL                                                         AS inst_time_to_award_terms,
    -- ============================================================
    -- Graduation flags
    -- graduated_in_program: awarded in NF entry major (not a closed program)
    -- graduated_in_closed:  awarded in any closed program major
    -- ============================================================
    CASE
        WHEN o.award_term IS NOT NULL
            AND o.award_major = mc.major_code
            AND o.award_major NOT IN (SELECT major_code FROM program_codes)
        THEN 1 ELSE 0
    END                                                          AS graduated_in_program_flag,
    CASE
        WHEN o.award_term IS NOT NULL
            AND o.award_major IN (SELECT major_code FROM program_codes)
        THEN 1 ELSE 0
    END                                                          AS graduated_in_closed_flag,
    0                                                            AS matriculated_to_rscc_flag,
    0                                                            AS graduated_rscc_flag,
    -- ============================================================
    -- Current state fields
    -- ============================================================
    cm.current_term_id,
    CASE
        WHEN o.award_term IS NOT NULL
            THEN o.award_major
        ELSE cm.current_major_code
    END                                                          AS last_major_code,
    CASE
        WHEN o.award_term IS NOT NULL
            THEN F_STUDENT_GET_DESC('STVMAJR', o.award_major, 30)
        ELSE F_STUDENT_GET_DESC('STVMAJR', cm.current_major_code, 30)
    END                                                          AS last_major_desc,
    cm.currently_enrolled_flag,
    0                                                            AS enrolled_rscc_flag,
    CASE
        WHEN cm.currently_enrolled_flag = 1
            AND cm.current_major_code IN (SELECT major_code FROM program_codes)
        THEN 1 ELSE 0
    END                                                          AS enrolled_in_closed_flag,
    CASE
        WHEN o.award_term IS NOT NULL
            AND o.award_major = mc.major_code
            THEN 'Same Major'
        WHEN o.award_term IS NOT NULL
            THEN 'Changed Major'
        WHEN cm.current_major_code = mc.major_code
            THEN 'Same Major'
        ELSE 'Changed Major'
    END                                                          AS major_change_flag,
    0                                                            AS next_term_matriculation_flag,
    0                                                            AS graduated_other_closed_flag,
    0                                                            AS enrolled_other_closed_flag,
    NULL                                                         AS oc_gateway_flag,
    SYSDATE                                                      AS ExtractDate
FROM master_cohort mc
CROSS JOIN max_term mt
JOIN      all_outcomes o   ON  o.pidm  = mc.pidm
LEFT JOIN current_major cm ON cm.pidm  = mc.pidm
ORDER BY mc.cohort_entry_term_id, mc.student_id
