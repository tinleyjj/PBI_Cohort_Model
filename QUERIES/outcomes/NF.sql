-- ==================================================
-- RPT-008-NF: outcomes_NF.csv
-- New Freshman cohort outcomes -- all terms from 202080
-- Grain: one row per student per cohort entry term
-- Output: outcomes_NF.csv via Argos SFTP
-- Refresh cadence: Per term (full rebuild)
--
-- Cohort rule: SORLCUR_ADMT_CODE = 'FR' (as-of term)
--   + SGBSTDN_STYP_CODE IN ('N','B').
-- Admission gate is SORLCUR (matches RPT-004 profile
--   StudentClass definition for First Time Freshman).
-- SGBSTDN provides stu_type and degree code only.
-- B students (summer starters) shift cohort_entry_term_id
--   to following Fall; entry_seq joins on shifted term
--   so retention window arithmetic is correct.
-- Structure mirrors outcomes_DE_DM for consistency.
-- ==================================================

WITH

term_dim AS (
    SELECT
        t.STVTERM_CODE                               AS term_id,
        ROW_NUMBER() OVER (ORDER BY t.STVTERM_CODE)  AS term_sequence,
        b.SOBPTRM_START_DATE                         AS term_start_date
    FROM STVTERM t
    LEFT JOIN SOBPTRM b
        ON  b.SOBPTRM_TERM_CODE = t.STVTERM_CODE
        AND b.SOBPTRM_PTRM_CODE = '1'
),

max_term AS (
    SELECT MAX(term_sequence) AS max_seq FROM term_dim
),

birth_dates AS (
    SELECT
        SPBPERS_PIDM    AS pidm,
        SPBPERS_BIRTH_DATE AS birth_date
    FROM SPBPERS
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
        MIN(shd.SHRDGMR_DEGC_CODE)                                      AS award_degree,
        MIN(shd.SHRDGMR_MAJR_CODE_1)                                    AS award_major
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
    LEFT JOIN SHRDGMR shd
        ON  shd.SHRDGMR_PIDM           = mc.pidm
        AND shd.SHRDGMR_DEGS_CODE      = 'AW'
        AND shd.SHRDGMR_TERM_CODE_GRAD >= mc.cohort_entry_term_id
    LEFT JOIN term_dim td_aw
        ON  td_aw.term_id = shd.SHRDGMR_TERM_CODE_GRAD
    GROUP BY mc.pidm
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
    END                                                          AS audit_error_type,
    mt.max_seq,
    CASE WHEN mt.max_seq < mc.entry_seq + 1 THEN NULL
         WHEN o.has_t1 = 1 OR o.award_seq <= mc.entry_seq + 1 THEN 1 ELSE 0 END AS retained_next_term,
    CASE WHEN mt.max_seq < mc.entry_seq + 3 THEN NULL
         WHEN o.has_t3 = 1 OR o.award_seq <= mc.entry_seq + 3 THEN 1 ELSE 0 END AS retained_1yr,
    CASE WHEN mt.max_seq < mc.entry_seq + 6 THEN NULL
         WHEN o.has_t6 = 1 OR o.award_seq <= mc.entry_seq + 6 THEN 1 ELSE 0 END AS retained_2yr,
    CASE WHEN mt.max_seq < mc.entry_seq + 9 THEN NULL
         WHEN o.has_t9 = 1 OR o.award_seq <= mc.entry_seq + 9 THEN 1 ELSE 0 END AS retained_3yr,
    0                                                            AS retained_in_major_t1,
    NVL(o.earned_12cr, 0)                                        AS earned_12cr_flag,
    NVL(o.earned_24cr, 0)                                        AS earned_24cr_flag,
    CASE WHEN o.award_term IS NOT NULL THEN 1 ELSE 0 END         AS received_award_flag,
    0                                                            AS graduated_in_major_flag,
    o.award_term                                                 AS first_award_term_id,
    o.award_degree                                               AS first_award_degree_code,
    o.award_major                                                AS first_award_major_code,
    (o.award_seq - mc.entry_seq)                                 AS time_to_award_terms,
    NULL                                                         AS inst_entry_term,
    NULL                                                         AS terms_since_inst_entry,
    sg2.SGBSTDN_FULL_PART_IND                                    AS full_part_ind,
    TRUNC(MONTHS_BETWEEN(td_entry.term_start_date,
        bp.birth_date) / 12)                                     AS age_at_entry,
    CASE
        WHEN TRUNC(MONTHS_BETWEEN(td_entry.term_start_date,
             bp.birth_date) / 12) < 18  THEN '0-17'
        WHEN TRUNC(MONTHS_BETWEEN(td_entry.term_start_date,
             bp.birth_date) / 12) <= 20 THEN '18-20'
        WHEN TRUNC(MONTHS_BETWEEN(td_entry.term_start_date,
             bp.birth_date) / 12) <= 24 THEN '21-24'
        WHEN TRUNC(MONTHS_BETWEEN(td_entry.term_start_date,
             bp.birth_date) / 12) <= 34 THEN '25-34'
        WHEN TRUNC(MONTHS_BETWEEN(td_entry.term_start_date,
             bp.birth_date) / 12) <= 49 THEN '35-49'
        WHEN TRUNC(MONTHS_BETWEEN(td_entry.term_start_date,
             bp.birth_date) / 12) <= 65 THEN '50-65'
        WHEN TRUNC(MONTHS_BETWEEN(td_entry.term_start_date,
             bp.birth_date) / 12) > 65  THEN '65+'
        ELSE NULL
    END                                                          AS age_group,
    SYSDATE                                                      AS ExtractDate
FROM master_cohort mc
CROSS JOIN max_term mt
JOIN all_outcomes o ON o.pidm = mc.pidm
LEFT JOIN birth_dates bp
    ON  bp.pidm = mc.pidm
LEFT JOIN SGBSTDN sg2
    ON  sg2.ROWID = F_GET_SGBSTDN_ROWID(mc.pidm, mc.cohort_entry_term_id)
LEFT JOIN term_dim td_entry
    ON  td_entry.term_id = mc.cohort_entry_term_id
ORDER BY mc.cohort_entry_term_id, mc.student_id
