-- ============================================================================
-- WageGo 每日 Vintage 跑批（优化版）
-- 观察日自动取快照表最新分区，无需修改日期。
--
-- 依赖顺序：
--   param_obs_date
--     → stg_debt_snp
--     → dwd_loan_apply
--     → dwd_loan_debt       ← dwd_loan_apply + listing + stg_debt_snp + param
--     → dws_vintage_loan    ← dwd_loan_debt + param
--     → dws_vintage_mob     ← dws_vintage_loan + stg_debt_snp
--     → ads_vintage_month   ← dws_vintage_loan
--     → ads_vintage_curve   ← dws_vintage_mob
--
-- 表清单（粒度 / 主键 / 上游 → 下游）：
--   param_obs_date     1 行                    / obs_dt                     / 快照表 → 全链路
--   stg_debt_snp       listing_id × stat_date  / (listing_id, stat_date)    / 快照表 + 借款申请表 + param → dwd_loan_debt / dws_vintage_mob
--   dwd_loan_apply     loan_no                 / loan_no                    / 借款申请表 + 事件表 → dwd_loan_debt
--   dwd_loan_debt      loan_no                 / loan_no                    / dwd_loan_apply + listing + stg_debt_snp → dws_vintage_loan
--   dws_vintage_loan   loan_no                 / loan_no                    / dwd_loan_debt + param → dws_vintage_mob / ads_vintage_month
--   dws_vintage_mob    loan_no × mob_no        / (loan_no, mob_no)          / dws_vintage_loan + stg_debt_snp → ads_vintage_curve（仅曲线）
--   ads_vintage_month  disburse_month          / disburse_month             / dws_vintage_loan → 报表
--   ads_vintage_curve  disburse_month × user_type × mob_no / 三列同主键     / dws_vintage_mob → 报表
--
-- 口径说明（除统一标签窗口外，其余口径与优化前保持一致）：
--   1) 样本：ods_ewa / edw_ewa 原生表；当前按单期产品口径，借据快照取 period_no = 1。
--      已知后续会转多期：届时需按 period_no 展开，并重新确认借据级 MOB/FPD/逾期聚合口径。
--   2) 观察日：借据快照最新分区，作为 data_as_of。
--   3) 标签观察窗：统一锚定首个应还日 init_due_date，观察点 = init_due_date + 31 天
--      （30 天窗口，+1 天保证严格 >30 可被观察）。所有产品期限（7/14/30 天）共用同一窗口；
--      未到观察点的借据标签置 NULL，不提前记 0。
--      FPD3/7/15/30 仅表示同一观察点下的严重度分层，不再代表不同观察窗。
--   4) MOB1~MOB12 曲线保留在 dws_vintage_mob，按同 MOB 对齐，仅作描述性分析；
--      dws_vintage_loan 不再输出 MOB1/MOB2 标签。
--   5) 新老客：按用户首笔“放款成功”的借据判定（application_rank = 1 为 New），已确认。
--   6) 逾期阈值：30+ 为严格大于 30；5+ 为大于等于 5。
--   7) application_id / app_id 仅作展示，不参与关联；借款统一用 loan_no 关联。
--
-- 多期改造点（当前不实现，待产品上线后按业务口径调整）：
--   stg_debt_snp  : 粒度改为 listing_id × period_no × stat_date，主键加入 period_no，
--                   不再固定 period_no = 1。
--   dwd_loan_debt : 观察日快照需按 period_no 汇总；init_due_date / user_actual_repay_time
--                   不再取首期单值。
--   dws_vintage_* : 统一标签窗口需明确以哪一期应还日为锚点；多期下建议按借据最早未结清
--                   期次或全部期次汇总重新定义 DPD / 逾期金额 / FPD。
--   ads_*         : 需明确统计单位是“借据”还是“期次”，分母/分子同步调整。
-- ============================================================================

SET spark.sql.session.timeZone = Australia/Sydney;

