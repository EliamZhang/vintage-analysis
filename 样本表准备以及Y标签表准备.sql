SET spark.sql.session.timeZone = Australia/Sydney;

-- ============================================================================
-- 第零步：观察日参数表（param_obs_date）
-- 粒度：1 行；主键：观察日（obs_dt）
-- 上游：edw_ewa.dwb_asset_debt_dtl_snp
-- 目的：取最新快照日（obs_dt），统一本次分析的观察时点，供下游快照关联。
-- 加工逻辑：从债务快照表（edw_ewa.dwb_asset_debt_dtl_snp）取 MAX(TO_DATE(dt))，输出一行观察日（obs_dt）。
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
-- 下游：dwd_loan_debt、dws_vintage_loan、dws_vintage_mob
-- 日期范围：最早申请日前 1 个月 ~ 观察日（obs_dt）。
-- 目的：把多期快照聚合成一个借款一天一行，供标签窗口（init_due_date + 31 天）和 MOB 观察点取数。
-- 加工逻辑：从债务快照表（edw_ewa.dwb_asset_debt_dtl_snp）取借款（listing_id）、快照日期（dt）、应还日（init_due_date）、
--   债务状态（debt_status）、还款时间（user_actual_repay_time）、逾期天数（current_overdue_days、hist_overdue_days）和金额（principal、repay_amount、owing_amount）；
--   按借款（listing_id）× 快照日期（stat_date）聚合：应还日取 MIN、逾期天数取 MAX、金额取 SUM、债务状态取最差（4 > 1 > 2）；
--   首期还款时间（first_repay_time）只取 period_no = 1，结清时间（user_actual_repay_time）只在全部期次结清时取值；
--   日期下界取借款申请表（ods_ewa.aus_ewa_loan_biz_t_loan_application）最早申请时间（inserttime）前 1 个月。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_stg_debt_snp;
CREATE TABLE model.tmp_eliam_wagego_stg_debt_snp AS
SELECT
     d.listing_id
    ,MAX(d.user_id)                                       AS user_id
    ,TO_DATE(d.dt)                                        AS stat_date
    ,MIN(CAST(d.init_due_date AS DATE))                   AS init_due_date
    ,MAX(CASE WHEN CAST(d.period_no AS INT) = 1 THEN CAST(d.user_actual_repay_time AS TIMESTAMP) END) AS first_repay_time
    ,CASE WHEN COUNT(*) = SUM(CASE WHEN CAST(d.debt_status AS INT) = 2 THEN 1 ELSE 0 END) THEN MAX(CAST(d.user_actual_repay_time AS TIMESTAMP)) END AS user_actual_repay_time
    ,CASE MAX(CASE CAST(d.debt_status AS INT) WHEN 4 THEN 3 WHEN 1 THEN 2 WHEN 2 THEN 1 ELSE 0 END) WHEN 3 THEN 4 WHEN 2 THEN 1 WHEN 1 THEN 2 ELSE MAX(CAST(d.debt_status AS INT)) END AS debt_status
    ,MAX(CAST(d.hist_overdue_days AS INT))                AS hist_overdue_days
    ,MAX(CAST(d.current_overdue_days AS INT))             AS current_overdue_days
    ,SUM(CAST(d.principal AS DOUBLE))                     AS principal
    ,SUM(CAST(d.repay_amount AS DOUBLE))                  AS repay_amount
    ,SUM(CAST(d.owing_amount AS DOUBLE))                  AS owing_amount
FROM edw_ewa.dwb_asset_debt_dtl_snp d
CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
WHERE TO_DATE(d.dt) <= p.obs_dt
  AND TO_DATE(d.dt) >= (
      SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
      FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
      WHERE CAST(a.isactive AS INT) = 1
  )
GROUP BY d.listing_id, TO_DATE(d.dt)
;                                                                 -- 日快照（stat_date），支持任意 init_due_date + 31 标签观察点

