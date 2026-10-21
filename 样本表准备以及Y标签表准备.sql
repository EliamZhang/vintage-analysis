SET spark.sql.session.timeZone = Australia/Sydney;

-- ============================================================================
-- 第零步：观察日参数表（param_obs_date）
-- 粒度：1 行；主键：观察日（obs_dt）
-- 上游：edw_ewa.dwb_asset_debt_dtl_snp
-- 目的：取最新快照日（obs_dt），统一本次分析的观察时点，供下游快照关联。
-- 加工逻辑：债务快照表（edw_ewa.dwb_asset_debt_dtl_snp）是按天记录的借款债务快照，一行是某借款某期次在某天的状态；
--   这里取全表最新快照日 MAX(TO_DATE(dt)) 作为观察日（obs_dt），下游所有快照取数都以这一天为准。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_param_obs_date;
CREATE TABLE model.tmp_eliam_wagego_param_obs_date AS
SELECT MAX(TO_DATE(dt)) AS obs_dt
FROM edw_ewa.dwb_asset_debt_dtl_snp
;

-- ============================================================================
-- 第一步：债务快照子集（stg_debt_snp）
-- 粒度：借款（listing_id）× 快照日期（stat_date），一个借款一天一行
-- 上游：
--   edw_ewa.dwb_asset_debt_dtl_snp
--   ods_ewa.aus_ewa_loan_biz_t_loan_application
--   model.tmp_eliam_wagego_param_obs_date
-- 下游：dwd_loan_apply
-- 日期范围：最早申请日前 1 个月 ~ 观察日（obs_dt）。
-- 目的：把多期快照聚合成一个借款一天一行，供标签窗口（init_due_date + 31 天）和 MOB 观察点取数。
-- 加工逻辑：债务快照表（edw_ewa.dwb_asset_debt_dtl_snp）一行是借款（listing_id）× 期次（period_no）× 日期（dt），
--   这里按借款（listing_id）× 日期（dt）聚合，把多期压成一行：应还日（init_due_date）取 MIN、逾期天数（current_overdue_days、hist_overdue_days）取 MAX、
--   金额（principal、repay_amount、owing_amount）取 SUM、债务状态（debt_status）取最差（4 逾期中 > 1 未结清 > 2 已结清）；
--   还款时间拆两个：首期还款时间（first_repay_time）只取 period_no = 1，供 FPD 判定；结清时间（user_actual_repay_time）只在全部期次结清时取 MAX，否则为 NULL；
--   扫描范围取放款申请表（ods_ewa.aus_ewa_loan_biz_t_loan_application）最早申请时间（inserttime）前 1 个月，到观察日参数表（param_obs_date）的 obs_dt。
-- ============================================================================
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
    FROM edw_ewa.dwb_asset_debt_dtl_snp d
    CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
    WHERE TO_DATE(d.dt) <= p.obs_dt
      AND TO_DATE(d.dt) >= (
          SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
          FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
          WHERE CAST(a.isactive AS INT) = 1
      )
)
SELECT
     listing_id
    ,MAX(user_id)                                         AS user_id
    ,stat_date
    ,MIN(init_due_date)                                   AS init_due_date
    ,MAX(CASE WHEN period_no = 1 THEN user_actual_repay_time END) AS first_repay_time
    ,CASE WHEN COUNT(*) = SUM(CASE WHEN debt_status = 2 THEN 1 ELSE 0 END) THEN MAX(user_actual_repay_time) END AS user_actual_repay_time
    ,CASE MAX(CASE debt_status WHEN 4 THEN 3 WHEN 1 THEN 2 WHEN 2 THEN 1 ELSE 0 END) WHEN 3 THEN 4 WHEN 2 THEN 1 WHEN 1 THEN 2 ELSE MAX(debt_status) END AS debt_status
    ,MAX(hist_overdue_days)                               AS hist_overdue_days
    ,MAX(current_overdue_days)                            AS current_overdue_days
    ,SUM(principal)                                       AS principal
    ,SUM(repay_amount)                                    AS repay_amount
    ,SUM(owing_amount)                                    AS owing_amount