-- ============================================================================
-- 第零步：观察日参数表
-- 粒度：1 行；主键：obs_dt
-- 目的：统一确定本次分析看到哪一天，供下游所有快照关联使用。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_param_obs_date;
CREATE TABLE model.tmp_eliam_wagego_param_obs_date AS
SELECT MAX(TO_DATE(dt)) AS obs_dt
FROM edw_ewa.dwb_asset_debt_dtl_snp
WHERE CAST(period_no AS INT) = 1;                         -- 当前单期口径；转多期见文件头“多期改造点”

-- ============================================================================
-- 第一步：债务快照子集（stg）
-- 粒度：listing_id × stat_date；主键：(listing_id, stat_date)
-- 上游：edw_ewa.dwb_asset_debt_dtl_snp + param_obs_date
-- 下游：dwd_loan_debt、dws_vintage_loan、dws_vintage_mob
-- 目的：把原来 3 次扫描快照（观察日、MOB1/2、12 个 MOB 月末）收敛为 1 次，
--       保留观察日、各月末以及日快照，供统一标签窗口（init_due_date + 31 天）精确取点。
-- 日期下界：最早借款申请月再往前 1 个月，覆盖所有借款的 MOB1~MOB12 观察点。
-- 当前单期口径：period_no = 1；转多期后需把 period_no 纳入粒度和主键。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_stg_debt_snp;
CREATE TABLE model.tmp_eliam_wagego_stg_debt_snp AS
SELECT
     d.listing_id
    ,TO_DATE(d.dt)                                        AS stat_date
    ,CAST(d.init_due_date AS DATE)                        AS init_due_date
    ,CAST(d.user_actual_repay_time AS TIMESTAMP)          AS user_actual_repay_time
    ,CAST(d.debt_status AS INT)                           AS debt_status
    ,CAST(d.hist_overdue_days AS INT)                     AS hist_overdue_days
    ,CAST(d.current_overdue_days AS INT)                  AS current_overdue_days
    ,CAST(d.principal AS DOUBLE)                          AS principal
    ,CAST(d.repay_amount AS DOUBLE)                       AS repay_amount
    ,CAST(d.owing_amount AS DOUBLE)                       AS owing_amount
FROM edw_ewa.dwb_asset_debt_dtl_snp d
CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
WHERE CAST(d.period_no AS INT) = 1                         -- 当前单期口径；转多期见文件头“多期改造点”
  AND TO_DATE(d.dt) <= p.obs_dt
  AND TO_DATE(d.dt) >= (
      SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
      FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
      WHERE CAST(a.isactive AS INT) = 1
  )
;                                                                 -- 保留日快照，支持任意 due+31 标签观察点

-- ============================================================================
-- 第二步：借款申请明细（dwd）
-- 粒度：loan_no；主键：loan_no（一行一个借款申请，覆盖成功/拒绝/过期/放款失败）
-- 上游：ods_ewa.aus_ewa_loan_biz_t_loan_application + ods_ewa.aus_ewa_risk_risk_event_task
-- 下游：dwd_loan_debt
-- 说明：原 application 表只被本表用到 4 个字段，这里直接内联，避免多落一张
--       18 万行的宽表；事件表按 flow_id 去重，保证 1:1 关联不放大行数。
--       apply_seq / is_first_apply_in_window 保留为样本属性，本 vintage 链路未使用；
--       新老客在 dws_vintage_loan 中按首笔放款判定。
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
        ,ROW_NUMBER() OVER (
             PARTITION BY a.user_id
             ORDER BY CAST(a.inserttime AS TIMESTAMP), a.loan_no
         )                                                    AS apply_seq
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
            ,ROW_NUMBER() OVER (
                 PARTITION BY e.flow_id
                 ORDER BY CAST(e.updatetime AS TIMESTAMP) DESC NULLS LAST,
                          CAST(e.inserttime AS TIMESTAMP) DESC NULLS LAST
             )                                                AS rn
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
         WHEN 'DISBURSE_SUCCESS' THEN '放款成功'
         WHEN 'DISBURSE'         THEN '放款中'
         WHEN 'DISBURSE_FAILED'  THEN '放款失败'
         WHEN 'AUDIT'            THEN '审核中'
         WHEN 'AUDIT_APPROVED'   THEN '审核通过'
         WHEN 'AUDIT_REJECTED'   THEN '审核拒绝'
         WHEN 'EXPIRED'          THEN '已过期'
         WHEN 'INFO_CHANGED'     THEN '信息变更'
         ELSE a.apply_status
     END                                                      AS apply_status_desc
    ,CASE WHEN a.apply_status = 'DISBURSE_SUCCESS' THEN 1 ELSE 0 END AS is_disburse_success
    ,CASE WHEN a.apply_status = 'AUDIT_REJECTED'   THEN 1 ELSE 0 END AS is_reject
    ,CASE WHEN a.apply_status = 'EXPIRED'          THEN 1 ELSE 0 END AS is_expired
    ,CASE WHEN a.apply_status = 'DISBURSE_FAILED'  THEN 1 ELSE 0 END AS is_disburse_failed
    ,a.apply_time
    ,TO_DATE(a.apply_time)                                    AS apply_date
    ,DATE_FORMAT(a.apply_time, 'yyyy-MM')                     AS apply_month
    ,CASE WHEN a.apply_status = 'DISBURSE_SUCCESS'
          THEN a.apply_disburse_time END                      AS disburse_time
    ,a.apply_seq
    ,CASE WHEN a.apply_seq = 1 THEN 1 ELSE 0 END              AS is_first_apply_in_window
    ,e.strategy_time
    ,e.retry_count