-- ============================================================================
-- 第二步：借款申请明细（dwd_loan_apply）
-- 粒度：借款申请（loan_no），一行一个申请（含成功/拒绝/过期/放款失败）
-- 上游：ods_ewa.aus_ewa_loan_biz_t_loan_application + ods_ewa.aus_ewa_risk_risk_event_task
-- 下游：dwd_loan_debt
-- 加工逻辑：以借款申请表（ods_ewa.aus_ewa_loan_biz_t_loan_application，isactive = 1）为主表；
--   从风控事件表（ods_ewa.aus_ewa_risk_risk_event_task）筛 biz_id = 20050、flow_id 以 LN 开头的记录，并按 flow_id 取最新一条；
--   两表 LEFT JOIN 后，按用户申请时间生成申请序号（apply_seq），补状态中文、成功/拒绝/过期/失败标记和放款时间。
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
)
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
    ,CASE WHEN a.apply_seq = 1 THEN 1 ELSE 0 END              AS is_first_apply_in_window
    ,e.strategy_time
    ,e.retry_count
FROM apply a
LEFT JOIN event e
  ON a.loan_no = e.loan_no
;

-- ============================================================================
-- 第三步：借款 / 债务明细（dwd_loan_debt）
-- 粒度：借款申请（loan_no），行数与 dwd_loan_apply 一致
-- 上游：dwd_loan_apply + edw_ewa.dwb_asset_cmn_listing + stg_debt_snp
-- 下游：dws_vintage_loan
-- 目的：给每笔借款申请补上放款金额（real_amount）、期限（term_quantity / term_unit）、
--       债务状态（debt_status）、还款时间（user_actual_repay_time）、逾期天数（current_overdue_days）
--       和统一窗口标签。
-- 加工逻辑：以借款申请（dwd_loan_apply）为主表，LEFT JOIN 放款信息表（edw_ewa.dwb_asset_cmn_listing，listing_id）补放款金额和期限；
--   再分别关联观察日（obs_dt）和标签观察日（label_obs_dt = init_due_date + 31）的债务快照（stg_debt_snp）；
--   最后按快照计算逾期、FPD、30+、5+ 和结清天数，未到观察点的标签为 NULL。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_debt;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_debt AS
WITH latest AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.application_id
        ,a.app_id
        ,a.listing_id
        ,a.apply_status
        ,a.apply_status_desc
        ,a.is_disburse_success
        ,a.is_reject
        ,a.is_expired
        ,a.is_disburse_failed
        ,a.apply_time
        ,a.apply_date
        ,a.apply_month
        ,a.disburse_time
        ,a.apply_seq
        ,a.is_first_apply_in_window
        ,a.strategy_time
        ,a.retry_count
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
    FROM model.tmp_eliam_wagego_dwd_loan_apply a
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
    ,b.is_first_apply_in_window
    ,b.strategy_time
    ,b.retry_count
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
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd3_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END END END AS is_fpd3_ovd
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd7_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END END END AS is_fpd7_ovd
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd15_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 15) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 15) THEN 1 ELSE 0 END END END AS is_fpd15_ovd
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd30_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END END END AS is_fpd30_ovd
    ,CASE WHEN b.debt_listing_id IS NOT NULL THEN DATEDIFF(b.init_due_date, TO_DATE(b.disburse_time)) END AS loan_term_contract_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN DATEDIFF(TO_DATE(b.user_actual_repay_time), TO_DATE(b.disburse_time)) END AS loan_term_actual_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN CASE WHEN TO_DATE(b.user_actual_repay_time) < b.init_due_date THEN 1 ELSE 0 END END AS is_early_settlement
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN 1 ELSE 0 END END AS is_current_overdue
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS current_ovd_amt
FROM base b
;

