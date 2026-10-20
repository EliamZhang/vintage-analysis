-- ============================================================================
-- 样本表准备以及Y标签表准备（一键运行）
-- 观察日自动取快照表最新分区，无需修改日期
-- 运行顺序：第零步 → 第一~二步 → 第三步 → 第四步 → 第五步
-- ============================================================================

SET spark.sql.session.timeZone = Australia/Sydney;

-- ============================================================================
-- 第零步：观察日控制表
-- 目的：统一确定这次分析看到哪一天。
-- 加工：取借据快照表里最新的日期，只保留一行 obs_dt。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_obs_date;
CREATE TABLE model.tmp_eliam_wagego_obs_date AS
SELECT MAX(TO_DATE(dt)) AS obs_dt
FROM edw_ewa.dwb_asset_debt_dtl_snp
WHERE CAST(period_no AS INT) = 1;

-- ============================================================================
-- 第一步：申请事件主表（一行 = 一次场景执行，flow_id 唯一）
-- 目的：把用户每次跑额、借款、拉流水整理成一行，供后面取借款事件。
-- 加工：清洗事件表，翻译场景/状态，并从 params 取出 app_id 等字段。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_application;
CREATE TABLE model.tmp_eliam_wagego_application AS
SELECT
     a.id
    ,a.flow_id
    ,a.user_id
    ,CAST(a.biz_id AS STRING)                                     AS biz_id
    ,CAST(a.application_id AS STRING)                             AS application_id  -- 仅展示，不参与关联
    ,CASE CAST(a.biz_id AS STRING)
         WHEN '10000' THEN '戳额'
         WHEN '10001' THEN '还款后跑额（非逾期）'
         WHEN '10002' THEN '换卡跑额'
         WHEN '10003' THEN '离线跑额'
         WHEN '10004' THEN '进首页跑额'
         WHEN '10005' THEN '进发表页跑额'
         WHEN '10006' THEN '失败重试跑额'
         WHEN '20050' THEN '放款策略'
         ELSE '未知场景'
     END                                                          AS scenario_name
    ,CASE CAST(a.biz_id AS STRING)
         WHEN '20050' THEN 'loan_apply'
         WHEN '40000' THEN 'cds_pull'
         ELSE 'credit_run'
     END                                                          AS event_type
    ,CAST(a.status AS INT)                                        AS status
    ,CASE CAST(a.status AS INT)
         WHEN 20 THEN 'success'
         WHEN -3 THEN 'failed'
         WHEN 10 THEN 'processing'
         ELSE 'other'
     END                                                          AS status_desc
    ,CASE WHEN CAST(a.status AS INT) = 20 THEN 1 ELSE 0 END       AS is_success
    ,CAST(a.retry_count AS INT)                                   AS retry_count
    ,CAST(a.inserttime AS TIMESTAMP)                              AS inserttime
    ,CAST(a.updatetime AS TIMESTAMP)                              AS updatetime
    ,CAST(a.resume_status AS INT)                                 AS resume_status
    ,a.error_msg
    ,a.params
    ,a.source_msg
    ,GET_JSON_OBJECT(a.params, '$.appId')                         AS app_id
    ,GET_JSON_OBJECT(a.params, '$.institution')                   AS institution
    ,CAST(GET_JSON_OBJECT(a.params, '$.refreshDays') AS INT)      AS refresh_days
    ,CAST(GET_JSON_OBJECT(a.params, '$.dpd') AS INT)              AS dpd
    ,CAST(GET_JSON_OBJECT(a.params, '$.repayAmount') AS DOUBLE)   AS repay_amount
    ,CASE WHEN CAST(a.biz_id AS STRING) = '20050'
          THEN a.flow_id END                                      AS loan_no
    ,a.dw_cre_date
    ,a.dw_upd_date
FROM ods_ewa.aus_ewa_risk_risk_event_task a
WHERE CAST(a.is_active AS INT) = 1
;