FROM apply a
LEFT JOIN event e
  ON a.loan_no = e.loan_no
;

-- ============================================================================
-- 第三步：借据 / 债务明细（dwd）
-- 粒度：loan_no；主键：loan_no（行数必须与 dwd_loan_apply 完全一致）
-- 上游：dwd_loan_apply + edw_ewa.dwb_asset_cmn_listing + stg_debt_snp
-- 下游：dws_vintage_loan
-- 目的：在每笔借款申请上补齐放款金额、期限、应还、实还、逾期及统一窗口标签。
-- 说明：listing 与快照均按唯一键关联，不做聚合，保证不改变申请级行数。
--       标签观察点 label_obs_dt = init_due_date + 31 天（30 天窗口，+1 天保证严格 >30
--       可被观察）；未到观察点的借据 is_label_matured = 0，窗口标签置 NULL。
--       FPD3/7/15/30 共用同一观察点，仅表示逾期严重度分层。
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
        ,CASE WHEN s.init_due_date IS NOT NULL
              THEN DATE_ADD(s.init_due_date, 31) END          AS label_obs_dt
        ,s.user_actual_repay_time
        ,s.debt_status
        ,CASE s.debt_status
             WHEN 1 THEN '未结清'
             WHEN 2 THEN '已结清'
             WHEN 4 THEN '逾期中'
             ELSE CAST(s.debt_status AS STRING)
         END                                                  AS debt_status_desc
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
        ,x.label_user_actual_repay_time
        ,x.label_debt_status
        ,x.label_hist_overdue_days
        ,x.label_current_overdue_days
        ,x.label_owing_amount
        ,CASE WHEN b.is_disburse_success = 1
               AND b.is_deal = 1
               AND b.debt_listing_id IS NOT NULL
               AND b.label_obs_dt IS NOT NULL
               AND b.label_obs_dt >= TO_DATE(b.disburse_time)
               AND b.label_obs_dt <= b.obs_dt
              THEN 1 ELSE 0 END                               AS is_label_matured
        ,COALESCE(
             x.label_user_actual_repay_time
            ,CASE WHEN b.user_actual_repay_time IS NOT NULL
                   AND TO_DATE(b.user_actual_repay_time) <= b.label_obs_dt
                  THEN b.user_actual_repay_time END
         )                                                    AS repay_at_label_obs
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
    ,CASE WHEN b.is_label_matured = 1
          THEN b.label_current_overdue_days END              AS dpd_at_label_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN b.label_hist_overdue_days END                 AS hist_dpd_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_current_overdue_days > 0 THEN 1 ELSE 0 END END
                                                             AS is_current_overdue_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_current_overdue_days > 0 THEN b.real_amount ELSE 0 END END
                                                             AS current_ovd_amt_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_current_overdue_days >= 5 THEN 1 ELSE 0 END END
                                                             AS is_5plus_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_current_overdue_days > 30 THEN 1 ELSE 0 END END
                                                             AS is_30plus_at_label_obs
    ,CASE WHEN b.is_label_matured = 1 AND b.label_hist_overdue_days IS NOT NULL
          THEN CASE WHEN b.label_hist_overdue_days > 30 THEN 1 ELSE 0 END END
                                                             AS is_ever_30plus_in_window
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END   AS is_fpd3_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL
                    THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END END
          END                                                AS is_fpd3_ovd
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END   AS is_fpd7_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL
                    THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END END
          END                                                AS is_fpd7_ovd
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END   AS is_fpd15_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL
                    THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 15) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 15) THEN 1 ELSE 0 END END
          END                                                AS is_fpd15_ovd
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END   AS is_fpd30_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL
                    THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END END
          END                                                AS is_fpd30_ovd
    ,CASE WHEN b.debt_listing_id IS NOT NULL
          THEN DATEDIFF(b.init_due_date, TO_DATE(b.disburse_time)) END
                                                             AS loan_term_contract_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL
          THEN DATEDIFF(TO_DATE(b.user_actual_repay_time), TO_DATE(b.disburse_time)) END
                                                             AS loan_term_actual_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL
          THEN CASE WHEN TO_DATE(b.user_actual_repay_time) < b.init_due_date
                    THEN 1 ELSE 0 END END
                                                             AS is_early_settlement
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL
          THEN CASE WHEN b.current_overdue_days > 0 THEN 1 ELSE 0 END END
                                                             AS is_current_overdue
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL
          THEN CASE WHEN b.current_overdue_days > 0 THEN b.real_amount ELSE 0 END END
                                                             AS current_ovd_amt