-- ============================================================================
-- 第四步：放款成功表（dwd_disbursed_loan）
-- 粒度：借款申请（loan_no），只保留放款成功（is_disburse_success = 1）的记录
-- 上游：dwd_loan_debt
-- 下游：下游分析 / 建模取数
-- 目的：作为通用放款样本表。
-- 加工逻辑：从借款明细（dwd_loan_debt）筛放款成功（is_disburse_success = 1），按用户放款时间生成放款序号（application_rank）。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_disbursed_loan;
CREATE TABLE model.tmp_eliam_wagego_dwd_disbursed_loan AS
WITH disbursed AS (
    SELECT
         loan_no
        ,user_id
        ,listing_id
        ,disburse_time
        ,real_amount
        ,term_quantity
        ,term_unit
        ,init_due_date
        ,ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY disburse_time, loan_no) AS application_rank
    FROM model.tmp_eliam_wagego_dwd_loan_debt
    WHERE is_disburse_success = 1
)
SELECT
     loan_no
    ,user_id
    ,listing_id
    ,disburse_time
    ,TO_DATE(disburse_time)                               AS disburse_date
    ,DATE_FORMAT(disburse_time, 'yyyy-MM')                AS disburse_month
    ,real_amount
    ,term_quantity
    ,term_unit
    ,init_due_date
    ,CASE WHEN application_rank = 1 THEN 'New' ELSE 'Old' END AS user_type
FROM disbursed
;