-- ============================================================================
-- 第二步：借款申请表（一行一个 loan_no，覆盖全部申请）
-- 目的：得到每笔借款申请的清单，不管成功、被拒、过期还是放款失败。
-- 加工：以借款申请表为底，一行一个 loan_no，再补上第一步的策略执行信息。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_loan_apply;
CREATE TABLE model.tmp_eliam_wagego_loan_apply AS
WITH base AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,a.status                                             AS apply_status
        ,a.fail_reason
        ,CAST(a.inserttime AS TIMESTAMP)                      AS apply_time
        ,CAST(a.apply_disburse_time AS TIMESTAMP)             AS apply_disburse_time
        ,ROW_NUMBER() OVER (
             PARTITION BY a.user_id
             ORDER BY CAST(a.inserttime AS TIMESTAMP), a.loan_no
         )                                                    AS apply_seq
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
)
SELECT
     b.loan_no
    ,b.user_id
    ,e.application_id                                         -- 仅展示，不参与关联
    ,e.app_id
    ,b.listing_id
    ,b.apply_status
    ,CASE b.apply_status
         WHEN 'DISBURSE_SUCCESS' THEN '放款成功'
         WHEN 'DISBURSE'         THEN '放款中'
         WHEN 'DISBURSE_FAILED'  THEN '放款失败'
         WHEN 'AUDIT'            THEN '审核中'
         WHEN 'AUDIT_APPROVED'   THEN '审核通过'
         WHEN 'AUDIT_REJECTED'   THEN '审核拒绝'
         WHEN 'EXPIRED'          THEN '已过期'
         WHEN 'INFO_CHANGED'     THEN '信息变更'
         ELSE b.apply_status
     END                                                      AS apply_status_desc
    ,CASE WHEN b.apply_status = 'DISBURSE_SUCCESS' THEN 1 ELSE 0 END AS is_disburse_success
    ,CASE WHEN b.apply_status = 'AUDIT_REJECTED'   THEN 1 ELSE 0 END AS is_reject
    ,CASE WHEN b.apply_status = 'EXPIRED'          THEN 1 ELSE 0 END AS is_expired
    ,CASE WHEN b.apply_status = 'DISBURSE_FAILED'  THEN 1 ELSE 0 END AS is_disburse_failed
    ,b.apply_time
    ,TO_DATE(b.apply_time)                                    AS apply_date
    ,DATE_FORMAT(b.apply_time, 'yyyy-MM')                     AS apply_month
    ,CASE WHEN b.apply_status = 'DISBURSE_SUCCESS'
          THEN b.apply_disburse_time END                      AS disburse_time
    ,b.apply_seq
    ,CASE WHEN b.apply_seq = 1 THEN 1 ELSE 0 END              AS is_first_apply_in_window
    ,e.strategy_time
    ,e.retry_count
FROM base b
LEFT JOIN (
    SELECT
         loan_no
        ,application_id
        ,app_id
        ,CAST(inserttime AS TIMESTAMP) AS strategy_time
        ,CAST(retry_count AS INT)      AS retry_count
    FROM model.tmp_eliam_wagego_application
    WHERE event_type = 'loan_apply'
      AND loan_no LIKE 'LN%'
) e
  ON b.loan_no = e.loan_no
;

