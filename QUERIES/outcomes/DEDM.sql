-- ==================================================
-- RPT-008-DE_DM: outcomes_DE_DM.csv
-- DE / DM / DC combined outcomes
-- Grain: one row per student per cohort entry term
-- Output: outcomes_DE_DM.csv via Argos SFTP
-- Refresh cadence: Per term (full rebuild)
-- ==================================================

WITH

term_dim AS (
    SELECT
        t.STVTERM_CODE                               AS term_id,
        ROW_NUMBER() OVER (ORDER BY t.STVTERM_CODE) AS term_sequence,
        b.SOBPTRM_START_DATE                        AS term_start_date,
        b.SOBPTRM_END_DATE                          AS term_end_date
    FROM STVTERM t
    LEFT JOIN SOBPTRM b
        ON b.SOBPTRM_TERM_CODE = t.STVTERM_CODE
        AND b.SOBPTRM_PTRM_CODE = '1'
),

current_fs_term AS (
    SELECT MAX(STVTERM_CODE) AS fs_term_id
    FROM STVTERM
    WHERE STVTERM_CODE <= F_RSCC_GET_TERM('TERM1')
    AND   SUBSTR(STVTERM_CODE, 5, 2) IN ('10', '80')
),

-- OPTIMIZATION: Narrow down the target PIDM pool early 
-- to prevent global scans on SHRTGPA and SFVRCRS history.
cohort_pidms AS (
    SELECT DISTINCT sf.PIDM_A3 AS pidm
    FROM SFVRCRS sf
    JOIN SGBSTDN sg ON sg.ROWID = F_GET_SGBSTDN_ROWID(sf.PIDM_A3, sf.TERM_CODE_A3)
    WHERE sf.TERM_CODE_A3 >= :Term
    AND   sf.TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
    AND   sf.TOT_CRHRS_A3 > 0
    AND   sg.SGBSTDN_ADMT_CODE IN ('DE','DM')
),

