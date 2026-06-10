WITH
enr AS (
    SELECT
        sf.PIDM_A3      AS pidm,
        sf.TERM_CODE_A3 AS term_id,
        sf.TOT_CRHRS_A3 AS enrolled_crhrs
    FROM SFVRCRS sf
    WHERE sf.TOT_CRHRS_A3 > 0
    AND sf.TERM_CODE_A3 >= :Term
    AND sf.TERM_CODE_A3 <= F_RSCC_GET_TERM('TERM1')
),
id AS (
    SELECT
        spr.SPRIDEN_PIDM AS pidm,
        spr.SPRIDEN_ID   AS student_id
    FROM SPRIDEN spr
    WHERE spr.SPRIDEN_CHANGE_IND IS NULL
),
term_dim AS (
    SELECT
        t.STVTERM_CODE AS term_id,
        ROW_NUMBER() OVER (ORDER BY t.STVTERM_CODE) AS term_sequence,
        SUBSTR(t.STVTERM_CODE, 5, 2) AS term_suffix,
        CASE SUBSTR(t.STVTERM_CODE, 5, 2)
            WHEN '10' THEN 'Spring'
            WHEN '50' THEN 'Summer'
            WHEN '80' THEN 'Fall'
            ELSE 'Other'
        END AS term_type,
        CASE SUBSTR(t.STVTERM_CODE, 5, 2)
            WHEN '10' THEN
                SUBSTR(TO_CHAR(TO_NUMBER(SUBSTR(t.STVTERM_CODE,1,4)) - 1), 3, 2)
                || '-' || SUBSTR(t.STVTERM_CODE, 3, 2)
            WHEN '50' THEN
                SUBSTR(t.STVTERM_CODE, 3, 2)
                || '-' || TO_CHAR(TO_NUMBER(SUBSTR(t.STVTERM_CODE,1,4)) + 1 - 2000)
            WHEN '80' THEN
                SUBSTR(t.STVTERM_CODE, 3, 2)
                || '-' || TO_CHAR(TO_NUMBER(SUBSTR(t.STVTERM_CODE,1,4)) + 1 - 2000)
            ELSE SUBSTR(t.STVTERM_CODE, 1, 4)
        END AS academic_year,
        b.SOBPTRM_START_DATE AS term_start_date,
        b.SOBPTRM_END_DATE   AS term_end_date
    FROM STVTERM t
    LEFT JOIN SOBPTRM b
        ON b.SOBPTRM_TERM_CODE = t.STVTERM_CODE
        AND b.SOBPTRM_PTRM_CODE = '1'
),
sgb AS (
    SELECT
        e.pidm,
        e.term_id,
        s.SGBSTDN_STYP_CODE    AS stu_type,
        s.SGBSTDN_ADMT_CODE    AS admit_type,
        s.SGBSTDN_DEGC_CODE_1  AS degree_code,
        s.SGBSTDN_MAJR_CODE_1  AS major_code
    FROM enr e
    LEFT JOIN SGBSTDN s
        ON s.ROWID = F_GET_SGBSTDN_ROWID(e.pidm, e.term_id)
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
    WHERE g.SHRTGPA_LEVL_CODE = 'UG'
    AND g.SHRTGPA_GPA_TYPE_IND = 'I'
),
term_flags AS (
    SELECT
        e.pidm,
        i.student_id,
        e.term_id,
        td.term_suffix,
        s.admit_type,
        s.stu_type,
        s.degree_code,
        s.major_code,
        e.enrolled_crhrs,
        NVL(pc.prior_cum_hrs, 0) AS prior_cum_hrs,
        CASE WHEN s.admit_type = 'FR' AND s.stu_type = 'N' THEN 'NF' END AS flag_nf_n,
        CASE WHEN s.admit_type = 'FR' AND s.stu_type = 'B' THEN 'NF' END AS flag_nf_b,
        CASE WHEN s.admit_type IN ('DE','DM') AND NVL(pc.prior_cum_hrs,0) = 0 THEN 'DE' END AS flag_de,
        CASE WHEN s.admit_type IN ('T','T1') AND NVL(pc.prior_cum_hrs,0) < 12 AND td.term_suffix IN ('10','80') THEN 'TR' END AS flag_tr,
        CASE WHEN s.admit_type = 'SP' AND s.stu_type = 'S' THEN 'CT' END AS flag_ct,
        CASE WHEN s.admit_type = 'AA' AND td.term_suffix IN ('10','80') THEN 'AA' END AS flag_aa,
        CASE WHEN s.stu_type = 'R' AND NVL(pc.prior_cum_hrs,0) < 12 AND td.term_suffix IN ('10','80') THEN 'RS' END AS flag_rs,
        CASE
            WHEN s.admit_type IN ('UD','XT') THEN 1
            WHEN s.degree_code = 'NDUG' AND s.admit_type NOT IN ('DE','DM') THEN 1
            ELSE 0
        END AS excl_flag
    FROM enr e
    JOIN id i ON i.pidm = e.pidm
    JOIN term_dim td ON td.term_id = e.term_id
    LEFT JOIN sgb s ON s.pidm = e.pidm AND s.term_id = e.term_id
    LEFT JOIN prior_cum pc ON pc.pidm = e.pidm AND pc.term_id = e.term_id
),
nf_b_resolved AS (
    SELECT
        tf.pidm,
        tf.student_id,
        SUBSTR(tf.term_id, 1, 4) || '80' AS entry_term_id,
        'NF' AS cohort_type_code,
        tf.term_id AS trigger_term_id,
        ROW_NUMBER() OVER (PARTITION BY tf.pidm ORDER BY tf.term_id) AS rn
    FROM term_flags tf
    WHERE tf.flag_nf_b = 'NF'
    AND tf.excl_flag = 0
),
other_entries AS (
    SELECT
        tf.pidm,
        tf.student_id,
        tf.term_id AS entry_term_id,
        COALESCE(tf.flag_nf_n, tf.flag_de, tf.flag_tr, tf.flag_ct, tf.flag_aa, tf.flag_rs) AS cohort_type_code,
        tf.term_id AS trigger_term_id,
        ROW_NUMBER() OVER (
            PARTITION BY tf.pidm,
                COALESCE(tf.flag_nf_n, tf.flag_de, tf.flag_tr, tf.flag_ct, tf.flag_aa, tf.flag_rs)
            ORDER BY tf.term_id
        ) AS rn
    FROM term_flags tf
    WHERE tf.excl_flag = 0
    AND COALESCE(tf.flag_nf_n, tf.flag_de, tf.flag_tr, tf.flag_ct, tf.flag_aa, tf.flag_rs) IS NOT NULL
    AND NOT (tf.admit_type = 'FR' AND tf.stu_type = 'B')
),
all_entries AS (
    SELECT pidm, student_id, entry_term_id, cohort_type_code, trigger_term_id
    FROM nf_b_resolved WHERE rn = 1
    UNION ALL
    SELECT pidm, student_id, entry_term_id, cohort_type_code, trigger_term_id
    FROM other_entries WHERE rn = 1
),
entry_ranked AS (
    SELECT
        ae.*,
        ROW_NUMBER() OVER (PARTITION BY ae.pidm, ae.cohort_type_code ORDER BY ae.entry_term_id) AS cohort_instance,
        COUNT(*) OVER (PARTITION BY ae.pidm, ae.cohort_type_code) AS cohort_type_count
    FROM all_entries ae
),
cohort_entries AS (
    SELECT
        er.student_id,
        er.pidm,
        er.entry_term_id,
        er.cohort_type_code,
        er.trigger_term_id,
        er.cohort_instance,
        CASE WHEN er.cohort_type_count > 1 THEN 1 ELSE 0 END AS duplicate_cohort_flag,
        CASE
            WHEN er.cohort_type_code = 'NF' THEN 'New Freshman'
            WHEN er.cohort_type_code = 'DE' THEN 'Dual Enrollment'
            WHEN er.cohort_type_code = 'TR' THEN 'New Transfer'
            WHEN er.cohort_type_code = 'CT' THEN 'Certificate'
            WHEN er.cohort_type_code = 'AA' THEN 'Additional Degree'
            WHEN er.cohort_type_code = 'RS' THEN 'Readmit'
            ELSE 'Unknown'
        END AS cohort_type
    FROM entry_ranked er
),
entry_sgb AS (
    SELECT
        ce.pidm,
        ce.entry_term_id,
        s.SGBSTDN_STYP_CODE   AS stu_type,
        s.SGBSTDN_ADMT_CODE   AS admit_type,
        s.SGBSTDN_DEGC_CODE_1 AS degree_code,
        s.SGBSTDN_MAJR_CODE_1 AS major_code,
        s.SGBSTDN_RESD_CODE   AS residency_code
    FROM cohort_entries ce
    LEFT JOIN SGBSTDN s
        ON s.ROWID = F_GET_SGBSTDN_ROWID(ce.pidm, ce.entry_term_id)
),
pell AS (
    SELECT
        r.RPRATRM_PIDM   AS pidm,
        r.RPRATRM_PERIOD AS term_id,
        1                AS pell_flag
    FROM RPRATRM r
    WHERE r.RPRATRM_FUND_CODE = 'PELL'
),
cohort_snap AS (
    SELECT
        ce.student_id || '-' || ce.cohort_type_code || '-' || ce.entry_term_id AS cohort_id,
        ce.student_id,
        ce.pidm,
        ce.entry_term_id                AS cohort_entry_term_id,
        td.term_sequence                AS entry_term_sequence,
        td.term_start_date              AS entry_term_start_date,
        td.term_type                    AS entry_term_type,
        td.academic_year                AS entry_academic_year,
        ce.cohort_type_code,
        ce.cohort_type,
        ce.cohort_instance,
        ce.duplicate_cohort_flag,
        ce.trigger_term_id,
        es.admit_type                   AS cohort_admit_type,
        es.stu_type                     AS cohort_stu_type,
        es.degree_code                  AS cohort_degree_code,
        F_STUDENT_GET_DESC('STVDEGC', es.degree_code, 30) AS cohort_degree_desc,
        es.major_code                   AS cohort_major_code,
        F_STUDENT_GET_DESC('STVMAJR', es.major_code, 30)  AS cohort_major_desc,
        es.residency_code               AS cohort_residency_code,
        F_STUDENT_GET_DESC('STVRESD', es.residency_code, 30) AS cohort_residency_desc,
        CASE WHEN ee.enrolled_crhrs >= 12 THEN 'FT' ELSE 'PT' END AS cohort_ft_pt,
        ee.enrolled_crhrs               AS cohort_enrolled_crhrs,
        NVL(p.pell_flag, 0)             AS cohort_pell_flag,
        NVL(pc.prior_cum_hrs, 0)        AS prior_cum_hrs
    FROM cohort_entries ce
    JOIN term_dim td ON td.term_id = ce.entry_term_id
    LEFT JOIN entry_sgb es ON es.pidm = ce.pidm AND es.entry_term_id = ce.entry_term_id
    LEFT JOIN enr ee ON ee.pidm = ce.pidm AND ee.term_id = ce.entry_term_id
    LEFT JOIN pell p ON p.pidm = ce.pidm AND p.term_id = ce.entry_term_id
    LEFT JOIN prior_cum pc ON pc.pidm = ce.pidm AND pc.term_id = ce.entry_term_id
    WHERE ce.entry_term_id = '202380'
),
post_enr AS (
    SELECT
        sf.PIDM_A3      AS pidm,
        sf.TERM_CODE_A3 AS term_id,
        sf.TOT_CRHRS_A3 AS enrolled_crhrs
    FROM SFVRCRS sf
    WHERE sf.TOT_CRHRS_A3 > 0
),
cohort_terms AS (
    SELECT
        cs.cohort_id,
        cs.student_id,
        cs.pidm,
        cs.cohort_entry_term_id,
        cs.entry_term_sequence,
        cs.cohort_type_code,
        pe.term_id,
        td.term_sequence,
        pe.enrolled_crhrs,
        td.term_sequence - cs.entry_term_sequence AS term_index
    FROM cohort_snap cs
    JOIN post_enr pe ON pe.pidm = cs.pidm AND pe.term_id >= cs.cohort_entry_term_id
    JOIN term_dim td ON td.term_id = pe.term_id
),
max_term AS (
    SELECT MAX(term_sequence) AS max_seq FROM term_dim
),
spbpers AS (
    SELECT
        SPBPERS_PIDM       AS pidm,
        SPBPERS_BIRTH_DATE AS birth_date
    FROM SPBPERS
),
retention AS (
    SELECT
        cs.cohort_id,
        cs.student_id,
        cs.pidm,
        cs.cohort_entry_term_id,
        cs.entry_term_sequence,
        cs.entry_academic_year,
        cs.cohort_type_code,
        cs.cohort_type,
        cs.cohort_admit_type,
        cs.cohort_stu_type,
        cs.cohort_degree_code,
        cs.cohort_degree_desc,
        cs.cohort_major_code,
        cs.cohort_major_desc,
        cs.cohort_residency_code,
        cs.cohort_residency_desc,
        cs.cohort_ft_pt,
        cs.cohort_enrolled_crhrs,
        cs.cohort_pell_flag,
        cs.prior_cum_hrs,
        cs.cohort_instance,
        cs.duplicate_cohort_flag,
        mt.max_seq,
        CASE
            WHEN mt.max_seq < cs.entry_term_sequence + 1 THEN NULL
            WHEN MAX(CASE WHEN ct.term_sequence = cs.entry_term_sequence + 1 THEN 1 ELSE 0 END) = 1 THEN 1
            ELSE 0
        END AS retained_next_term,
        CASE
            WHEN mt.max_seq < cs.entry_term_sequence + 3 THEN NULL
            WHEN MAX(CASE WHEN ct.term_sequence BETWEEN cs.entry_term_sequence + 1 AND cs.entry_term_sequence + 3 THEN 1 ELSE 0 END) = 1 THEN 1
            ELSE 0
        END AS retained_1yr,
        CASE
            WHEN mt.max_seq < cs.entry_term_sequence + 6 THEN NULL
            WHEN MAX(CASE WHEN ct.term_sequence BETWEEN cs.entry_term_sequence + 1 AND cs.entry_term_sequence + 6 THEN 1 ELSE 0 END) = 1 THEN 1
            ELSE 0
        END AS retained_2yr,
        CASE
            WHEN mt.max_seq < cs.entry_term_sequence + 9 THEN NULL
            WHEN MAX(CASE WHEN ct.term_sequence BETWEEN cs.entry_term_sequence + 1 AND cs.entry_term_sequence + 9 THEN 1 ELSE 0 END) = 1 THEN 1
            ELSE 0
        END AS retained_3yr
    FROM cohort_snap cs
    LEFT JOIN cohort_terms ct ON ct.cohort_id = cs.cohort_id AND ct.term_index > 0
    CROSS JOIN max_term mt
    GROUP BY
        cs.cohort_id, cs.student_id, cs.pidm,
        cs.cohort_entry_term_id, cs.entry_term_sequence, cs.entry_academic_year,
        cs.cohort_type_code, cs.cohort_type, cs.cohort_admit_type, cs.cohort_stu_type,
        cs.cohort_degree_code, cs.cohort_degree_desc, cs.cohort_major_code, cs.cohort_major_desc,
        cs.cohort_residency_code, cs.cohort_residency_desc, cs.cohort_ft_pt,
        cs.cohort_enrolled_crhrs, cs.cohort_pell_flag, cs.prior_cum_hrs,
        cs.cohort_instance, cs.duplicate_cohort_flag, mt.max_seq
)
SELECT
    r.cohort_id,
    r.student_id,
    r.cohort_entry_term_id,
    r.entry_academic_year,
    r.cohort_type_code,
    r.cohort_type,
    r.cohort_admit_type,
    r.cohort_stu_type,
    r.cohort_degree_code,
    r.cohort_degree_desc,
    r.cohort_major_code,
    r.cohort_major_desc,
    r.cohort_residency_code,
    r.cohort_residency_desc,
    r.cohort_ft_pt,
    r.cohort_enrolled_crhrs,
    r.cohort_pell_flag,
    r.prior_cum_hrs,
    r.cohort_instance,
    r.duplicate_cohort_flag,
    r.retained_next_term,
    r.retained_1yr,
    r.retained_2yr,
    r.retained_3yr,
    TRUNC(MONTHS_BETWEEN(td_e.term_start_date,
        bp.birth_date) / 12)                        AS age_at_entry,
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
    END                                             AS age_group,
    SYSDATE                                         AS ExtractDate
FROM retention r
LEFT JOIN spbpers bp
    ON  bp.pidm = r.pidm
LEFT JOIN term_dim td_e
    ON  td_e.term_id = r.cohort_entry_term_id
ORDER BY r.student_id, r.cohort_entry_term_id