-- ============================================================================
-- 第三步：补放款金额、期限、应还、实还、逾期（行数不变）
-- 目的：在每笔借款申请上补齐放款金额、期限、应还日、实还日和逾期情况。
-- 加工：按 listing_id 关联放款表和借据快照，一笔申请仍是一行。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_loan_debt;
CREATE TABLE model.tmp_eliam_wagego_loan_debt AS
WITH listing AS (
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
        ,CAST(l.real_amount AS DOUBLE)      AS real_amount
        ,CAST(l.apply_amount AS DOUBLE)     AS apply_amount
        ,CAST(l.interest AS DOUBLE)         AS interest
        ,CAST(l.service_fee AS DOUBLE)      AS service_fee
        ,CAST(l.term_quantity AS INT)       AS term_quantity
        ,l.term_unit
        ,l.total_period
        ,CAST(l.is_deal AS INT)             AS is_deal
        ,CAST(l.withdraw_time AS TIMESTAMP) AS withdraw_time
        ,CAST(l.list_due_date AS DATE)      AS list_due_date
    FROM model.tmp_eliam_wagego_loan_apply a
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
)
SELECT
     a.*
    ,d.init_due_date
    ,d.user_actual_repay_time
    ,CAST(d.debt_status AS INT)          AS debt_status
    ,CASE CAST(d.debt_status AS INT)
         WHEN 1 THEN '未结清'
         WHEN 2 THEN '已结清'
         WHEN 4 THEN '逾期中'
         ELSE CAST(d.debt_status AS STRING)
     END                                 AS debt_status_desc
    ,CAST(d.hist_overdue_days AS INT)    AS hist_overdue_days
    ,CAST(d.current_overdue_days AS INT) AS current_overdue_days
    ,CAST(d.principal AS DOUBLE)         AS debt_principal
    ,CAST(d.repay_amount AS DOUBLE)      AS repay_amount
    ,CAST(d.owing_amount AS DOUBLE)      AS owing_amount
    ,CASE WHEN d.listing_id IS NOT NULL
          THEN DATEDIFF(d.init_due_date, TO_DATE(a.disburse_time)) END
                                         AS loan_term_contract_days
    ,CASE WHEN d.user_actual_repay_time IS NOT NULL
          THEN DATEDIFF(TO_DATE(d.user_actual_repay_time), TO_DATE(a.disburse_time)) END
                                         AS loan_term_actual_days
    ,CASE WHEN d.user_actual_repay_time IS NOT NULL
          THEN CASE WHEN TO_DATE(d.user_actual_repay_time) < d.init_due_date
                    THEN 1 ELSE 0 END END
                                         AS is_early_settlement
    ,CASE WHEN a.is_deal = 1 AND d.current_overdue_days IS NOT NULL
          THEN CASE WHEN CAST(d.current_overdue_days AS INT) > 0 THEN 1 ELSE 0 END END
                                         AS is_current_overdue
    ,CASE WHEN a.is_deal = 1 AND d.current_overdue_days IS NOT NULL
          THEN CASE WHEN CAST(d.current_overdue_days AS INT) > 0
                    THEN CAST(a.real_amount AS DOUBLE) ELSE 0 END END
                                         AS current_ovd_amt
    ,CASE WHEN a.is_deal = 1 AND d.listing_id IS NOT NULL
          THEN CASE WHEN LEAST(TO_DATE(d.user_actual_repay_time), DATE_ADD(d.init_due_date, 3)) < c.obs_dt
                    THEN 1 ELSE 0 END END
                                         AS is_fpd3_obs
    ,CASE WHEN a.is_deal = 1 AND d.listing_id IS NOT NULL
          THEN CASE WHEN d.user_actual_repay_time IS NOT NULL
                    THEN CASE WHEN TO_DATE(d.user_actual_repay_time) > DATE_ADD(d.init_due_date, 3) THEN 1 ELSE 0 END
                    ELSE CASE WHEN c.obs_dt > DATE_ADD(d.init_due_date, 3) THEN 1 ELSE 0 END END
               END                       AS is_fpd3_ovd
    ,CASE WHEN a.is_deal = 1 AND d.listing_id IS NOT NULL
          THEN CASE WHEN LEAST(TO_DATE(d.user_actual_repay_time), DATE_ADD(d.init_due_date, 7)) < c.obs_dt
                    THEN 1 ELSE 0 END END
                                         AS is_fpd7_obs
    ,CASE WHEN a.is_deal = 1 AND d.listing_id IS NOT NULL
          THEN CASE WHEN d.user_actual_repay_time IS NOT NULL
                    THEN CASE WHEN TO_DATE(d.user_actual_repay_time) > DATE_ADD(d.init_due_date, 7) THEN 1 ELSE 0 END
                    ELSE CASE WHEN c.obs_dt > DATE_ADD(d.init_due_date, 7) THEN 1 ELSE 0 END END
               END                       AS is_fpd7_ovd
    ,CASE WHEN a.is_deal = 1 AND d.listing_id IS NOT NULL
          THEN CASE WHEN LEAST(TO_DATE(d.user_actual_repay_time), DATE_ADD(d.init_due_date, 15)) < c.obs_dt
                    THEN 1 ELSE 0 END END
                                         AS is_fpd15_obs
    ,CASE WHEN a.is_deal = 1 AND d.listing_id IS NOT NULL
          THEN CASE WHEN d.user_actual_repay_time IS NOT NULL
                    THEN CASE WHEN TO_DATE(d.user_actual_repay_time) > DATE_ADD(d.init_due_date, 15) THEN 1 ELSE 0 END
                    ELSE CASE WHEN c.obs_dt > DATE_ADD(d.init_due_date, 15) THEN 1 ELSE 0 END END
               END                       AS is_fpd15_ovd
    ,CASE WHEN a.is_deal = 1 AND d.listing_id IS NOT NULL
          THEN CASE WHEN LEAST(TO_DATE(d.user_actual_repay_time), DATE_ADD(d.init_due_date, 30)) < c.obs_dt
                    THEN 1 ELSE 0 END END
                                         AS is_fpd30_obs
    ,CASE WHEN a.is_deal = 1 AND d.listing_id IS NOT NULL
          THEN CASE WHEN d.user_actual_repay_time IS NOT NULL
                    THEN CASE WHEN TO_DATE(d.user_actual_repay_time) > DATE_ADD(d.init_due_date, 30) THEN 1 ELSE 0 END
                    ELSE CASE WHEN c.obs_dt > DATE_ADD(d.init_due_date, 30) THEN 1 ELSE 0 END END
               END                       AS is_fpd30_ovd