prior_cum AS (
    SELECT
        g.SHRTGPA_PIDM      AS pidm,
        g.SHRTGPA_TERM_CODE AS term_id,
        SUM(g.SHRTGPA_HOURS_EARNED) OVER (
            PARTITION BY g.SHRTGPA_PIDM
            ORDER BY g.SHRTGPA_TERM_CODE
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prior_cum_hrs
    FROM SHRTGPA g
    WHERE g.SHRTGPA_LEVL_CODE  = 'UG'
    AND   g.SHRTGPA_GPA_TYPE_IND = 'I'
    AND   g.SHRTGPA_PIDM IN (SELECT pidm FROM cohort_pidms)
),

ft_term_counts AS (
    SELECT
        sf.PIDM_A3             AS pidm,
        sg2.SGBSTDN_ADMT_CODE  AS admit_code,
        COUNT(*)               AS ft_term_count
    FROM SFVRCRS sf
    JOIN SGBSTDN sg2
        ON sg2.ROWID = F_GET_SGBSTDN_ROWID(sf.PIDM_A3, sf.TERM_CODE_A3)
    WHERE sf.TOT_CRHRS_A3         >= 12
    AND   sg2.SGBSTDN_ADMT_CODE    IN ('DE','DM')
    AND   sf.PIDM_A3 IN (SELECT pidm FROM cohort_pidms)
    GROUP BY sf.PIDM_A3, sg2.SGBSTDN_ADMT_CODE
),

cohort AS (
    -- Added MATERIALIZE hint to force Oracle to write this baseline once to temporary memory
    SELECT /*+ MATERIALIZE */
        spr.SPRIDEN_ID
            || '-'
            || CASE
                   WHEN sg.SGBSTDN_ADMT_CODE = 'DM'
                    AND NVL(ftc_dm.ft_term_count, 0) >= 1  THEN 'DM'
                   WHEN sg.SGBSTDN_ADMT_CODE = 'DE'
                    AND NVL(ftc_de.ft_term_count, 0) = 2   THEN 'DC'
                   ELSE 'DE'
               END
            || '-'
            || MIN(sf.TERM_CODE_A3)         AS cohort_id,
        spr.SPRIDEN_ID                      AS student_id,
        sf.PIDM_A3                          AS pidm,
        MIN(sf.TERM_CODE_A3)                AS cohort_entry_term_id,
        MIN(td.term_sequence)               AS entry_term_sequence,
        sg.SGBSTDN_ADMT_CODE                AS admit_type,
        sg.SGBSTDN_STYP_CODE                AS stu_type,
        NVL(pc.prior_cum_hrs, 0)            AS prior_cum_hrs,
        CASE
            WHEN sg.SGBSTDN_ADMT_CODE = 'DM'
             AND NVL(ftc_dm.ft_term_count, 0) >= 1  THEN 'DM'
            WHEN sg.SGBSTDN_ADMT_CODE = 'DE'
             AND NVL(ftc_de.ft_term_count, 0) = 2   THEN 'DC'
            ELSE 'DE'
        END                                 AS cohort_type_code,
        CASE
            WHEN sg.SGBSTDN_ADMT_CODE = 'DM'
             AND NVL(ftc_dm.ft_term_count, 0) = 0
            THEN 1 ELSE 0
        END                                 AS misclassified_dm_flag,
        CASE
            WHEN sg.SGBSTDN_ADMT_CODE = 'DE'
             AND NVL(ftc_de.ft_term_count, 0) >= 3
            THEN 1 ELSE 0
        END                                 AS de_as_dm_flag
    FROM SFVRCRS sf
    JOIN SPRIDEN spr
        ON  spr.SPRIDEN_PIDM       = sf.PIDM_A3
        AND spr.SPRIDEN_CHANGE_IND IS NULL
    JOIN SGBSTDN sg
        ON  sg.ROWID = F_GET_SGBSTDN_ROWID(sf.PIDM_A3, sf.TERM_CODE_A3)
    JOIN term_dim td
        ON  td.term_id = sf.TERM_CODE_A3
    LEFT JOIN ft_term_counts ftc_dm
        ON  ftc_dm.pidm       = sf.PIDM_A3
        AND ftc_dm.admit_code  = 'DM'
    LEFT JOIN ft_term_counts ftc_de
        ON  ftc_de.pidm       = sf.PIDM_A3
        AND ftc_de.admit_code  = 'DE'
    LEFT JOIN prior_cum pc
        ON  pc.pidm    = sf.PIDM_A3
        AND pc.term_id = sf.TERM_CODE_A3
    WHERE sf.TOT_CRHRS_A3   > 0
    AND   sf.TERM_CODE_A3  >= :Term
    AND   sf.TERM_CODE_A3  <= F_RSCC_GET_TERM('TERM1')
    AND   sg.SGBSTDN_ADMT_CODE IN ('DE','DM')
    GROUP BY
        spr.SPRIDEN_ID,
        sf.PIDM_A3,
        sg.SGBSTDN_ADMT_CODE,
        sg.SGBSTDN_STYP_CODE,
        NVL(pc.prior_cum_hrs, 0),
        CASE WHEN sg.SGBSTDN_ADMT_CODE = 'DM'
              AND NVL(ftc_dm.ft_term_count, 0) >= 1 THEN 'DM'
             WHEN sg.SGBSTDN_ADMT_CODE = 'DE'
              AND NVL(ftc_de.ft_term_count, 0) = 2  THEN 'DC'
             ELSE 'DE' END,
        CASE WHEN sg.SGBSTDN_ADMT_CODE = 'DM'
              AND NVL(ftc_dm.ft_term_count, 0) = 0
             THEN 1 ELSE 0 END,
        CASE WHEN sg.SGBSTDN_ADMT_CODE = 'DE'
              AND NVL(ftc_de.ft_term_count, 0) >= 3
             THEN 1 ELSE 0 END
),

post_enr AS (
    SELECT
        sf.PIDM_A3              AS pidm,
        sf.TERM_CODE_A3         AS term_id,
        sf.TOT_CRHRS_A3         AS enrolled_crhrs,
        sg.SGBSTDN_ADMT_CODE    AS admt_code
    FROM SFVRCRS sf
    JOIN cohort c
        ON  c.pidm = sf.PIDM_A3
    LEFT JOIN SGBSTDN sg
        ON  sg.ROWID = F_GET_SGBSTDN_ROWID(sf.PIDM_A3, sf.TERM_CODE_A3)
    WHERE sf.TOT_CRHRS_A3 > 0
    AND   sf.TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
),

cohort_terms AS (
    SELECT
        c.cohort_id,
        c.pidm,
        c.entry_term_sequence,
        pe.term_id,
        td.term_sequence,
        td.term_sequence - c.entry_term_sequence AS term_index
    FROM cohort c
    JOIN post_enr pe
        ON  pe.pidm    = c.pidm
        AND pe.term_id >= c.cohort_entry_term_id
    JOIN term_dim td
        ON  td.term_id = pe.term_id
),

earned_by_term AS (
    SELECT
        g.SHRTGPA_PIDM         AS pidm,
        g.SHRTGPA_TERM_CODE    AS term_id,
        g.SHRTGPA_HOURS_EARNED AS earned_hrs,
        SUM(g.SHRTGPA_HOURS_EARNED) OVER (
            PARTITION BY g.SHRTGPA_PIDM
            ORDER BY g.SHRTGPA_TERM_CODE
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cum_earned_hrs
    FROM SHRTGPA g
    WHERE g.SHRTGPA_LEVL_CODE  = 'UG'
    AND   g.SHRTGPA_GPA_TYPE_IND = 'I'
    AND   g.SHRTGPA_PIDM IN (SELECT pidm FROM cohort_pidms)
),

awards AS (
    SELECT
        shd.SHRDGMR_PIDM           AS pidm,
        shd.SHRDGMR_TERM_CODE_GRAD AS award_term_id,
        shd.SHRDGMR_DEGC_CODE      AS degree_code,
        shd.SHRDGMR_MAJR_CODE_1    AS major_code,
        td.term_sequence           AS award_term_sequence,
        ROW_NUMBER() OVER (
            PARTITION BY shd.SHRDGMR_PIDM
            ORDER BY td.term_sequence ASC
        ) AS award_seq
    FROM SHRDGMR shd
    JOIN term_dim td
        ON  td.term_id = shd.SHRDGMR_TERM_CODE_GRAD
    WHERE shd.SHRDGMR_DEGS_CODE       = 'AW'
    AND   shd.SHRDGMR_TERM_CODE_GRAD >= :Term
    AND   shd.SHRDGMR_PIDM IN (SELECT pidm FROM cohort_pidms)
),

first_award AS (
    SELECT
        pidm,
        award_term_id       AS first_award_term_id,
        award_term_sequence AS first_award_term_sequence,
        degree_code         AS first_award_degree_code,
        major_code          AS first_award_major_code
    FROM awards
    WHERE award_seq = 1
),

outcomes AS (
    SELECT
        c.cohort_id,
        c.student_id,
        c.pidm,
        c.cohort_entry_term_id,
        c.entry_term_sequence,
        c.cohort_type_code,
        c.admit_type,
        c.stu_type,
        c.prior_cum_hrs,
        c.misclassified_dm_flag,
        c.de_as_dm_flag,
        (SELECT MAX(td2.term_sequence) FROM term_dim td2) AS max_seq,

        CASE
            WHEN (SELECT MAX(td2.term_sequence) FROM term_dim td2)
                 < c.entry_term_sequence + 1
            THEN NULL
            WHEN MAX(CASE WHEN ct.term_sequence = c.entry_term_sequence + 1
                          THEN 1 ELSE 0 END) = 1
              OR MIN(CASE WHEN fa.pidm IS NOT NULL
                          THEN fa.first_award_term_sequence
                          ELSE NULL END) <= c.entry_term_sequence + 1
            THEN 1 ELSE 0
        END AS retained_next_term,

        CASE
            WHEN (SELECT MAX(td2.term_sequence) FROM term_dim td2)
                 < c.entry_term_sequence + 3
            THEN NULL
            WHEN MAX(CASE WHEN ct.term_sequence = c.entry_term_sequence + 3
                          THEN 1 ELSE 0 END) = 1
              OR MIN(CASE WHEN fa.pidm IS NOT NULL
                          THEN fa.first_award_term_sequence
                          ELSE NULL END) <= c.entry_term_sequence + 3
            THEN 1 ELSE 0
        END AS retained_1yr,

        CASE
            WHEN (SELECT MAX(td2.term_sequence) FROM term_dim td2)
                 < c.entry_term_sequence + 6
            THEN NULL
            WHEN MAX(CASE WHEN ct.term_sequence = c.entry_term_sequence + 6
                          THEN 1 ELSE 0 END) = 1
              OR MIN(CASE WHEN fa.pidm IS NOT NULL
                          THEN fa.first_award_term_sequence
                          ELSE NULL END) <= c.entry_term_sequence + 6
            THEN 1 ELSE 0
        END AS retained_2yr,

        CASE
            WHEN (SELECT MAX(td2.term_sequence) FROM term_dim td2)
                 < c.entry_term_sequence + 9
            THEN NULL
            WHEN MAX(CASE WHEN ct.term_sequence = c.entry_term_sequence + 9
                          THEN 1 ELSE 0 END) = 1
              OR MIN(CASE WHEN fa.pidm IS NOT NULL
                          THEN fa.first_award_term_sequence
                          ELSE NULL END) <= c.entry_term_sequence + 9
            THEN 1 ELSE 0
        END AS retained_3yr,

        -- OPTIMIZATION: Replaced the destructive correlated scalar subquery 
        -- with standard, set-based conditional aggregation.
        MAX(CASE
            WHEN ebt.term_id >= c.cohort_entry_term_id AND ebt.cum_earned_hrs >= 12
            THEN 1 ELSE 0
        END) AS earned_12cr_flag,

        MAX(CASE
            WHEN ebt.term_id >= c.cohort_entry_term_id AND ebt.cum_earned_hrs >= 24
            THEN 1 ELSE 0
        END) AS earned_24cr_flag,

        MAX(CASE WHEN fa.pidm IS NOT NULL THEN 1 ELSE 0 END) AS received_award_flag,
        MIN(fa.first_award_term_id)     AS first_award_term_id,
        MIN(fa.first_award_degree_code) AS first_award_degree_code,
        MIN(fa.first_award_major_code)  AS first_award_major_code,
        MIN(CASE WHEN fa.pidm IS NOT NULL
            THEN fa.first_award_term_sequence - c.entry_term_sequence
            ELSE NULL END)              AS time_to_award_terms

    FROM cohort c
    LEFT JOIN cohort_terms ct
        ON  ct.cohort_id  = c.cohort_id AND ct.term_index > 0
    LEFT JOIN earned_by_term ebt
        ON  ebt.pidm      = c.pidm
        AND ebt.term_id  >= c.cohort_entry_term_id
    LEFT JOIN first_award fa
        ON  fa.pidm             = c.pidm
        AND fa.first_award_term_id >= c.cohort_entry_term_id
    GROUP BY
        c.cohort_id, c.student_id, c.pidm,
        c.cohort_entry_term_id, c.entry_term_sequence,
        c.cohort_type_code, c.admit_type, c.stu_type,
        c.prior_cum_hrs, c.misclassified_dm_flag, c.de_as_dm_flag
),

sorlcur_at_term AS (
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
        AND   SORLCUR_PIDM IN (SELECT pidm FROM cohort_pidms)
    )
    WHERE rn = 1
),

-- OPTIMIZATION: Pulled out sequence evaluation into its own consolidated layout 
-- to eliminate the redundant inline scan against cohort and post_enr.
last_dedm_term AS (
    SELECT
        c.cohort_id,
        c.pidm,
        MAX(pe.term_id)         AS last_dedm_term_id,
        MAX(td.term_sequence)   AS last_dedm_seq,
        CASE
            WHEN SUBSTR(MAX(pe.term_id), 5, 2) = '80'
            THEN TO_CHAR(TO_NUMBER(SUBSTR(MAX(pe.term_id), 1, 4)) + 1) || '10'
            ELSE SUBSTR(MAX(pe.term_id), 1, 4) || '80'
        END                     AS next_fs_1,
        CASE
            WHEN SUBSTR(MAX(pe.term_id), 5, 2) = '80'
            THEN TO_CHAR(TO_NUMBER(SUBSTR(MAX(pe.term_id), 1, 4)) + 1) || '80'
            ELSE TO_CHAR(TO_NUMBER(SUBSTR(MAX(pe.term_id), 1, 4)) + 1) || '10'
        END                     AS next_fs_2
    FROM cohort c
    JOIN post_enr pe
        ON  pe.pidm      = c.pidm
        AND pe.admt_code IN ('DE', 'DM', 'JE', 'AT')
    JOIN term_dim td
        ON  td.term_id = pe.term_id
    GROUP BY c.cohort_id, c.pidm
),

matriculation AS (
    SELECT
        c.cohort_id,
        MIN(pe.term_id)         AS first_rscc_term_id,
        MIN(td.term_sequence)   AS first_rscc_term_seq
    FROM cohort c
    JOIN post_enr pe
        ON  pe.pidm    = c.pidm
        AND pe.term_id > c.cohort_entry_term_id
        AND NVL(pe.admt_code, 'XX') NOT IN ('DE', 'DM', 'JE', 'AT')
    JOIN term_dim td
        ON  td.term_id = pe.term_id
    JOIN sorlcur_at_term sat
        ON  sat.pidm       = pe.pidm
        AND sat.term_id    = pe.term_id
        AND sat.major_code != 'NDUG'
    JOIN last_dedm_term ldt
        ON  ldt.cohort_id  = c.cohort_id
        AND td.term_sequence  <= ldt.last_dedm_seq + 4
    GROUP BY c.cohort_id
),

student_max_term AS (
    SELECT
        c.cohort_id,
        c.pidm,
        MAX(pe.term_id)         AS current_term_id,
        CASE
            WHEN SUM(CASE
                WHEN pe.term_id      = (SELECT fs_term_id FROM current_fs_term)
                     AND pe.enrolled_crhrs > 0 THEN 1 ELSE 0
            END) > 0
            THEN 1 ELSE 0
        END                     AS currently_enrolled_flag,
        MAX(CASE
            WHEN pe.term_id      = F_RSCC_GET_TERM('TERM1')
                AND pe.enrolled_crhrs > 0
                AND NVL(pe.admt_code, 'XX') NOT IN ('DE', 'DM', 'JE', 'AT')
            THEN 1 ELSE 0
        END)                    AS enrolled_rscc_flag
    FROM cohort c
    LEFT JOIN post_enr pe
        ON  pe.pidm    = c.pidm
        AND pe.term_id > c.cohort_entry_term_id
    GROUP BY c.cohort_id, c.pidm
),

current_major AS (
    SELECT
        smt.cohort_id,
        smt.current_term_id,
        smt.currently_enrolled_flag,
        smt.enrolled_rscc_flag,
        COALESCE(sat.major_code, 'NDUG')    AS current_major_code
    FROM student_max_term smt
    LEFT JOIN sorlcur_at_term sat
        ON  sat.pidm    = smt.pidm
        AND sat.term_id = smt.current_term_id
),

next_term_mat AS (
    SELECT
        ldt.cohort_id,
        MAX(CASE
            WHEN pe.term_id IN (ldt.next_fs_1, ldt.next_fs_2)
                AND NVL(pe.admt_code, 'XX') NOT IN ('DE', 'DM', 'JE', 'AT')
                AND pe.enrolled_crhrs > 0
            THEN 1 ELSE 0
        END)                    AS next_term_matriculation_flag
    FROM last_dedm_term ldt
    LEFT JOIN post_enr pe
        ON  pe.pidm    = ldt.pidm
        AND pe.term_id IN (ldt.next_fs_1, ldt.next_fs_2)
    GROUP BY ldt.cohort_id
)

SELECT
    o.cohort_id,
    o.student_id,
    o.cohort_entry_term_id,
    o.cohort_type_code,
    o.admit_type,
    o.stu_type,
    'NDUG'                                      AS cohort_major_code,
    'Non-Degree Undergraduate'                  AS cohort_major_desc,
    NULL                                        AS cohort_concentration_code,
    NULL                                        AS cohort_concentration_desc,
    o.prior_cum_hrs,
    NULL                                        AS entry_term_crhrs,
    NULL                                        AS readmit_event_sequence,
    CASE
        WHEN o.misclassified_dm_flag = 1 THEN 'Misclassified DM'
        WHEN o.de_as_dm_flag         = 1 THEN 'DE as DM'
        ELSE 'Clean'
    END                                         AS error_flag,
    o.misclassified_dm_flag,
    o.de_as_dm_flag,
    o.max_seq,
    o.retained_next_term,
    o.retained_1yr,
    o.retained_2yr,
    o.retained_3yr,
    0                                           AS retained_in_major_t1,
    o.earned_12cr_flag,
    o.earned_24cr_flag,
    o.received_award_flag,
    NULL                                        AS program_code,
    NULL                                        AS program_name,
    NULL                                        AS inst_entry_term,
    NULL                                        AS terms_since_inst_entry,
    NULL                                        AS program_entry_type,
    o.first_award_term_id,
    o.first_award_degree_code,
    o.first_award_major_code,
    o.time_to_award_terms,
    NULL                                        AS inst_time_to_award_terms,
    CASE
        WHEN o.received_award_flag = 1
            AND (mat.first_rscc_term_id IS NULL
                 OR o.first_award_term_id < mat.first_rscc_term_id)
        THEN 1 ELSE 0
    END                                         AS graduated_in_program_flag,
    0                                           AS graduated_in_closed_flag,
    CASE
        WHEN mat.first_rscc_term_id IS NOT NULL THEN 1 ELSE 0
    END                                         AS matriculated_to_rscc_flag,
    CASE
        WHEN o.received_award_flag = 1
            AND mat.first_rscc_term_id IS NOT NULL
            AND o.first_award_term_id >= mat.first_rscc_term_id
        THEN 1 ELSE 0
    END                                         AS graduated_rscc_flag,
    cm.current_term_id,
    CASE
        WHEN o.received_award_flag = 1
            THEN o.first_award_major_code
        ELSE cm.current_major_code
    END                                         AS last_major_code,
    CASE
        WHEN o.received_award_flag = 1
            THEN F_STUDENT_GET_DESC('STVMAJR', o.first_award_major_code, 30)
        ELSE F_STUDENT_GET_DESC('STVMAJR', cm.current_major_code, 30)
    END                                         AS last_major_desc,
    cm.currently_enrolled_flag,
    cm.enrolled_rscc_flag,
    0                                           AS enrolled_in_closed_flag,
    CASE
        WHEN cm.current_major_code = 'NDUG'
            THEN 'Same Major'
        ELSE 'Changed Major'
    END                                         AS major_change_flag,
    NVL(ntm.next_term_matriculation_flag, 0)    AS next_term_matriculation_flag,
    0                                           AS graduated_other_closed_flag,
    0                                           AS enrolled_other_closed_flag,
    NULL                                        AS oc_gateway_flag,
    SYSDATE                                     AS ExtractDate
FROM outcomes o
LEFT JOIN matriculation mat     ON  mat.cohort_id = o.cohort_id
LEFT JOIN current_major cm      ON  cm.cohort_id  = o.cohort_id
LEFT JOIN next_term_mat ntm     ON  ntm.cohort_id = o.cohort_id
ORDER BY o.cohort_entry_term_id, o.student_id