-- ============================================================================
-- 第五步：戳额表（dwd_loan_stamp）
-- 粒度：借款申请（loan_no），一行一笔放款
-- 上游：dwd_disbursed_loan + ods_ewa.aus_listing_tb_loan_limit_apply
--       + ods_ewa.aus_ewa_risk_risk_event_task + ods_ewa.aus_listing_tb_loan_user_limit_log
-- 下游：下游分析 / 建模取数
-- 目的：为每笔放款（loan_no）匹配同一用户（user_id）在放款时间（disburse_time）前
--       最近一次戳额时点（stamp_time），并带出当时额度。
-- 加工逻辑：从放款成功表（dwd_disbursed_loan）出发，为每笔放款按 user_id 取放款时间（disburse_time）之前最近一条戳额（stamp_time）；
--   戳额优先取额度申请表（ods_ewa.aus_listing_tb_loan_limit_apply，biz_type = 400），没有时用风控事件表（ods_ewa.aus_ewa_risk_risk_event_task，biz_id = 10000）兜底；
--   再按戳额流水（flow_no = relate_id）关联额度日志表（ods_ewa.aus_listing_tb_loan_user_limit_log，event_type = 1、limit_category = 1）带出额度。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_stamp;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_stamp AS
WITH apply_stamp AS (
    SELECT
         a.borrower_id                                        AS user_id
        ,CAST(a.inserttime AS TIMESTAMP)                      AS stamp_time
        ,a.limit_apply_no
        ,a.flow_no
        ,CAST(a.id AS BIGINT)                                 AS stamp_id
    FROM ods_ewa.aus_listing_tb_loan_limit_apply a
    WHERE CAST(a.isactive AS INT) = 1
      AND CAST(a.biz_type AS INT) = 400
),
event_stamp AS (
    SELECT
         e.user_id
        ,CAST(e.inserttime AS TIMESTAMP)                      AS stamp_time
        ,CAST(NULL AS STRING)                                 AS limit_apply_no
        ,e.flow_id                                            AS flow_no
        ,CAST(e.id AS BIGINT)                                 AS stamp_id
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
primary_match AS (
    SELECT
         d.loan_no
        ,d.user_id
        ,d.disburse_time
        ,s.stamp_time
        ,s.limit_apply_no
        ,s.flow_no
        ,'limit_apply'                                        AS stamp_source
        ,ROW_NUMBER() OVER (PARTITION BY d.loan_no ORDER BY s.stamp_time DESC, s.stamp_id DESC) AS rn
    FROM model.tmp_eliam_wagego_dwd_disbursed_loan d
    JOIN apply_stamp s
      ON d.user_id = s.user_id
     AND s.stamp_time <= d.disburse_time
),
fallback_match AS (
    SELECT
         d.loan_no
        ,d.user_id
        ,d.disburse_time
        ,s.stamp_time
        ,s.limit_apply_no
        ,s.flow_no
        ,'risk_event'                                         AS stamp_source
        ,ROW_NUMBER() OVER (PARTITION BY d.loan_no ORDER BY s.stamp_time DESC, s.stamp_id DESC) AS rn
    FROM model.tmp_eliam_wagego_dwd_disbursed_loan d
    LEFT JOIN (SELECT DISTINCT loan_no FROM primary_match) p
      ON d.loan_no = p.loan_no
    JOIN event_stamp s
      ON d.user_id = s.user_id
     AND s.stamp_time <= d.disburse_time
    WHERE p.loan_no IS NULL
),
matched AS (
    SELECT loan_no, user_id, disburse_time, stamp_time, limit_apply_no, flow_no, stamp_source
    FROM primary_match
    WHERE rn = 1
    UNION ALL
    SELECT loan_no, user_id, disburse_time, stamp_time, limit_apply_no, flow_no, stamp_source
    FROM fallback_match
    WHERE rn = 1
),
limit_grant AS (
    SELECT
         l.relate_id
        ,CAST(l.total_amount_before AS DOUBLE)                AS limit_total_before
        ,CAST(l.total_amount_after AS DOUBLE)                 AS limit_total_after
        ,CAST(l.available_amount_after AS DOUBLE)             AS limit_available_after
        ,CAST(l.occupied_amount_after AS DOUBLE)              AS limit_occupied_after
        ,CAST(l.expire_time_after AS TIMESTAMP)               AS limit_expire_time
        ,ROW_NUMBER() OVER (PARTITION BY l.relate_id ORDER BY CAST(l.id AS BIGINT) DESC) AS rn
    FROM ods_ewa.aus_listing_tb_loan_user_limit_log l
    WHERE CAST(l.isactive AS INT) = 1
      AND CAST(l.event_type AS INT) = 1
      AND CAST(l.limit_category AS INT) = 1
)
SELECT
     d.loan_no
    ,d.user_id
    ,d.disburse_time
    ,m.stamp_time
    ,DATEDIFF(TO_DATE(d.disburse_time), TO_DATE(m.stamp_time)) AS stamp_to_disburse_days
    ,m.stamp_source
    ,m.limit_apply_no
    ,m.flow_no                                               AS stamp_flow_no
    ,g.limit_total_before
    ,g.limit_total_after
    ,g.limit_available_after
    ,g.limit_occupied_after
    ,g.limit_expire_time
FROM model.tmp_eliam_wagego_dwd_disbursed_loan d
LEFT JOIN matched m
  ON d.loan_no = m.loan_no
LEFT JOIN limit_grant g
  ON m.flow_no = g.relate_id
 AND g.rn = 1
;

-- ============================================================================
-- 第六步：借款级 Vintage 标签（dws_vintage_loan）
-- 粒度：借款申请（loan_no），只保留放款成功的借款
-- 上游：dwd_loan_debt + param_obs_date
-- 下游：dws_vintage_mob、ads_vintage_month
-- 目的：每笔放款一行，输出统一窗口（init_due_date + 31 天）的逾期（is_current_overdue_at_label_obs）、
--       30+（is_30plus_at_label_obs）、5+（is_5plus_at_label_obs）、FPD（is_fpd3_ovd 等）
--       和新老客标签（user_type）；MOB 曲线（mob_no）不在本表输出。
-- 加工逻辑：从借款明细（dwd_loan_debt）筛放款成功（is_disburse_success = 1）；
--   按用户放款时间生成放款序号（application_rank）并打新老客（user_type），只输出标签和放款属性。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dws_vintage_loan;
CREATE TABLE model.tmp_eliam_wagego_dws_vintage_loan AS
WITH loan AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,a.disburse_time
        ,DATE_FORMAT(a.disburse_time, 'yyyy-MM')              AS disburse_month
        ,TO_DATE(a.disburse_time)                             AS disburse_date
        ,a.real_amount
        ,a.term_unit
        ,a.init_due_date
        ,a.label_obs_dt
        ,a.is_label_matured
        ,a.dpd_at_label_obs
        ,a.hist_dpd_at_label_obs
        ,a.is_current_overdue_at_label_obs
        ,a.current_ovd_amt_at_label_obs
        ,a.is_5plus_at_label_obs
        ,a.is_30plus_at_label_obs
        ,a.is_ever_30plus_in_window
        ,a.is_fpd3_obs
        ,a.is_fpd3_ovd
        ,a.is_fpd7_obs
        ,a.is_fpd7_ovd
        ,a.is_fpd15_obs
        ,a.is_fpd15_ovd
        ,a.is_fpd30_obs
        ,a.is_fpd30_ovd
        ,ROW_NUMBER() OVER (PARTITION BY a.user_id ORDER BY a.disburse_time, a.loan_no) AS application_rank
    FROM model.tmp_eliam_wagego_dwd_loan_debt a
    WHERE a.is_disburse_success = 1
)
SELECT
     l.loan_no
    ,l.user_id
    ,l.listing_id
    ,l.disburse_time
    ,l.disburse_month
    ,l.real_amount
    ,l.term_unit
    ,l.init_due_date
    ,l.label_obs_dt
    ,l.is_label_matured
    ,p.obs_dt                                                  AS data_as_of
    ,DATEDIFF(p.obs_dt, l.disburse_date)                       AS days_on_book
    ,l.dpd_at_label_obs
    ,l.hist_dpd_at_label_obs
    ,l.is_current_overdue_at_label_obs
    ,l.current_ovd_amt_at_label_obs
    ,l.is_5plus_at_label_obs
    ,l.is_30plus_at_label_obs
    ,l.is_ever_30plus_in_window
    ,l.is_fpd3_obs
    ,l.is_fpd3_ovd
    ,l.is_fpd7_obs
    ,l.is_fpd7_ovd
    ,l.is_fpd15_obs
    ,l.is_fpd15_ovd
    ,l.is_fpd30_obs
    ,l.is_fpd30_ovd
    ,l.application_rank
    ,CASE WHEN l.application_rank = 1 THEN 'New' ELSE 'Old' END AS user_type