FROM listing a
LEFT JOIN (
    SELECT
         listing_id
        ,init_due_date
        ,user_actual_repay_time
        ,debt_status
        ,hist_overdue_days
        ,current_overdue_days
        ,principal
        ,repay_amount
        ,owing_amount
    FROM edw_ewa.dwb_asset_debt_dtl_snp
    WHERE TO_DATE(dt) = (SELECT obs_dt FROM model.tmp_eliam_wagego_obs_date)
      AND CAST(period_no AS INT) = 1
) d
  ON a.listing_id = d.listing_id
CROSS JOIN model.tmp_eliam_wagego_obs_date c
;

-- ============================================================================
-- 第四步：按放款月做 Vintage（按放款月份观察后续逾期）
-- 4.1 loan 级明细（含新老客标记）
-- 目的：筛出放款成功的借款，算每笔在 MOB1/MOB2（放款后第 1/2 个月）和最新的逾期，以及 FPD（首期逾期）。
-- 加工：只留放款成功的 loan_no，关联月末快照，打上 30+、FPD 和新老客标签。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_vintage_loan;
CREATE TABLE model.tmp_eliam_wagego_vintage_loan AS
WITH loan AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,a.disburse_time
        ,DATE_FORMAT(a.disburse_time, 'yyyy-MM')            AS disburse_month
        ,TO_DATE(a.disburse_time)                           AS disburse_date
        ,CAST(a.real_amount AS DOUBLE)                      AS real_amount
        ,a.term_unit
        ,DATE_FORMAT(LAST_DAY(ADD_MONTHS(TO_DATE(a.disburse_time), 1)), 'yyyy-MM-dd') AS mob1_dt
        ,DATE_FORMAT(LAST_DAY(ADD_MONTHS(TO_DATE(a.disburse_time), 2)), 'yyyy-MM-dd') AS mob2_dt
        ,c.obs_dt
        ,a.current_ovd_amt
        ,a.is_fpd3_obs
        ,a.is_fpd3_ovd
        ,a.is_fpd7_obs
        ,a.is_fpd7_ovd
        ,a.is_fpd15_obs
        ,a.is_fpd15_ovd
        ,a.is_fpd30_obs
        ,a.is_fpd30_ovd
        ,ROW_NUMBER() OVER (
             PARTITION BY a.user_id
             ORDER BY a.disburse_time, a.loan_no
         )                                                   AS application_rank
    FROM model.tmp_eliam_wagego_loan_debt a
    CROSS JOIN model.tmp_eliam_wagego_obs_date c
    WHERE a.is_disburse_success = 1
),
debt AS (
    SELECT
         listing_id
        ,dt
        ,CAST(current_overdue_days AS INT) AS current_overdue_days
        ,CAST(hist_overdue_days AS INT)    AS hist_overdue_days
    FROM edw_ewa.dwb_asset_debt_dtl_snp
    WHERE (TO_DATE(dt) = LAST_DAY(TO_DATE(dt))
           OR TO_DATE(dt) = (SELECT obs_dt FROM model.tmp_eliam_wagego_obs_date))
      AND CAST(period_no AS INT) = 1
)
SELECT
     l.loan_no
    ,l.user_id
    ,l.listing_id
    ,l.disburse_time
    ,l.disburse_month
    ,l.real_amount
    ,l.term_unit
    ,l.obs_dt                                                  AS data_as_of
    ,DATEDIFF(l.obs_dt, l.disburse_date)                   AS days_on_book
    ,m1.current_overdue_days                               AS dpd_mob1
    ,m2.current_overdue_days                               AS dpd_mob2
    ,cur.current_overdue_days                              AS dpd_latest
    ,cur.hist_overdue_days                                 AS hist_dpd_latest
    ,CASE WHEN m1.current_overdue_days IS NOT NULL
          THEN CASE WHEN m1.current_overdue_days > 30 THEN 1 ELSE 0 END END AS is_mob1_30plus
    ,CASE WHEN m2.current_overdue_days IS NOT NULL
          THEN CASE WHEN m2.current_overdue_days > 30 THEN 1 ELSE 0 END END AS is_mob2_30plus
    ,CASE WHEN cur.hist_overdue_days IS NOT NULL
          THEN CASE WHEN cur.hist_overdue_days > 30 THEN 1 ELSE 0 END END   AS is_ever_30plus_to_date
    ,l.current_ovd_amt
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
LEFT JOIN debt m1  ON l.listing_id = m1.listing_id  AND TO_DATE(m1.dt)  = TO_DATE(l.mob1_dt)
LEFT JOIN debt m2  ON l.listing_id = m2.listing_id  AND TO_DATE(m2.dt)  = TO_DATE(l.mob2_dt)
LEFT JOIN debt cur ON l.listing_id = cur.listing_id AND TO_DATE(cur.dt) = l.obs_dt
;

