-- ==================================================
-- RPT-008-DE_DM: outcomes_DE_DM.csv
-- DE / DM / DC combined outcomes -- all terms from 202080
-- Grain: one row per student per cohort entry term
-- Output: outcomes_DE_DM.csv via Argos SFTP
-- Refresh cadence: Per term (full rebuild)
-- Power BI: folder connector appends all outcomes_*.csv
--           files into a single 8_Outcomes table
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
        ON b.SOBPTRM_TERM_CODE = t.STVTERM_CODE
        AND b.SOBPTRM_PTRM_CODE = '1'
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
    AND g.SHRTGPA_GPA_TYPE_IND = 'I'
),

birth_dates AS (
    SELECT
        SPBPERS_PIDM       AS pidm,
        SPBPERS_BIRTH_DATE AS birth_date
    FROM SPBPERS
),

ft_term_counts AS (
    -- Full history FT term count per student per DE/DM admit code.
    -- No floor date -- required for accurate DM/DC/DE classification.
    -- One scan shared across all three cohort type classifications.
    SELECT
        sf.PIDM_A3                  AS pidm,
        sg2.SGBSTDN_ADMT_CODE       AS admit_code,
        COUNT(*)                    AS ft_term_count
    FROM SFVRCRS sf
    JOIN SGBSTDN sg2
        ON sg2.ROWID = F_GET_SGBSTDN_ROWID(sf.PIDM_A3, sf.TERM_CODE_A3)
    WHERE sf.TOT_CRHRS_A3          >= 12
    AND sg2.SGBSTDN_ADMT_CODE       IN ('DE','DM')
    GROUP BY sf.PIDM_A3, sg2.SGBSTDN_ADMT_CODE
),

cohort AS (
    -- Combined DE/DM/DC cohort.
    -- cohort_type_code is derived from the FT term count heuristic:
    --   DM  = DM admit + 1+ FT terms under DM
    --   DC  = DE admit + exactly 2 FT terms under DE
    --   DE  = DE admit + 0-1 FT terms under DE
    --         + DE admit + 3+ FT terms (DE-as-DM, flagged)
    --         + DM admit + 0 FT terms (misclassified, flagged)
    -- misclassified_dm_flag: DM admit never took FT load
    -- de_as_dm_flag: DE admit with DM-level FT term history
    SELECT
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
        ON spr.SPRIDEN_PIDM        = sf.PIDM_A3
        AND spr.SPRIDEN_CHANGE_IND IS NULL
    JOIN SGBSTDN sg
        ON sg.ROWID = F_GET_SGBSTDN_ROWID(sf.PIDM_A3, sf.TERM_CODE_A3)
    JOIN term_dim td
        ON td.term_id = sf.TERM_CODE_A3
    LEFT JOIN ft_term_counts ftc_dm
        ON ftc_dm.pidm       = sf.PIDM_A3
        AND ftc_dm.admit_code = 'DM'
    LEFT JOIN ft_term_counts ftc_de
        ON ftc_de.pidm       = sf.PIDM_A3
        AND ftc_de.admit_code = 'DE'
    LEFT JOIN prior_cum pc
        ON pc.pidm    = sf.PIDM_A3
        AND pc.term_id = sf.TERM_CODE_A3
    WHERE sf.TOT_CRHRS_A3   > 0
    AND sf.TERM_CODE_A3      >= '202080'
    AND sf.TERM_CODE_A3      <= F_RSCC_GET_TERM('TERM1')
    AND sg.SGBSTDN_ADMT_CODE  IN ('DE','DM')
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
        sf.PIDM_A3      AS pidm,
        sf.TERM_CODE_A3 AS term_id,
        sf.TOT_CRHRS_A3 AS enrolled_crhrs
    FROM SFVRCRS sf
    JOIN cohort c
        ON c.pidm = sf.PIDM_A3
    WHERE sf.TOT_CRHRS_A3 > 0
    AND sf.TERM_CODE_A3   <= F_RSCC_GET_TERM('TERM1')
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
        ON pe.pidm     = c.pidm
        AND pe.term_id >= c.cohort_entry_term_id
    JOIN term_dim td
        ON td.term_id = pe.term_id
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
    JOIN cohort c
        ON c.pidm = g.SHRTGPA_PIDM
    WHERE g.SHRTGPA_LEVL_CODE  = 'UG'
    AND g.SHRTGPA_GPA_TYPE_IND = 'I'
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
    JOIN cohort c
        ON c.pidm = shd.SHRDGMR_PIDM
    JOIN term_dim td
        ON td.term_id = shd.SHRDGMR_TERM_CODE_GRAD
    WHERE shd.SHRDGMR_DEGS_CODE       = 'AW'
    AND shd.SHRDGMR_TERM_CODE_GRAD   >= (
        SELECT MIN(c2.cohort_entry_term_id) FROM cohort c2
    )
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

        MAX(CASE
            WHEN ebt.cum_earned_hrs >= 12
             AND ebt.term_id <= (
                SELECT MIN(e2.term_id) FROM earned_by_term e2
                WHERE e2.pidm = c.pidm
                AND e2.cum_earned_hrs >= 12
                AND e2.term_id >= c.cohort_entry_term_id)
            THEN 1 ELSE 0
        END) AS earned_12cr_flag,

        MAX(CASE
            WHEN ebt.cum_earned_hrs >= 24
             AND ebt.term_id <= (
                SELECT MIN(e2.term_id) FROM earned_by_term e2
                WHERE e2.pidm = c.pidm
                AND e2.cum_earned_hrs >= 24
                AND e2.term_id >= c.cohort_entry_term_id)
            THEN 1 ELSE 0
        END) AS earned_24cr_flag,

        MAX(CASE WHEN fa.pidm IS NOT NULL THEN 1 ELSE 0 END)
            AS received_award_flag,
        MIN(fa.first_award_term_id)     AS first_award_term_id,
        MIN(fa.first_award_degree_code) AS first_award_degree_code,
        MIN(fa.first_award_major_code)  AS first_award_major_code,
        MIN(CASE WHEN fa.pidm IS NOT NULL
            THEN fa.first_award_term_sequence - c.entry_term_sequence
            ELSE NULL END)              AS time_to_award_terms

    FROM cohort c
    LEFT JOIN cohort_terms ct
        ON ct.cohort_id = c.cohort_id AND ct.term_index > 0
    LEFT JOIN earned_by_term ebt
        ON ebt.pidm    = c.pidm
        AND ebt.term_id >= c.cohort_entry_term_id
    LEFT JOIN first_award fa
        ON fa.pidm             = c.pidm
        AND fa.first_award_term_id >= c.cohort_entry_term_id
    GROUP BY
        c.cohort_id, c.student_id, c.pidm,
        c.cohort_entry_term_id, c.entry_term_sequence,
        c.cohort_type_code, c.admit_type, c.stu_type,
        c.prior_cum_hrs, c.misclassified_dm_flag, c.de_as_dm_flag
)