FROM loan l
CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
;

-- ============================================================================
-- 第七步：借款 × MOB 长表（dws_vintage_mob）
-- 粒度：借款申请（loan_no）× MOB（mob_no）
-- 上游：dws_vintage_loan + stg_debt_snp
-- 下游：ads_vintage_curve
-- 目的：把每笔借款展开为 MOB1~MOB12 观察点，供滚动 vintage 曲线使用。
-- 加工逻辑：从借款级 Vintage 标签表（dws_vintage_loan）取每笔放款，展开为 MOB1~MOB12，观察日（obs_dt）= LAST_DAY(ADD_MONTHS(disburse_time, mob_no))；
--   再按借款（listing_id）+ 观察日关联债务快照（stg_debt_snp），取对应天的逾期天数。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dws_vintage_mob;
CREATE TABLE model.tmp_eliam_wagego_dws_vintage_mob AS
WITH mob AS (
    SELECT EXPLODE(SEQUENCE(1, 12)) AS mob_no
),
obs AS (
    SELECT
         s.loan_no
        ,s.user_id
        ,s.listing_id
        ,TO_DATE(s.disburse_time)                             AS disburse_date
        ,s.disburse_month
        ,s.real_amount
        ,s.term_unit
        ,s.user_type
        ,s.application_rank
        ,s.data_as_of
        ,m.mob_no
        ,LAST_DAY(ADD_MONTHS(TO_DATE(s.disburse_time), m.mob_no)) AS obs_dt
    FROM model.tmp_eliam_wagego_dws_vintage_loan s
    CROSS JOIN mob m
)
SELECT
     o.loan_no
    ,o.user_id
    ,o.listing_id
    ,o.disburse_date
    ,o.disburse_month
    ,o.real_amount
    ,o.term_unit
    ,o.user_type
    ,o.application_rank
    ,o.data_as_of
    ,o.mob_no
    ,o.obs_dt
    ,CASE WHEN o.obs_dt <= o.data_as_of THEN 1 ELSE 0 END     AS is_matured
    ,d.current_overdue_days                                   AS dpd
    ,CASE WHEN o.obs_dt <= o.data_as_of AND d.current_overdue_days IS NOT NULL
          THEN CASE WHEN d.current_overdue_days >= 5  THEN 1 ELSE 0 END END AS is_5plus
    ,CASE WHEN o.obs_dt <= o.data_as_of AND d.current_overdue_days IS NOT NULL
          THEN CASE WHEN d.current_overdue_days > 30 THEN 1 ELSE 0 END END AS is_30plus