-- ============================================================================
-- 第四步：4.2 放款月汇总（笔数 + 金额双口径）
-- 目的：按放款月份汇总，一眼看每个月的放款量、逾期率和 FPD。
-- 加工：把 4.1 的结果按 disburse_month 分组，笔数和金额分别统计。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_vintage_month;
CREATE TABLE model.tmp_eliam_wagego_vintage_month AS
SELECT
     disburse_month
    ,MAX(data_as_of)                                                             AS data_as_of
    ,COUNT(*)                                                                    AS loan_cnt
    ,ROUND(SUM(real_amount), 2)                                                  AS loan_amt
    ,SUM(CASE WHEN dpd_latest IS NOT NULL THEN 1 ELSE 0 END)                     AS obs_cnt
    ,ROUND(SUM(CASE WHEN dpd_latest IS NOT NULL THEN real_amount ELSE 0 END), 2) AS obs_amt
    ,SUM(CASE WHEN dpd_latest > 30 THEN 1 ELSE 0 END)                            AS cur_30plus_cnt
    ,ROUND(SUM(CASE WHEN dpd_latest > 30 THEN real_amount ELSE 0 END), 2)        AS cur_30plus_amt
    ,SUM(CASE WHEN dpd_latest > 0 THEN 1 ELSE 0 END)                             AS cur_ovd_cnt
    ,ROUND(SUM(current_ovd_amt), 2)                                              AS cur_ovd_amt
    ,ROUND(100.0 * SUM(CASE WHEN dpd_latest > 0 THEN 1 ELSE 0 END)
           / NULLIF(SUM(CASE WHEN dpd_latest IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS cur_ovd_rate
    ,ROUND(100.0 * SUM(current_ovd_amt)
           / NULLIF(SUM(CASE WHEN dpd_latest IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS cur_ovd_amt_rate
    ,SUM(is_ever_30plus_to_date)                                                 AS ever_30plus_cnt
    ,ROUND(SUM(CASE WHEN is_ever_30plus_to_date = 1 THEN real_amount ELSE 0 END), 2) AS ever_30plus_amt
    ,ROUND(100.0 * SUM(is_ever_30plus_to_date)
           / NULLIF(SUM(CASE WHEN dpd_latest IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS ever_30plus_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_ever_30plus_to_date = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN dpd_latest IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS ever_30plus_amt_rate
    ,SUM(CASE WHEN dpd_mob1 IS NOT NULL THEN 1 ELSE 0 END)                       AS mob1_obs_cnt
    ,ROUND(SUM(CASE WHEN dpd_mob1 IS NOT NULL THEN real_amount ELSE 0 END), 2)   AS mob1_obs_amt
    ,SUM(is_mob1_30plus)                                                         AS mob1_30plus_cnt
    ,ROUND(SUM(CASE WHEN is_mob1_30plus = 1 THEN real_amount ELSE 0 END), 2)     AS mob1_30plus_amt
    ,ROUND(100.0 * SUM(is_mob1_30plus)
           / NULLIF(SUM(CASE WHEN dpd_mob1 IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS mob1_30plus_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_mob1_30plus = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN dpd_mob1 IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS mob1_30plus_amt_rate
    ,SUM(CASE WHEN dpd_mob2 IS NOT NULL THEN 1 ELSE 0 END)                       AS mob2_obs_cnt
    ,ROUND(SUM(CASE WHEN dpd_mob2 IS NOT NULL THEN real_amount ELSE 0 END), 2)   AS mob2_obs_amt
    ,SUM(is_mob2_30plus)                                                         AS mob2_30plus_cnt
    ,ROUND(SUM(CASE WHEN is_mob2_30plus = 1 THEN real_amount ELSE 0 END), 2)     AS mob2_30plus_amt
    ,ROUND(100.0 * SUM(is_mob2_30plus)
           / NULLIF(SUM(CASE WHEN dpd_mob2 IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS mob2_30plus_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_mob2_30plus = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN dpd_mob2 IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS mob2_30plus_amt_rate
    ,SUM(is_fpd3_obs)                                                            AS fpd3_obs_cnt
    ,SUM(is_fpd3_ovd)                                                            AS fpd3_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd3_obs = 1 THEN real_amount ELSE 0 END), 2)        AS fpd3_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd3_ovd = 1 THEN real_amount ELSE 0 END), 2)        AS fpd3_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd3_ovd) / NULLIF(SUM(is_fpd3_obs), 0), 2)            AS fpd3_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd3_ovd = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_fpd3_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd3_ovd_amt_rate
    ,SUM(is_fpd7_obs)                                                            AS fpd7_obs_cnt
    ,SUM(is_fpd7_ovd)                                                            AS fpd7_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd7_obs = 1 THEN real_amount ELSE 0 END), 2)        AS fpd7_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd7_ovd = 1 THEN real_amount ELSE 0 END), 2)        AS fpd7_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd7_ovd) / NULLIF(SUM(is_fpd7_obs), 0), 2)            AS fpd7_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd7_ovd = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_fpd7_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd7_ovd_amt_rate
    ,SUM(is_fpd15_obs)                                                           AS fpd15_obs_cnt
    ,SUM(is_fpd15_ovd)                                                           AS fpd15_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd15_obs = 1 THEN real_amount ELSE 0 END), 2)       AS fpd15_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd15_ovd = 1 THEN real_amount ELSE 0 END), 2)       AS fpd15_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd15_ovd) / NULLIF(SUM(is_fpd15_obs), 0), 2)          AS fpd15_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd15_ovd = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_fpd15_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd15_ovd_amt_rate
    ,SUM(is_fpd30_obs)                                                           AS fpd30_obs_cnt
    ,SUM(is_fpd30_ovd)                                                           AS fpd30_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd30_obs = 1 THEN real_amount ELSE 0 END), 2)       AS fpd30_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd30_ovd = 1 THEN real_amount ELSE 0 END), 2)       AS fpd30_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd30_ovd) / NULLIF(SUM(is_fpd30_obs), 0), 2)          AS fpd30_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd30_ovd = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_fpd30_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd30_ovd_amt_rate
