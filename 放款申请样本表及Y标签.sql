SET spark.sql.session.timeZone = Australia/Sydney;

DROP TABLE IF EXISTS model.tmp_eliam_wagego_param_obs_date;
CREATE TABLE model.tmp_eliam_wagego_param_obs_date AS
SELECT MAX(TO_DATE(dt)) AS obs_dt
FROM edw_ewa.dwb_asset_debt_dtl_snp
;

DROP TABLE IF EXISTS model.tmp_eliam_wagego_stg_debt_snp;
CREATE TABLE model.tmp_eliam_wagego_stg_debt_snp AS
WITH src AS (
    SELECT
         d.listing_id
        ,d.user_id
        ,TO_DATE(d.dt)                                        AS stat_date
        ,CAST(d.init_due_date AS DATE)                        AS init_due_date
        ,CAST(d.period_no AS INT)                             AS period_no
        ,CAST(d.user_actual_repay_time AS TIMESTAMP)          AS user_actual_repay_time
        ,CAST(d.debt_status AS INT)                           AS debt_status
        ,CAST(d.hist_overdue_days AS INT)                     AS hist_overdue_days
        ,CAST(d.current_overdue_days AS INT)                  AS current_overdue_days
        ,CAST(d.principal AS DOUBLE)                          AS principal
        ,CAST(d.repay_amount AS DOUBLE)                       AS repay_amount
        ,CAST(d.owing_amount AS DOUBLE)                       AS owing_amount
        ,CAST(d.owing_principal AS DOUBLE)                    AS owing_principal
    FROM edw_ewa.dwb_asset_debt_dtl_snp d
    CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
    WHERE TO_DATE(d.dt) <= p.obs_dt
      AND TO_DATE(d.dt) >= (
          SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
          FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
          WHERE CAST(a.isactive AS INT) = 1
      )
),
agg AS (
    SELECT
         listing_id
        ,MAX(user_id)                                         AS user_id
        ,stat_date
        ,MIN(init_due_date)                                   AS init_due_date
        ,MAX(CASE WHEN period_no = 1 THEN user_actual_repay_time END) AS first_repay_time
        ,CASE WHEN COUNT(*) = SUM(CASE WHEN debt_status = 2 THEN 1 ELSE 0 END) THEN MAX(user_actual_repay_time) END AS user_actual_repay_time
        ,MAX(CASE debt_status WHEN 4 THEN 3 WHEN 1 THEN 2 WHEN 2 THEN 1 ELSE 0 END) AS status_priority
        ,MAX(debt_status)                                     AS max_debt_status
        ,MAX(hist_overdue_days)                               AS hist_overdue_days
        ,MAX(current_overdue_days)                            AS current_overdue_days
        ,SUM(principal)                                       AS principal
        ,SUM(repay_amount)                                    AS repay_amount
        ,SUM(owing_amount)                                    AS owing_amount
        ,SUM(owing_principal)                                 AS owing_principal
    FROM src
    GROUP BY listing_id, stat_date
)
SELECT
     listing_id
    ,user_id
    ,stat_date
    ,init_due_date
    ,first_repay_time
    ,user_actual_repay_time
    ,CASE status_priority WHEN 3 THEN 4 WHEN 2 THEN 1 WHEN 1 THEN 2 ELSE max_debt_status END AS debt_status
    ,CASE status_priority WHEN 3 THEN '逾期中' WHEN 2 THEN '未结清' WHEN 1 THEN '已结清' ELSE CAST(max_debt_status AS STRING) END AS debt_status_desc
    ,hist_overdue_days
    ,current_overdue_days
    ,principal
    ,repay_amount
    ,owing_amount
    ,owing_principal
FROM agg
;

DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_apply_label;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_apply_label AS
WITH apply AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,a.status                                             AS apply_status
        ,CAST(a.inserttime AS TIMESTAMP)                      AS apply_time
        ,CAST(a.apply_disburse_time AS TIMESTAMP)             AS apply_disburse_time
        ,ROW_NUMBER() OVER (PARTITION BY a.user_id ORDER BY CAST(a.inserttime AS TIMESTAMP), a.loan_no) AS apply_seq
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
),
ranked AS (
    SELECT
         loan_no
        ,ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY apply_disburse_time ASC NULLS LAST, loan_no) AS application_rank
    FROM apply
    WHERE apply_status = 'DISBURSE_SUCCESS'
),
event AS (
    SELECT
         t.flow_id                                            AS loan_no
        ,CAST(t.application_id AS STRING)                     AS application_id
        ,GET_JSON_OBJECT(t.params, '$.appId')                 AS app_id
        ,CAST(t.inserttime AS TIMESTAMP)                      AS strategy_time
        ,CAST(t.retry_count AS INT)                           AS retry_count
    FROM (
        SELECT
             e.flow_id
            ,e.application_id
            ,e.params
            ,e.inserttime
            ,e.retry_count
            ,ROW_NUMBER() OVER (PARTITION BY e.flow_id ORDER BY CAST(e.updatetime AS TIMESTAMP) DESC NULLS LAST, CAST(e.inserttime AS TIMESTAMP) DESC NULLS LAST) AS rn
        FROM ods_ewa.aus_ewa_risk_risk_event_task e
        WHERE CAST(e.is_active AS INT) = 1
          AND CAST(e.biz_id AS STRING) = '20050'
          AND e.flow_id LIKE 'LN%'
    ) t
    WHERE t.rn = 1
),
stamp AS (
    SELECT
         a.borrower_id                                        AS user_id
        ,CAST(a.inserttime AS TIMESTAMP)                      AS stamp_time
        ,a.flow_no                                            AS stamp_flow_id
        ,CAST(a.id AS BIGINT)                                 AS stamp_id
        ,1                                                    AS source_priority
    FROM ods_ewa.aus_listing_tb_loan_limit_apply a
    WHERE CAST(a.isactive AS INT) = 1
      AND CAST(a.biz_type AS INT) = 400
    UNION ALL
    SELECT
         e.user_id
        ,CAST(e.inserttime AS TIMESTAMP)
        ,e.flow_id
        ,CAST(e.id AS BIGINT)
        ,2
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
stamp_matched AS (
    SELECT
         t.loan_no
        ,t.stamp_time
        ,t.stamp_flow_id
    FROM (
        SELECT
             a.loan_no
            ,s.stamp_time
            ,s.stamp_flow_id
            ,ROW_NUMBER() OVER (PARTITION BY a.loan_no ORDER BY s.source_priority, s.stamp_time DESC, s.stamp_id DESC) AS rn
        FROM apply a
        JOIN stamp s
          ON a.user_id = s.user_id
         AND s.stamp_time <= a.apply_time
    ) t
    WHERE t.rn = 1
),
loan_apply AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,e.application_id
        ,e.app_id
        ,a.listing_id
        ,a.apply_status
        ,CASE a.apply_status
             WHEN 'DISBURSE_SUCCESS' THEN '放款成功'  WHEN 'DISBURSE'       THEN '放款中'
             WHEN 'DISBURSE_FAILED'  THEN '放款失败'  WHEN 'AUDIT'          THEN '审核中'
             WHEN 'AUDIT_APPROVED'   THEN '审核通过'  WHEN 'AUDIT_REJECTED' THEN '审核拒绝'
             WHEN 'EXPIRED'          THEN '已过期'    WHEN 'INFO_CHANGED'   THEN '信息变更'
             ELSE a.apply_status
         END                                                      AS apply_status_desc
        ,CASE WHEN a.apply_status = 'DISBURSE_SUCCESS' THEN 1 ELSE 0 END AS is_disburse_success
        ,CASE WHEN a.apply_status = 'AUDIT_REJECTED'   THEN 1 ELSE 0 END AS is_reject
        ,CASE WHEN a.apply_status = 'EXPIRED'          THEN 1 ELSE 0 END AS is_expired
        ,CASE WHEN a.apply_status = 'DISBURSE_FAILED'  THEN 1 ELSE 0 END AS is_disburse_failed
        ,a.apply_time
        ,TO_DATE(a.apply_time)                                    AS apply_date
        ,DATE_FORMAT(a.apply_time, 'yyyy-MM')                     AS apply_month
        ,CASE WHEN a.apply_status = 'DISBURSE_SUCCESS' THEN a.apply_disburse_time END AS disburse_time
        ,a.apply_seq
        ,r.application_rank
        ,e.strategy_time
        ,e.retry_count
        ,sm.stamp_time
        ,sm.stamp_flow_id
    FROM apply a
    LEFT JOIN event e
      ON a.loan_no = e.loan_no
    LEFT JOIN ranked r
      ON a.loan_no = r.loan_no
    LEFT JOIN stamp_matched sm
      ON a.loan_no = sm.loan_no
),
latest AS (
    SELECT
         a.*
        ,CAST(l.real_amount AS DOUBLE)                        AS real_amount
        ,CAST(l.apply_amount AS DOUBLE)                       AS apply_amount
        ,CAST(l.interest AS DOUBLE)                           AS interest
        ,CAST(l.service_fee AS DOUBLE)                        AS service_fee
        ,CAST(l.term_quantity AS INT)                         AS term_quantity
        ,l.term_unit
        ,l.total_period
        ,CAST(l.is_deal AS INT)                               AS is_deal
        ,CAST(l.withdraw_time AS TIMESTAMP)                   AS withdraw_time
        ,CAST(l.list_due_date AS DATE)                        AS list_due_date
        ,s.listing_id                                         AS debt_listing_id
        ,s.init_due_date
        ,CASE WHEN s.init_due_date IS NOT NULL THEN DATE_ADD(s.init_due_date, 31) END AS label_obs_dt
        ,s.first_repay_time
        ,s.user_actual_repay_time
        ,s.debt_status
        ,s.debt_status_desc
        ,s.hist_overdue_days
        ,s.current_overdue_days
        ,CASE WHEN a.is_disburse_success = 1
              THEN COALESCE(NULLIF(CAST(l.real_amount AS DOUBLE), 0), s.principal) END AS principal
        ,s.repay_amount
        ,s.owing_amount
        ,p.obs_dt
        ,CASE WHEN a.is_disburse_success = 1 AND CAST(l.is_deal AS INT) = 1 AND s.listing_id IS NOT NULL
               AND DATE_ADD(s.init_due_date, 31) BETWEEN TO_DATE(a.disburse_time) AND p.obs_dt
              THEN 1 ELSE 0 END                               AS is_label_matured
    FROM loan_apply a
    CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON a.listing_id = s.listing_id
     AND s.stat_date = p.obs_dt
),
base AS (
    SELECT
         l.*
        ,x.first_repay_time                                   AS label_first_repay_time
        ,x.user_actual_repay_time                             AS label_user_actual_repay_time
        ,x.debt_status                                        AS label_debt_status
        ,x.hist_overdue_days                                  AS label_hist_overdue_days
        ,x.current_overdue_days                               AS label_current_overdue_days
        ,x.owing_amount                                       AS label_owing_amount
        ,CASE WHEN l.is_label_matured = 1 THEN x.current_overdue_days END AS label_dpd
        ,CASE WHEN l.is_label_matured = 1 THEN x.hist_overdue_days END    AS label_hist_dpd

        ,COALESCE(
             TO_DATE(x.first_repay_time)
            ,CASE WHEN l.first_repay_time IS NOT NULL AND TO_DATE(l.first_repay_time) <= l.label_obs_dt
                  THEN TO_DATE(l.first_repay_time) END
            ,l.label_obs_dt
         )                                                    AS label_obs_day
    FROM latest l
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp x
      ON l.listing_id = x.listing_id
     AND x.stat_date = l.label_obs_dt
),
mob_obs AS (
    SELECT
         b.loan_no
        ,b.listing_id
        ,TO_DATE(b.disburse_time)                             AS disburse_date
        ,m.mob_no
        ,LAST_DAY(ADD_MONTHS(TO_DATE(b.disburse_time), m.mob_no)) AS mob_obs_dt
    FROM base b
    CROSS JOIN (SELECT EXPLODE(SEQUENCE(0, 4)) AS mob_no) m
    WHERE b.is_disburse_success = 1
      AND LAST_DAY(ADD_MONTHS(TO_DATE(b.disburse_time), m.mob_no)) <= b.obs_dt
),
mob_detail AS (
    SELECT
         o.loan_no
        ,o.mob_no
        ,CASE WHEN d.current_overdue_days IS NOT NULL
              THEN CASE WHEN d.current_overdue_days >= 5  THEN 1 ELSE 0 END END AS is_5plus
        ,CASE WHEN d.current_overdue_days IS NOT NULL
              THEN CASE WHEN d.current_overdue_days > 30 THEN 1 ELSE 0 END END AS is_30plus
        ,CASE WHEN d.hist_overdue_days IS NOT NULL
              THEN CASE WHEN d.hist_overdue_days >= 5  THEN 1 ELSE 0 END END AS is_ever_5plus
        ,CASE WHEN d.hist_overdue_days IS NOT NULL
              THEN CASE WHEN d.hist_overdue_days > 30 THEN 1 ELSE 0 END END AS is_ever_30plus
    FROM mob_obs o
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp d
      ON o.listing_id = d.listing_id
     AND o.mob_obs_dt = d.stat_date
),
mob_wide AS (
    SELECT
         loan_no
        ,MAX(CASE WHEN mob_no = 1  THEN is_5plus END) AS y_mob1_5plus_cnt
        ,MAX(CASE WHEN mob_no = 1  THEN is_ever_5plus END) AS y_mob1_ever_5plus_cnt
        ,MAX(CASE WHEN mob_no = 2  THEN is_5plus END) AS y_mob2_5plus_cnt
        ,MAX(CASE WHEN mob_no = 2  THEN is_ever_5plus END) AS y_mob2_ever_5plus_cnt
        ,MAX(CASE WHEN mob_no = 3  THEN is_5plus END) AS y_mob3_5plus_cnt
        ,MAX(CASE WHEN mob_no = 3  THEN is_ever_5plus END) AS y_mob3_ever_5plus_cnt
        ,MAX(CASE WHEN mob_no = 1  THEN is_30plus END) AS y_mob1_30plus_cnt
        ,MAX(CASE WHEN mob_no = 1  THEN is_ever_30plus END) AS y_mob1_ever_30plus_cnt
        ,MAX(CASE WHEN mob_no = 2  THEN is_30plus END) AS y_mob2_30plus_cnt
        ,MAX(CASE WHEN mob_no = 2  THEN is_ever_30plus END) AS y_mob2_ever_30plus_cnt
        ,MAX(CASE WHEN mob_no = 3  THEN is_30plus END) AS y_mob3_30plus_cnt
        ,MAX(CASE WHEN mob_no = 3  THEN is_ever_30plus END) AS y_mob3_ever_30plus_cnt
    FROM mob_detail
    GROUP BY loan_no
),