FROM src
GROUP BY listing_id, stat_date
;                                                                 -- 日快照（stat_date），支持任意 init_due_date + 31 标签观察点

-- ============================================================================
-- 第二步：放款申请明细（dwd_loan_apply）
-- 粒度：放款申请（loan_no），一行一个申请（含成功/拒绝/过期/放款失败）
-- 上游：ods_ewa.aus_ewa_loan_biz_t_loan_application + ods_ewa.aus_ewa_risk_risk_event_task
--       + ods_ewa.aus_listing_tb_loan_limit_apply + edw_ewa.dwb_asset_cmn_listing
--       + stg_debt_snp + param_obs_date
-- 下游：下游分析 / 建模取数
-- 目的：一行一个申请，包含申请状态、放款属性、观察日债务状态、FPD3/7/14/30 标签和 MOB1~MOB12 的 5+ / 30+ 标记；
--       后续分析按 is_disburse_success = 1 筛放款成功样本。
-- 加工逻辑：
--   1) 以有效申请（isactive = 1）为主表，补风控事件（biz_id = 20050）、申请状态中文和放款时间；
--   2) 额度申请表（biz_type = 400）和风控事件（biz_id = 10000）按用户匹配申请前最近一次戳额时点（stamp_time），额度申请表优先；
--   3) 按用户申请时间生成申请序号（apply_seq），并为放款成功的申请按放款时间生成放款序号（application_rank）；
--   4) 按 listing_id 关联放款信息表（dwb_asset_cmn_listing），补放款金额、利息费用、期限、是否成交和合同应还日；
--   5) 按 listing_id + 观察日关联债务快照（stg_debt_snp），取观察日债务状态，并以 init_due_date + 31 为标签观察日再关联一次快照；
--   6) 成熟后计算标签日 DPD、5+ / 30+、FPD3/7/14/30、合同期限、实际期限和早结清等指标；
--   7) 按 MOB1~MOB12 关联债务快照，输出每个观察点的 5+ / 30+ 标记，未到观察日或无快照时标记为 NULL。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_apply;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_apply AS
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
        ,CAST(t.application_id AS STRING)                     AS application_id  -- 仅展示，不参与关联
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
        ,CAST(a.id AS BIGINT)                                 AS stamp_id
        ,1                                                    AS source_priority
    FROM ods_ewa.aus_listing_tb_loan_limit_apply a
    WHERE CAST(a.isactive AS INT) = 1
      AND CAST(a.biz_type AS INT) = 400
    UNION ALL
    SELECT
         e.user_id
        ,CAST(e.inserttime AS TIMESTAMP)
        ,CAST(e.id AS BIGINT)
        ,2
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
stamp_matched AS (
    SELECT
         a.loan_no
        ,s.stamp_time
        ,ROW_NUMBER() OVER (PARTITION BY a.loan_no ORDER BY s.source_priority, s.stamp_time DESC, s.stamp_id DESC) AS rn
    FROM apply a
    JOIN stamp s
      ON a.user_id = s.user_id
     AND s.stamp_time <= a.apply_time
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
    FROM apply a
    LEFT JOIN event e
      ON a.loan_no = e.loan_no
    LEFT JOIN ranked r
      ON a.loan_no = r.loan_no
    LEFT JOIN stamp_matched sm
      ON a.loan_no = sm.loan_no
     AND sm.rn = 1
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
        ,CASE s.debt_status WHEN 1 THEN '未结清' WHEN 2 THEN '已结清' WHEN 4 THEN '逾期中' ELSE CAST(s.debt_status AS STRING) END AS debt_status_desc
        ,s.hist_overdue_days
        ,s.current_overdue_days
        ,s.principal                                          AS debt_principal
        ,s.repay_amount
        ,s.owing_amount
        ,p.obs_dt
    FROM loan_apply a
    CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON a.listing_id = s.listing_id
     AND s.stat_date = p.obs_dt
),
label AS (
    SELECT
         l.loan_no
        ,s.first_repay_time                                   AS label_first_repay_time
        ,s.user_actual_repay_time                             AS label_user_actual_repay_time
        ,s.debt_status                                        AS label_debt_status
        ,s.hist_overdue_days                                  AS label_hist_overdue_days
        ,s.current_overdue_days                               AS label_current_overdue_days
        ,s.owing_amount                                       AS label_owing_amount
    FROM latest l
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON l.listing_id = s.listing_id
     AND s.stat_date = l.label_obs_dt
),
base AS (
    SELECT
         b.*
        ,x.label_first_repay_time
        ,x.label_user_actual_repay_time
        ,x.label_debt_status
        ,x.label_hist_overdue_days
        ,x.label_current_overdue_days
        ,x.label_owing_amount
        ,CASE WHEN b.is_disburse_success = 1 AND b.is_deal = 1 AND b.debt_listing_id IS NOT NULL
               AND b.label_obs_dt IS NOT NULL AND b.label_obs_dt >= TO_DATE(b.disburse_time)
               AND b.label_obs_dt <= b.obs_dt
              THEN 1 ELSE 0 END                               AS is_label_matured
        ,COALESCE(x.label_first_repay_time,
                  CASE WHEN b.first_repay_time IS NOT NULL AND TO_DATE(b.first_repay_time) <= b.label_obs_dt
                       THEN b.first_repay_time END)            AS repay_at_label_obs
    FROM latest b
    LEFT JOIN label x
      ON b.loan_no = x.loan_no
),
loan AS (
    SELECT
         b.loan_no
        ,b.listing_id
        ,b.disburse_time
        ,b.obs_dt                                             AS data_as_of
    FROM base b
    WHERE b.is_disburse_success = 1
),
mob AS (
    SELECT EXPLODE(SEQUENCE(1, 12)) AS mob_no
),
mob_obs AS (
    SELECT
         w.loan_no
        ,w.listing_id
        ,w.data_as_of
        ,m.mob_no
        ,LAST_DAY(ADD_MONTHS(TO_DATE(w.disburse_time), m.mob_no)) AS obs_dt
    FROM loan w
    CROSS JOIN mob m
),
mob_detail AS (
    SELECT
         o.loan_no
        ,o.mob_no
        ,CASE WHEN o.obs_dt <= o.data_as_of AND d.current_overdue_days IS NOT NULL
              THEN CASE WHEN d.current_overdue_days >= 5  THEN 1 ELSE 0 END END AS is_5plus
        ,CASE WHEN o.obs_dt <= o.data_as_of AND d.current_overdue_days IS NOT NULL
              THEN CASE WHEN d.current_overdue_days > 30 THEN 1 ELSE 0 END END AS is_30plus
    FROM mob_obs o
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp d
      ON o.listing_id = d.listing_id
     AND o.obs_dt = d.stat_date
),
mob_wide AS (
    SELECT
         loan_no
        ,MAX(CASE WHEN mob_no = 1  THEN is_5plus END) AS mob1_5plus
        ,MAX(CASE WHEN mob_no = 2  THEN is_5plus END) AS mob2_5plus
        ,MAX(CASE WHEN mob_no = 3  THEN is_5plus END) AS mob3_5plus
        ,MAX(CASE WHEN mob_no = 4  THEN is_5plus END) AS mob4_5plus
        ,MAX(CASE WHEN mob_no = 5  THEN is_5plus END) AS mob5_5plus
        ,MAX(CASE WHEN mob_no = 6  THEN is_5plus END) AS mob6_5plus
        ,MAX(CASE WHEN mob_no = 7  THEN is_5plus END) AS mob7_5plus
        ,MAX(CASE WHEN mob_no = 8  THEN is_5plus END) AS mob8_5plus
        ,MAX(CASE WHEN mob_no = 9  THEN is_5plus END) AS mob9_5plus
        ,MAX(CASE WHEN mob_no = 10 THEN is_5plus END) AS mob10_5plus
        ,MAX(CASE WHEN mob_no = 11 THEN is_5plus END) AS mob11_5plus
        ,MAX(CASE WHEN mob_no = 12 THEN is_5plus END) AS mob12_5plus
        ,MAX(CASE WHEN mob_no = 1  THEN is_30plus END) AS mob1_30plus
        ,MAX(CASE WHEN mob_no = 2  THEN is_30plus END) AS mob2_30plus
        ,MAX(CASE WHEN mob_no = 3  THEN is_30plus END) AS mob3_30plus
        ,MAX(CASE WHEN mob_no = 4  THEN is_30plus END) AS mob4_30plus
        ,MAX(CASE WHEN mob_no = 5  THEN is_30plus END) AS mob5_30plus
        ,MAX(CASE WHEN mob_no = 6  THEN is_30plus END) AS mob6_30plus
        ,MAX(CASE WHEN mob_no = 7  THEN is_30plus END) AS mob7_30plus
        ,MAX(CASE WHEN mob_no = 8  THEN is_30plus END) AS mob8_30plus
        ,MAX(CASE WHEN mob_no = 9  THEN is_30plus END) AS mob9_30plus
        ,MAX(CASE WHEN mob_no = 10 THEN is_30plus END) AS mob10_30plus
        ,MAX(CASE WHEN mob_no = 11 THEN is_30plus END) AS mob11_30plus
        ,MAX(CASE WHEN mob_no = 12 THEN is_30plus END) AS mob12_30plus
    FROM mob_detail
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
    ,b.debt_principal
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
    ,CASE WHEN b.is_label_matured = 1 THEN b.label_current_overdue_days END AS dpd_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 THEN b.label_hist_overdue_days END AS hist_dpd_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_current_overdue_days > 0 THEN 1 ELSE 0 END END AS is_current_overdue_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_current_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS current_ovd_amt_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_current_overdue_days >= 5 THEN 1 ELSE 0 END END AS is_5plus_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_current_overdue_days > 30 THEN 1 ELSE 0 END END AS is_30plus_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_hist_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_hist_overdue_days > 30 THEN 1 ELSE 0 END END AS is_ever_30plus_in_window
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN COALESCE(TO_DATE(b.repay_at_label_obs), b.label_obs_dt) > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END END AS is_fpd3_ovd
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN COALESCE(TO_DATE(b.repay_at_label_obs), b.label_obs_dt) > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END END AS is_fpd7_ovd
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN COALESCE(TO_DATE(b.repay_at_label_obs), b.label_obs_dt) > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END END AS is_fpd14_ovd
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN COALESCE(TO_DATE(b.repay_at_label_obs), b.label_obs_dt) > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END END AS is_fpd30_ovd
    ,CASE WHEN b.debt_listing_id IS NOT NULL THEN DATEDIFF(b.init_due_date, TO_DATE(b.disburse_time)) END AS loan_term_contract_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN DATEDIFF(TO_DATE(b.user_actual_repay_time), TO_DATE(b.disburse_time)) END AS loan_term_actual_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN CASE WHEN TO_DATE(b.user_actual_repay_time) < b.init_due_date THEN 1 ELSE 0 END END AS is_early_settlement
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN 1 ELSE 0 END END AS is_current_overdue
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS current_ovd_amt
    ,DATE_FORMAT(b.disburse_time, 'yyyy-MM')                 AS disburse_month
    ,DATEDIFF(b.obs_dt, TO_DATE(b.disburse_time))            AS days_on_book
    ,CASE WHEN b.application_rank = 1 THEN 'New' WHEN b.application_rank IS NOT NULL THEN 'Old' END AS user_type
    ,m.mob1_5plus
    ,m.mob2_5plus
    ,m.mob3_5plus
    ,m.mob4_5plus
    ,m.mob5_5plus
    ,m.mob6_5plus
    ,m.mob7_5plus
    ,m.mob8_5plus
    ,m.mob9_5plus
    ,m.mob10_5plus
    ,m.mob11_5plus
    ,m.mob12_5plus
    ,m.mob1_30plus
    ,m.mob2_30plus
    ,m.mob3_30plus
    ,m.mob4_30plus
    ,m.mob5_30plus
    ,m.mob6_30plus
    ,m.mob7_30plus
    ,m.mob8_30plus
    ,m.mob9_30plus
    ,m.mob10_30plus
    ,m.mob11_30plus
    ,m.mob12_30plus
FROM base b
LEFT JOIN mob_wide m
  ON b.loan_no = m.loan_no
;