FROM model.tmp_eliam_wagego_vintage_loan
GROUP BY disburse_month
;

-- ============================================================================
-- 第五步：分群与滚动 Vintage 曲线（看不同客群随时间的逾期走势）
-- 5.1 长表 MOB（1-12 个月）
-- 目的：把每笔借款展开成 1~12 个月的观察点，为画 vintage 曲线做准备。
-- 加工：每笔借款 × 12 个 MOB，关联对应月末快照，打上是否到期、逾期 5+/30+ 的标签。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_vintage_mob;
CREATE TABLE model.tmp_eliam_wagego_vintage_mob AS
WITH mob AS (
    SELECT EXPLODE(SEQUENCE(1, 12)) AS mob_no
),
obs AS (
    SELECT
         s.loan_no
        ,s.user_id
        ,s.listing_id
        ,TO_DATE(s.disburse_time)                                     AS disburse_date
        ,s.disburse_month
        ,s.real_amount
        ,s.term_unit
        ,s.user_type
        ,s.application_rank
        ,s.data_as_of
        ,m.mob_no
        ,LAST_DAY(ADD_MONTHS(TO_DATE(s.disburse_time), m.mob_no))     AS obs_dt
    FROM model.tmp_eliam_wagego_vintage_loan s
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
    ,CASE WHEN o.obs_dt <= o.data_as_of THEN 1 ELSE 0 END AS is_matured
    ,d.current_overdue_days                                AS dpd
    ,CASE WHEN o.obs_dt <= o.data_as_of AND d.current_overdue_days IS NOT NULL
          THEN CASE WHEN d.current_overdue_days >= 5  THEN 1 ELSE 0 END END AS is_5plus
    ,CASE WHEN o.obs_dt <= o.data_as_of AND d.current_overdue_days IS NOT NULL
          THEN CASE WHEN d.current_overdue_days > 30 THEN 1 ELSE 0 END END AS is_30plus
FROM obs o
LEFT JOIN (
    SELECT
         listing_id
        ,dt
        ,CAST(current_overdue_days AS INT) AS current_overdue_days
    FROM edw_ewa.dwb_asset_debt_dtl_snp
    WHERE TO_DATE(dt) = LAST_DAY(TO_DATE(dt))
      AND CAST(period_no AS INT) = 1
) d
  ON o.listing_id = d.listing_id
 AND o.obs_dt      = TO_DATE(d.dt)
;

-- ============================================================================
-- 第五步：5.2 分群 × MOB 曲线（笔数 + 金额双口径）
-- 目的：按放款月和新老客汇总每个 MOB 的逾期率，直接用于画曲线。
-- 加工：把 5.1 的结果按放款月、新老客、MOB 分组，统计笔数和金额口径。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_vintage_curve;
CREATE TABLE model.tmp_eliam_wagego_vintage_curve AS
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
    ,ROUND(100.0 * SUM(is_5plus)
           / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS rate_5plus
    ,ROUND(100.0 * SUM(CASE WHEN is_5plus = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS rate_5plus_amt
    ,SUM(is_30plus)                                                                            AS cnt_30plus
    ,ROUND(SUM(CASE WHEN is_30plus = 1 THEN real_amount ELSE 0 END), 2)                        AS amt_30plus
    ,ROUND(100.0 * SUM(is_30plus)
           / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS rate_30plus
    ,ROUND(100.0 * SUM(CASE WHEN is_30plus = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS rate_30plus_amt
FROM model.tmp_eliam_wagego_vintage_mob
GROUP BY disburse_month, user_type, mob_no
;