SELECT
    o.cohort_id,
    o.student_id,
    o.cohort_entry_term_id,
    o.cohort_type_code,
    o.admit_type,
    o.stu_type,
    o.prior_cum_hrs,
    o.misclassified_dm_flag,
    o.de_as_dm_flag,
    o.max_seq,
    o.retained_next_term,
    o.retained_1yr,
    o.retained_2yr,
    o.retained_3yr,
    o.earned_12cr_flag,
    o.earned_24cr_flag,
    o.received_award_flag,
    o.first_award_term_id,
    o.first_award_degree_code,
    o.first_award_major_code,
    o.time_to_award_terms,
    sg_e.SGBSTDN_FULL_PART_IND                 AS full_part_ind,
    TRUNC(MONTHS_BETWEEN(td_e.term_start_date,
        bp.birth_date) / 12)                   AS age_at_entry,
    CASE
        WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date,
             bp.birth_date) / 12) < 18  THEN '0-17'
        WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date,
             bp.birth_date) / 12) <= 20 THEN '18-20'
        WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date,
             bp.birth_date) / 12) <= 24 THEN '21-24'
        WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date,
             bp.birth_date) / 12) <= 34 THEN '25-34'
        WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date,
             bp.birth_date) / 12) <= 49 THEN '35-49'
        WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date,
             bp.birth_date) / 12) <= 65 THEN '50-65'
        WHEN TRUNC(MONTHS_BETWEEN(td_e.term_start_date,
             bp.birth_date) / 12) > 65  THEN '65+'
        ELSE NULL
    END                                        AS age_group,
    SYSDATE AS ExtractDate
FROM outcomes o
LEFT JOIN birth_dates bp
    ON  bp.pidm = o.pidm
LEFT JOIN term_dim td_e
    ON  td_e.term_id = o.cohort_entry_term_id
LEFT JOIN SGBSTDN sg_e
    ON  sg_e.ROWID = F_GET_SGBSTDN_ROWID(o.pidm, o.cohort_entry_term_id)
ORDER BY o.cohort_entry_term_id, o.student_id