FROM base b
;

-- ============================================================================
-- 第四步：借据级 Vintage 标签（dws）
-- 粒度：loan_no；主键：loan_no（仅放款成功借据）
-- 上游：dwd_loan_debt + param_obs_date
-- 下游：dws_vintage_mob、ads_vintage_month
-- 目的：每笔放款借据一行，给出统一窗口（init_due_date + 31 天）的逾期、30+、5+、FPD
--       与新老客标签；MOB1~MOB12 曲线不在本表输出。
-- 说明：所有借据共用同一观察窗；未到观察点的借据 is_label_matured = 0，标签为 NULL。
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
        ,ROW_NUMBER() OVER (
             PARTITION BY a.user_id
             ORDER BY a.disburse_time, a.loan_no
         )                                                    AS application_rank
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
-- 第五步：借据 × MOB 长表（dws）
-- 粒度：loan_no × mob_no；主键：(loan_no, mob_no)
-- 上游：dws_vintage_loan + stg_debt_snp
-- 下游：ads_vintage_curve
-- 目的：把每笔借据展开为 MOB1~MOB12 观察点，供滚动 vintage 曲线使用。
-- 说明：本表仅作曲线描述，不进入建模宽表；每个 MOB 点按相同 mob_no 对齐。
--       未到期 MOB 保留（is_matured = 0），不改变原有样本范围。
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
-- 第六步：放款月汇总（ads）
-- 粒度：disburse_month；主键：disburse_month
-- 上游：dws_vintage_loan
-- 下游：报表
-- 目的：按放款月份汇总放款量、统一窗口（应还日 + 30 天）的逾期、30+ 与 FPD
--       笔数/金额双口径；MOB 曲线见 ads_vintage_curve。
-- 说明：matured_cnt 为已到标签观察点的借据数，是 FPD 与窗口标签的统一分母；
--       obs_cnt 为其中能取到 due+31 快照的借据数，是 current/ever 标签的分母。
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
    ,ROUND(100.0 * SUM(CASE WHEN is_current_overdue_at_label_obs = 1 THEN 1 ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS cur_ovd_rate
    ,ROUND(100.0 * SUM(current_ovd_amt_at_label_obs)
           / NULLIF(SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS cur_ovd_amt_rate
    ,COALESCE(SUM(is_ever_30plus_in_window), 0)                                  AS ever_30plus_cnt
    ,ROUND(SUM(CASE WHEN is_ever_30plus_in_window = 1 THEN real_amount ELSE 0 END), 2) AS ever_30plus_amt
    ,ROUND(100.0 * SUM(is_ever_30plus_in_window)
           / NULLIF(SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS ever_30plus_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_ever_30plus_in_window = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS ever_30plus_amt_rate
    ,COALESCE(SUM(is_fpd3_obs), 0)                                               AS fpd3_obs_cnt
    ,COALESCE(SUM(is_fpd3_ovd), 0)                                               AS fpd3_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd3_obs = 1 THEN real_amount ELSE 0 END), 2)        AS fpd3_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd3_ovd = 1 THEN real_amount ELSE 0 END), 2)        AS fpd3_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd3_ovd) / NULLIF(SUM(is_fpd3_obs), 0), 2)            AS fpd3_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd3_ovd = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_fpd3_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd3_ovd_amt_rate
    ,COALESCE(SUM(is_fpd7_obs), 0)                                               AS fpd7_obs_cnt
    ,COALESCE(SUM(is_fpd7_ovd), 0)                                               AS fpd7_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd7_obs = 1 THEN real_amount ELSE 0 END), 2)        AS fpd7_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd7_ovd = 1 THEN real_amount ELSE 0 END), 2)        AS fpd7_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd7_ovd) / NULLIF(SUM(is_fpd7_obs), 0), 2)            AS fpd7_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd7_ovd = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_fpd7_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd7_ovd_amt_rate
    ,COALESCE(SUM(is_fpd15_obs), 0)                                              AS fpd15_obs_cnt
    ,COALESCE(SUM(is_fpd15_ovd), 0)                                              AS fpd15_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd15_obs = 1 THEN real_amount ELSE 0 END), 2)       AS fpd15_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd15_ovd = 1 THEN real_amount ELSE 0 END), 2)       AS fpd15_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd15_ovd) / NULLIF(SUM(is_fpd15_obs), 0), 2)          AS fpd15_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd15_ovd = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_fpd15_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd15_ovd_amt_rate
    ,COALESCE(SUM(is_fpd30_obs), 0)                                              AS fpd30_obs_cnt
    ,COALESCE(SUM(is_fpd30_ovd), 0)                                              AS fpd30_ovd_cnt
    ,ROUND(SUM(CASE WHEN is_fpd30_obs = 1 THEN real_amount ELSE 0 END), 2)       AS fpd30_obs_amt
    ,ROUND(SUM(CASE WHEN is_fpd30_ovd = 1 THEN real_amount ELSE 0 END), 2)       AS fpd30_ovd_amt
    ,ROUND(100.0 * SUM(is_fpd30_ovd) / NULLIF(SUM(is_fpd30_obs), 0), 2)          AS fpd30_ovd_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_fpd30_ovd = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN is_fpd30_obs = 1 THEN real_amount ELSE 0 END), 0), 2) AS fpd30_ovd_amt_rate