FROM obs o
LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp d
  ON o.listing_id = d.listing_id
 AND o.obs_dt = d.stat_date
;

-- ============================================================================
-- 第八步：放款月汇总（ads_vintage_month）
-- 粒度：放款月（disburse_month）
-- 上游：dws_vintage_loan
-- 下游：报表
-- 目的：按放款月汇总放款量，以及统一窗口（init_due_date + 31 天）的逾期（cur_ovd_cnt）、
--       30+（cur_30plus_cnt）和 FPD（fpd3_ovd_cnt 等），笔数与金额双口径。
-- 加工逻辑：从借款级 Vintage 标签表（dws_vintage_loan）按放款月（disburse_month）分组；
--   汇总放款、逾期、30+ 和 FPD3/7/15/30 的笔数与金额，并计算占比。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_ads_vintage_month;
CREATE TABLE model.tmp_eliam_wagego_ads_vintage_month AS
SELECT
     disburse_month
    ,MAX(data_as_of)                                                             AS data_as_of
    ,COUNT(*)                                                                    AS loan_cnt
    ,ROUND(SUM(real_amount), 2)                                                  AS loan_amt
    ,SUM(is_label_matured)                                                       AS matured_cnt
    ,ROUND(SUM(CASE WHEN is_label_matured = 1 THEN real_amount ELSE 0 END), 2)   AS matured_amt
    ,SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN 1 ELSE 0 END) AS obs_cnt
    ,ROUND(SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN real_amount ELSE 0 END), 2) AS obs_amt
    ,SUM(CASE WHEN is_30plus_at_label_obs = 1 THEN 1 ELSE 0 END)                 AS cur_30plus_cnt
    ,ROUND(SUM(CASE WHEN is_30plus_at_label_obs = 1 THEN real_amount ELSE 0 END), 2) AS cur_30plus_amt
    ,SUM(CASE WHEN is_current_overdue_at_label_obs = 1 THEN 1 ELSE 0 END)        AS cur_ovd_cnt
    ,ROUND(COALESCE(SUM(current_ovd_amt_at_label_obs), 0), 2)                    AS cur_ovd_amt
    ,ROUND(100.0 * SUM(CASE WHEN is_current_overdue_at_label_obs = 1 THEN 1 ELSE 0 END) / NULLIF(SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS cur_ovd_rate
    ,ROUND(100.0 * SUM(current_ovd_amt_at_label_obs) / NULLIF(SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS cur_ovd_amt_rate
    ,COALESCE(SUM(is_ever_30plus_in_window), 0)                                  AS ever_30plus_cnt
    ,ROUND(SUM(CASE WHEN is_ever_30plus_in_window = 1 THEN real_amount ELSE 0 END), 2) AS ever_30plus_amt
    ,ROUND(100.0 * SUM(is_ever_30plus_in_window) / NULLIF(SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS ever_30plus_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_ever_30plus_in_window = 1 THEN real_amount ELSE 0 END) / NULLIF(SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS ever_30plus_amt_rate
    ,COALESCE(SUM(is_fpd3_obs), 0)                                               AS fpd3_obs_cnt
    ,COALESCE(SUM(is_fpd3_ovd), 0)                                               AS fpd3_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd3_obs = 1 THEN real_amount ELSE 0 END), 2)        AS fpd3_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd3_ovd = 1 THEN real_amount ELSE 0 END), 2)        AS fpd3_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd3_ovd) / NULLIF(SUM(is_fpd3_obs), 0), 2)            AS fpd3_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd3_ovd = 1 THEN real_amount ELSE 0 END) / NULLIF(SUM(CASE WHEN is_fpd3_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd3_ovd_amt_rate
    ,COALESCE(SUM(is_fpd7_obs), 0)                                               AS fpd7_obs_cnt
    ,COALESCE(SUM(is_fpd7_ovd), 0)                                               AS fpd7_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd7_obs = 1 THEN real_amount ELSE 0 END), 2)        AS fpd7_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd7_ovd = 1 THEN real_amount ELSE 0 END), 2)        AS fpd7_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd7_ovd) / NULLIF(SUM(is_fpd7_obs), 0), 2)            AS fpd7_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd7_ovd = 1 THEN real_amount ELSE 0 END) / NULLIF(SUM(CASE WHEN is_fpd7_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd7_ovd_amt_rate
    ,COALESCE(SUM(is_fpd15_obs), 0)                                              AS fpd15_obs_cnt
    ,COALESCE(SUM(is_fpd15_ovd), 0)                                              AS fpd15_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd15_obs = 1 THEN real_amount ELSE 0 END), 2)       AS fpd15_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd15_ovd = 1 THEN real_amount ELSE 0 END), 2)       AS fpd15_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd15_ovd) / NULLIF(SUM(is_fpd15_obs), 0), 2)          AS fpd15_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd15_ovd = 1 THEN real_amount ELSE 0 END) / NULLIF(SUM(CASE WHEN is_fpd15_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd15_ovd_amt_rate
    ,COALESCE(SUM(is_fpd30_obs), 0)                                              AS fpd30_obs_cnt
    ,COALESCE(SUM(is_fpd30_ovd), 0)                                              AS fpd30_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd30_obs = 1 THEN real_amount ELSE 0 END), 2)       AS fpd30_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd30_ovd = 1 THEN real_amount ELSE 0 END), 2)       AS fpd30_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd30_ovd) / NULLIF(SUM(is_fpd30_obs), 0), 2)          AS fpd30_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd30_ovd = 1 THEN real_amount ELSE 0 END) / NULLIF(SUM(CASE WHEN is_fpd30_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd30_ovd_amt_rate
FROM model.tmp_eliam_wagego_dws_vintage_loan
GROUP BY disburse_month
;

-- ============================================================================
-- 第九步：分群 × MOB 曲线汇总（ads_vintage_curve）
-- 粒度：放款月（disburse_month）× 用户类型（user_type）× MOB（mob_no）
-- 上游：dws_vintage_mob
-- 下游：报表 / 曲线
-- 目的：按放款月和新老客汇总每个 MOB 的逾期率，笔数与金额双口径。
-- 加工逻辑：从借款 × MOB 长表（dws_vintage_mob）按放款月（disburse_month）× 用户类型（user_type）× MOB（mob_no）分组，
--   汇总观测数、5+、30+ 的笔数与金额，并计算占比。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_ads_vintage_curve;
CREATE TABLE model.tmp_eliam_wagego_ads_vintage_curve AS
SELECT
     disburse_month
    ,user_type
    ,mob_no
    ,MAX(data_as_of)                                                                            AS data_as_of
    ,COUNT(*)                                                                                  AS cohort_cnt
    ,ROUND(SUM(real_amount), 2)                                                                AS cohort_amt
    ,SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN 1 ELSE 0 END)                       AS obs_cnt
    ,ROUND(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN real_amount ELSE 0 END), 2)   AS obs_amt
    ,SUM(is_5plus)                                                                             AS cnt_5plus
    ,ROUND(SUM(CASE WHEN is_5plus = 1 THEN real_amount ELSE 0 END), 2)                         AS amt_5plus
    ,ROUND(100.0 * SUM(is_5plus) / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS rate_5plus
    ,ROUND(100.0 * SUM(CASE WHEN is_5plus = 1 THEN real_amount ELSE 0 END) / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS rate_5plus_amt
    ,SUM(is_30plus)                                                                            AS cnt_30plus
    ,ROUND(SUM(CASE WHEN is_30plus = 1 THEN real_amount ELSE 0 END), 2)                        AS amt_30plus
    ,ROUND(100.0 * SUM(is_30plus) / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS rate_30plus
    ,ROUND(100.0 * SUM(CASE WHEN is_30plus = 1 THEN real_amount ELSE 0 END) / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS rate_30plus_amt
FROM model.tmp_eliam_wagego_dws_vintage_mob
GROUP BY disburse_month, user_type, mob_no
;