mob_track AS (
    SELECT
         t.loan_no
        ,t.mob_no
        ,GREATEST(COALESCE(t.owing_principal, 0), 0) AS estimate_principal_remaining
        ,COALESCE(t.current_overdue_days, 0)         AS dpd_days
        ,COALESCE(t.hist_overdue_days, 0)            AS dpd_days_ever
    FROM (
        SELECT
             o.loan_no
            ,o.mob_no
            ,d.owing_principal
            ,d.current_overdue_days
            ,d.hist_overdue_days
            ,ROW_NUMBER() OVER (
                 PARTITION BY o.loan_no, o.mob_no
                 ORDER BY CASE WHEN d.stat_date <= o.mob_obs_dt THEN 0 ELSE 1 END
                         ,CASE WHEN d.stat_date <= o.mob_obs_dt THEN DATEDIFF(o.mob_obs_dt, d.stat_date)
                               ELSE DATEDIFF(d.stat_date, o.mob_obs_dt) END
             ) AS rn
        FROM mob_obs o
        JOIN model.tmp_eliam_wagego_stg_debt_snp d
          ON o.listing_id = d.listing_id
         AND d.stat_date >= o.disburse_date
         AND d.stat_date <= DATE_ADD(o.mob_obs_dt, CASE WHEN o.mob_no = 0 THEN 7 ELSE 0 END)
    ) t
    WHERE t.rn = 1
),
mob_track_wide AS (
    SELECT
         loan_no
        ,MAX(CASE WHEN mob_no = 0 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob0
        ,MAX(CASE WHEN mob_no = 0 THEN dpd_days END)                     AS dpd_days_mob0
        ,MAX(CASE WHEN mob_no = 0 THEN dpd_days_ever END)                AS dpd_days_ever_mob0
        ,MAX(CASE WHEN mob_no = 1 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob1
        ,MAX(CASE WHEN mob_no = 1 THEN dpd_days END)                     AS dpd_days_mob1
        ,MAX(CASE WHEN mob_no = 1 THEN dpd_days_ever END)                AS dpd_days_ever_mob1
        ,MAX(CASE WHEN mob_no = 2 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob2
        ,MAX(CASE WHEN mob_no = 2 THEN dpd_days END)                     AS dpd_days_mob2
        ,MAX(CASE WHEN mob_no = 2 THEN dpd_days_ever END)                AS dpd_days_ever_mob2
        ,MAX(CASE WHEN mob_no = 3 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob3
        ,MAX(CASE WHEN mob_no = 3 THEN dpd_days END)                     AS dpd_days_mob3
        ,MAX(CASE WHEN mob_no = 3 THEN dpd_days_ever END)                AS dpd_days_ever_mob3
        ,MAX(CASE WHEN mob_no = 4 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob4
        ,MAX(CASE WHEN mob_no = 4 THEN dpd_days END)                     AS dpd_days_mob4
        ,MAX(CASE WHEN mob_no = 4 THEN dpd_days_ever END)                AS dpd_days_ever_mob4
    FROM mob_track
    GROUP BY loan_no
)
SELECT
     b.loan_no
    ,b.user_id
    ,b.application_id
    ,b.app_id
    ,b.listing_id
    ,b.apply_status
    ,b.apply_status_desc
    ,b.is_disburse_success
    ,b.is_reject
    ,b.is_expired
    ,b.is_disburse_failed
    ,b.apply_time
    ,b.apply_date
    ,b.apply_month
    ,b.disburse_time
    ,b.apply_seq
    ,b.application_rank
    ,b.strategy_time
    ,b.retry_count
    ,b.stamp_time
    ,b.stamp_flow_id
    ,b.real_amount
    ,b.apply_amount
    ,b.interest
    ,b.service_fee
    ,b.term_quantity
    ,b.term_unit
    ,b.total_period
    ,b.is_deal
    ,b.withdraw_time
    ,b.list_due_date
    ,b.init_due_date
    ,b.user_actual_repay_time
    ,b.debt_status
    ,b.debt_status_desc
    ,b.hist_overdue_days
    ,b.current_overdue_days
    ,b.principal
    ,b.repay_amount
    ,b.owing_amount
    ,b.obs_dt
    ,b.label_obs_dt
    ,b.is_label_matured
    ,b.label_user_actual_repay_time
    ,b.label_debt_status
    ,b.label_current_overdue_days
    ,b.label_hist_overdue_days
    ,b.label_owing_amount
    ,b.label_dpd                                           AS y_due_dpd
    ,b.label_hist_dpd                                      AS y_due_ever_dpd
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd > 0 THEN 1 ELSE 0 END END AS y_due_ovd_cnt
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd > 0 THEN b.real_amount ELSE 0 END END AS y_due_ovd_amt
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd >= 5 THEN 1 ELSE 0 END END AS y_due_5plus_cnt
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd > 30 THEN 1 ELSE 0 END END AS y_due_30plus_cnt
    ,CASE WHEN b.label_hist_dpd IS NOT NULL THEN CASE WHEN b.label_hist_dpd > 0 THEN 1 ELSE 0 END END AS y_due_ever_ovd_cnt
    ,CASE WHEN b.label_hist_dpd IS NOT NULL THEN CASE WHEN b.label_hist_dpd > 0 THEN b.real_amount ELSE 0 END END AS y_due_ever_ovd_amt
    ,CASE WHEN b.label_hist_dpd IS NOT NULL THEN CASE WHEN b.label_hist_dpd >= 5 THEN 1 ELSE 0 END END AS y_due_ever_5plus_cnt
    ,CASE WHEN b.label_hist_dpd IS NOT NULL THEN CASE WHEN b.label_hist_dpd > 30 THEN 1 ELSE 0 END END AS y_due_ever_30plus_cnt
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END END AS y_fpd3_ovd_cnt
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END END AS y_fpd7_ovd_cnt
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END END AS y_fpd14_ovd_cnt
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END END AS y_fpd30_ovd_cnt
    ,CASE WHEN b.debt_listing_id IS NOT NULL THEN DATEDIFF(b.init_due_date, TO_DATE(b.disburse_time)) END AS loan_term_contract_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN DATEDIFF(TO_DATE(b.user_actual_repay_time), TO_DATE(b.disburse_time)) END AS loan_term_actual_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN CASE WHEN TO_DATE(b.user_actual_repay_time) < b.init_due_date THEN 1 ELSE 0 END END AS is_early_settlement
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN 1 ELSE 0 END END AS y_obs_ovd_cnt
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS y_obs_ovd_amt
    ,CASE WHEN b.is_deal = 1 AND b.hist_overdue_days IS NOT NULL THEN CASE WHEN b.hist_overdue_days > 0 THEN 1 ELSE 0 END END AS y_obs_ever_ovd_cnt
    ,CASE WHEN b.is_deal = 1 AND b.hist_overdue_days IS NOT NULL THEN CASE WHEN b.hist_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS y_obs_ever_ovd_amt
    ,DATE_FORMAT(b.disburse_time, 'yyyy-MM')                 AS disburse_month
    ,DATEDIFF(b.obs_dt, TO_DATE(b.disburse_time))            AS days_on_book
    ,CASE WHEN b.application_rank = 1 THEN 'New' WHEN b.application_rank IS NOT NULL THEN 'Old' END AS user_type
    ,m.y_mob1_5plus_cnt
    ,m.y_mob1_ever_5plus_cnt
    ,m.y_mob2_5plus_cnt
    ,m.y_mob2_ever_5plus_cnt
    ,m.y_mob3_5plus_cnt
    ,m.y_mob3_ever_5plus_cnt
    ,m.y_mob1_30plus_cnt
    ,m.y_mob1_ever_30plus_cnt
    ,m.y_mob2_30plus_cnt
    ,m.y_mob2_ever_30plus_cnt
    ,m.y_mob3_30plus_cnt
    ,m.y_mob3_ever_30plus_cnt
    ,t.estimate_principal_remaining_mob0
    ,t.dpd_days_mob0
    ,t.dpd_days_ever_mob0
    ,t.estimate_principal_remaining_mob1
    ,t.dpd_days_mob1
    ,t.dpd_days_ever_mob1
    ,t.estimate_principal_remaining_mob2
    ,t.dpd_days_mob2
    ,t.dpd_days_ever_mob2
    ,t.estimate_principal_remaining_mob3
    ,t.dpd_days_mob3
    ,t.dpd_days_ever_mob3
    ,t.estimate_principal_remaining_mob4
    ,t.dpd_days_mob4
    ,t.dpd_days_ever_mob4
FROM base b
LEFT JOIN mob_wide m
  ON b.loan_no = m.loan_no
LEFT JOIN mob_track_wide t
  ON b.loan_no = t.loan_no
;