FROM model.tmp_eliam_wagego_dws_vintage_loan
GROUP BY disburse_month
;

-- ============================================================================
-- 第七步：分群 × MOB 曲线汇总（ads）
-- 粒度：disburse_month × user_type × mob_no；主键：三列组合
-- 上游：dws_vintage_mob
-- 下游：报表 / 曲线
-- 目的：按放款月与新老客汇总每个 MOB 的逾期率，笔数与金额双口径。
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
FROM model.tmp_eliam_wagego_dws_vintage_mob
GROUP BY disburse_month, user_type, mob_no
;

-- ============================================================================
-- 校验（按需执行；默认注释，不参与每日跑批）
-- ============================================================================
-- 1) 主键唯一性：row_cnt 应等于 pk_cnt
-- SELECT 'dwd_loan_apply'       AS tbl, COUNT(*) AS row_cnt, COUNT(DISTINCT loan_no) AS pk_cnt
-- FROM model.tmp_eliam_wagego_dwd_loan_apply
-- UNION ALL
-- SELECT 'stg_debt_snp', COUNT(*), COUNT(DISTINCT CONCAT(listing_id, '|', stat_date))
-- FROM model.tmp_eliam_wagego_stg_debt_snp
-- UNION ALL
-- SELECT 'dwd_loan_debt', COUNT(*), COUNT(DISTINCT loan_no)
-- FROM model.tmp_eliam_wagego_dwd_loan_debt
-- UNION ALL
-- SELECT 'dws_vintage_loan', COUNT(*), COUNT(DISTINCT loan_no)
-- FROM model.tmp_eliam_wagego_dws_vintage_loan
-- UNION ALL
-- SELECT 'dws_vintage_mob', COUNT(*), COUNT(DISTINCT CONCAT(loan_no, '|', mob_no))
-- FROM model.tmp_eliam_wagego_dws_vintage_mob
-- UNION ALL
-- SELECT 'ads_vintage_month', COUNT(*), COUNT(DISTINCT disburse_month)
-- FROM model.tmp_eliam_wagego_ads_vintage_month
-- UNION ALL
-- SELECT 'ads_vintage_curve', COUNT(*), COUNT(DISTINCT CONCAT(disburse_month, '|', user_type, '|', mob_no))
-- FROM model.tmp_eliam_wagego_ads_vintage_curve;

-- 2) 关联扇出：申请数与借据明细数必须一致
-- SELECT
--     (SELECT COUNT(*) FROM model.tmp_eliam_wagego_dwd_loan_apply) AS apply_cnt,
--     (SELECT COUNT(*) FROM model.tmp_eliam_wagego_dwd_loan_debt)  AS debt_cnt;

-- 3) 样本一致性：vintage 借据数必须等于放款成功申请数
-- SELECT
--     (SELECT COUNT(*) FROM model.tmp_eliam_wagego_dwd_loan_debt WHERE is_disburse_success = 1) AS disburse_cnt,
--     (SELECT COUNT(*) FROM model.tmp_eliam_wagego_dws_vintage_loan)                            AS vintage_loan_cnt;

-- 4) 汇总一致性：月度汇总与曲线 cohort 均不应丢借据
-- SELECT
--     (SELECT COUNT(*) FROM model.tmp_eliam_wagego_dws_vintage_loan)       AS loan_cnt,
--     (SELECT SUM(loan_cnt) FROM model.tmp_eliam_wagego_ads_vintage_month) AS month_loan_cnt,
--     (SELECT SUM(cohort_cnt) / 12 FROM model.tmp_eliam_wagego_ads_vintage_curve) AS curve_loan_cnt;

-- 5) 标签关系：逾期笔数不得超过观察笔数
-- SELECT disburse_month
-- FROM model.tmp_eliam_wagego_ads_vintage_month
-- WHERE cur_30plus_cnt > obs_cnt
--    OR cur_ovd_cnt    > obs_cnt
--    OR ever_30plus_cnt > obs_cnt
--    OR fpd3_ovd_cnt   > fpd3_obs_cnt
--    OR fpd7_ovd_cnt   > fpd7_obs_cnt
--    OR fpd15_ovd_cnt  > fpd15_obs_cnt
--    OR fpd30_ovd_cnt  > fpd30_obs_cnt;

-- 6) 标签窗口覆盖：已成熟借据应有 due+31 快照；missing_snp_cnt 应接近 0
-- SELECT
--     COUNT(*) AS loan_cnt,
--     SUM(is_label_matured) AS matured_cnt,
--     SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN 1 ELSE 0 END) AS label_snp_cnt,
--     SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NULL THEN 1 ELSE 0 END) AS missing_snp_cnt
-- FROM model.tmp_eliam_wagego_dws_vintage_loan;

-- 7) FPD 严重度应单调：FPD30 ⊆ FPD15 ⊆ FPD7 ⊆ FPD3
-- SELECT COUNT(*) AS violation_cnt
-- FROM model.tmp_eliam_wagego_dws_vintage_loan
-- WHERE is_fpd3_ovd < is_fpd7_ovd
--    OR is_fpd7_ovd < is_fpd15_ovd
--    OR is_fpd15_ovd < is_fpd30_ovd;

-- 8) 统一观察点下，FPD 分母应等于已成熟借据数
-- SELECT disburse_month
-- FROM model.tmp_eliam_wagego_ads_vintage_month
-- WHERE fpd3_obs_cnt  <> matured_cnt
--    OR fpd7_obs_cnt  <> matured_cnt
--    OR fpd15_obs_cnt <> matured_cnt
--    OR fpd30_obs_cnt <> matured_cnt;
