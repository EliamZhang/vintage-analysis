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
-- 第一步：借款申请明细（dwd_loan_apply）
-- 粒度：借款申请（loan_no），一行一个申请（含成功/拒绝/过期/放款失败）
-- 上游：ods_ewa.aus_ewa_loan_biz_t_loan_application + ods_ewa.aus_ewa_risk_risk_event_task
-- 下游：dwd_loan_debt、dwd_loan_stamp
-- 加工逻辑：借款申请表（ods_ewa.aus_ewa_loan_biz_t_loan_application）是用户提交的借款申请，一行一个申请（loan_no）；
--   风控事件表（ods_ewa.aus_ewa_risk_risk_event_task）记录风控流程流转，这里只取 biz_id = 20050、flow_id 以 LN 开头的事件，
--   并按 flow_id 取最新一条（updatetime 优先、inserttime 兜底），避免一次流程多条事件把申请行数放大；
--   以有效申请（isactive = 1）为主表 LEFT JOIN 事件表，补申请状态（apply_status）中文、成功/拒绝/过期/放款失败标记（is_disburse_success 等）和放款时间（disburse_time）；
--   最后按用户申请时间（inserttime）生成申请序号（apply_seq）。
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
-- 第二步：戳额表（dwd_loan_stamp）
-- 粒度：借款申请（loan_no），一行一个申请
-- 上游：dwd_loan_apply + ods_ewa.aus_listing_tb_loan_limit_apply
--       + ods_ewa.aus_ewa_risk_risk_event_task + ods_ewa.aus_listing_tb_loan_user_limit_log
-- 下游：下游分析 / 建模取数
-- 目的：为每个借款申请（loan_no）匹配同一用户（user_id）在申请时间（apply_time）前
--       最近一次戳额时点（stamp_time），并带出当时额度；不要求放款成功。
-- 加工逻辑：借款申请明细（dwd_loan_apply）提供每个申请（loan_no）的用户（user_id）和申请时间（apply_time）；
--   额度申请表（ods_ewa.aus_listing_tb_loan_limit_apply）记录用户主动戳额，biz_type = 400 为戳额动作；
--   风控事件表（ods_ewa.aus_ewa_risk_risk_event_task）中 biz_id = 10000 的记录是历史戳额，仅在额度申请表没有匹配记录时兜底；
--   每个申请按 user_id 取申请时间之前最近一条戳额（stamp_time），得到戳额来源（stamp_source）和戳额流水（flow_no）；
--   再用 flow_no = relate_id 关联额度日志表（ods_ewa.aus_listing_tb_loan_user_limit_log），取 event_type = 1、limit_category = 1 的记录带出戳额时点额度。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_stamp;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_stamp AS
WITH stamp AS (
    SELECT
         a.borrower_id                                        AS user_id
        ,CAST(a.inserttime AS TIMESTAMP)                      AS stamp_time
        ,a.limit_apply_no
        ,a.flow_no
        ,CAST(a.id AS BIGINT)                                 AS stamp_id
        ,'limit_apply'                                        AS stamp_source
        ,1                                                    AS source_priority
    FROM ods_ewa.aus_listing_tb_loan_limit_apply a
    WHERE CAST(a.isactive AS INT) = 1
      AND CAST(a.biz_type AS INT) = 400
    UNION ALL
    SELECT
         e.user_id
        ,CAST(e.inserttime AS TIMESTAMP)
        ,CAST(NULL AS STRING)
        ,e.flow_id
        ,CAST(e.id AS BIGINT)
        ,'risk_event'
        ,2
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
matched AS (
    SELECT
         a.loan_no
        ,s.stamp_time
        ,s.limit_apply_no
        ,s.flow_no
        ,s.stamp_source
        ,ROW_NUMBER() OVER (PARTITION BY a.loan_no ORDER BY s.source_priority, s.stamp_time DESC, s.stamp_id DESC) AS rn
    FROM model.tmp_eliam_wagego_dwd_loan_apply a
    JOIN stamp s
      ON a.user_id = s.user_id
     AND s.stamp_time <= a.apply_time
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
     a.loan_no
    ,a.user_id
    ,a.apply_time
    ,m.stamp_time
    ,DATEDIFF(TO_DATE(a.apply_time), TO_DATE(m.stamp_time))    AS stamp_to_apply_days
    ,m.stamp_source
    ,m.limit_apply_no
    ,m.flow_no                                               AS stamp_flow_no
    ,g.limit_total_before
    ,g.limit_total_after
    ,g.limit_available_after
    ,g.limit_occupied_after
    ,g.limit_expire_time
FROM model.tmp_eliam_wagego_dwd_loan_apply a
LEFT JOIN matched m
  ON a.loan_no = m.loan_no
 AND m.rn = 1
LEFT JOIN limit_grant g
  ON m.flow_no = g.relate_id
 AND g.rn = 1
;

-- ============================================================================
-- 第三步：债务快照子集（stg_debt_snp）
-- 粒度：借款（listing_id）× 快照日期（stat_date），一个借款一天一行
-- 上游：
--   edw_ewa.dwb_asset_debt_dtl_snp
--   ods_ewa.aus_ewa_loan_biz_t_loan_application
--   model.tmp_eliam_wagego_param_obs_date
-- 下游：dwd_loan_debt、dws_vintage_loan
-- 日期范围：最早申请日前 1 个月 ~ 观察日（obs_dt）。
-- 目的：把多期快照聚合成一个借款一天一行，供标签窗口（init_due_date + 31 天）和 MOB 观察点取数。
-- 加工逻辑：债务快照表（edw_ewa.dwb_asset_debt_dtl_snp）一行是借款（listing_id）× 期次（period_no）× 日期（dt），
--   这里按借款（listing_id）× 日期（dt）聚合，把多期压成一行：应还日（init_due_date）取 MIN、逾期天数（current_overdue_days、hist_overdue_days）取 MAX、
--   金额（principal、repay_amount、owing_amount）取 SUM、债务状态（debt_status）取最差（4 逾期中 > 1 未结清 > 2 已结清）；
--   还款时间拆两个：首期还款时间（first_repay_time）只取 period_no = 1，供 FPD 判定；结清时间（user_actual_repay_time）只在全部期次结清时取 MAX，否则为 NULL；
--   扫描范围取借款申请表（ods_ewa.aus_ewa_loan_biz_t_loan_application）最早申请时间（inserttime）前 1 个月，到观察日参数表（param_obs_date）的 obs_dt。
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
-- 第四步：借款 / 债务明细（dwd_loan_debt）
-- 粒度：借款申请（loan_no），行数与 dwd_loan_apply 一致
-- 上游：dwd_loan_apply + edw_ewa.dwb_asset_cmn_listing + stg_debt_snp
-- 下游：dwd_loan_disburse_sample、dwd_disbursed_loan、dws_vintage_loan
-- 目的：给每笔借款申请补上放款金额（real_amount）、期限（term_quantity / term_unit）、
--       债务状态（debt_status）、还款时间（user_actual_repay_time）、逾期天数（current_overdue_days）
--       和统一窗口标签。
-- 加工逻辑：以借款申请（dwd_loan_apply）为主表（一行一个 loan_no），CROSS JOIN 观察日参数表（param_obs_date）拿到 obs_dt；
--   1) 按 listing_id LEFT JOIN 放款信息表（edw_ewa.dwb_asset_cmn_listing），补放款金额（real_amount、apply_amount）、利息和费用（interest、service_fee）、
--      期限（term_quantity、term_unit、total_period）、是否成交（is_deal）、放款时间（withdraw_time）和合同应还日（list_due_date）；
--   2) 按 listing_id + stat_date = obs_dt LEFT JOIN 借款日快照（stg_debt_snp），取观察日当天的 init_due_date、first_repay_time、user_actual_repay_time、
--      debt_status、hist_overdue_days、current_overdue_days 和金额，并用 init_due_date + 31 算出标签观察日（label_obs_dt）；
--   3) 再按 listing_id + stat_date = label_obs_dt 关联一次快照，得到标签日口径，字段统一加 label_ 前缀；
--   4) 判定标签是否成熟（is_label_matured）：放款成功、is_deal = 1、有债务快照、标签观察日存在且落在放款日与 obs_dt 之间；
--   5) 成熟后计算标签：标签日 DPD（dpd_at_label_obs）、历史最大 DPD（hist_dpd_at_label_obs）、当前逾期（is_current_overdue_at_label_obs）、
--      5+（is_5plus_at_label_obs，DPD >= 5）、30+（is_30plus_at_label_obs，DPD > 30）、窗口内曾 30+（is_ever_30plus_in_window）、
--      FPD3/7/14/30（is_fpdN_obs / is_fpdN_ovd，还款时间晚于 init_due_date + N 记逾期；无还款时间时用 label_obs_dt 是否超过阈值判断）；
--   6) 同时计算合同期限（loan_term_contract_days = init_due_date - 放款日）、实际期限（loan_term_actual_days）、早结清（is_early_settlement）、
--      观察日当前逾期（is_current_overdue、current_ovd_amt，仅 is_deal = 1 时计算）；
--   未成熟的借款标签统一为 NULL；FPD 还款时间优先取标签日快照，缺失时用观察日快照中不晚于 label_obs_dt 的首期还款时间回补。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_debt;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_debt AS
WITH base AS (
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
        ,ls.user_actual_repay_time                            AS label_user_actual_repay_time
        ,ls.debt_status                                       AS label_debt_status
        ,ls.current_overdue_days                              AS label_current_overdue_days
        ,ls.hist_overdue_days                                 AS label_hist_overdue_days
        ,ls.owing_amount                                      AS label_owing_amount
        ,CASE WHEN a.is_disburse_success = 1 AND CAST(l.is_deal AS INT) = 1
               AND s.listing_id IS NOT NULL AND s.init_due_date IS NOT NULL
               AND DATE_ADD(s.init_due_date, 31) >= TO_DATE(a.disburse_time)
               AND DATE_ADD(s.init_due_date, 31) <= p.obs_dt
              THEN 1 ELSE 0 END                               AS is_label_matured
        ,COALESCE(ls.first_repay_time,
                  CASE WHEN s.first_repay_time IS NOT NULL
                        AND TO_DATE(s.first_repay_time) <= DATE_ADD(s.init_due_date, 31)
                       THEN s.first_repay_time END)            AS repay_at_label_obs
    FROM model.tmp_eliam_wagego_dwd_loan_apply a
    CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON a.listing_id = s.listing_id
     AND s.stat_date = p.obs_dt
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp ls
      ON a.listing_id = ls.listing_id
     AND ls.stat_date = DATE_ADD(s.init_due_date, 31)
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
    ,CASE WHEN b.is_label_matured = 1 THEN 1 END AS is_fpd3_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN COALESCE(TO_DATE(b.repay_at_label_obs), b.label_obs_dt) > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END END AS is_fpd3_ovd
    ,CASE WHEN b.is_label_matured = 1 THEN 1 END AS is_fpd7_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN COALESCE(TO_DATE(b.repay_at_label_obs), b.label_obs_dt) > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END END AS is_fpd7_ovd
    ,CASE WHEN b.is_label_matured = 1 THEN 1 END AS is_fpd14_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN COALESCE(TO_DATE(b.repay_at_label_obs), b.label_obs_dt) > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END END AS is_fpd14_ovd
    ,CASE WHEN b.is_label_matured = 1 THEN 1 END AS is_fpd30_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN COALESCE(TO_DATE(b.repay_at_label_obs), b.label_obs_dt) > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END END AS is_fpd30_ovd
    ,CASE WHEN b.debt_listing_id IS NOT NULL THEN DATEDIFF(b.init_due_date, TO_DATE(b.disburse_time)) END AS loan_term_contract_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN DATEDIFF(TO_DATE(b.user_actual_repay_time), TO_DATE(b.disburse_time)) END AS loan_term_actual_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN CASE WHEN TO_DATE(b.user_actual_repay_time) < b.init_due_date THEN 1 ELSE 0 END END AS is_early_settlement
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN 1 ELSE 0 END END AS is_current_overdue
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS current_ovd_amt
FROM base b
;

-- ============================================================================
-- 第五步：放款样本表（dwd_loan_disburse_sample）
-- 粒度：借款申请（loan_no），一行一个申请
-- 上游：dwd_loan_debt
-- 下游：放款样本分析
-- 目的：保留所有走到支用/放款环节的申请，不要求最终成交（is_deal = 1）或放款成功。
-- 加工逻辑：从借款 / 债务明细（dwd_loan_debt）中筛选申请状态为 DISBURSE（放款中）、
--   DISBURSE_SUCCESS（放款成功）、DISBURSE_FAILED（放款失败）的记录；
--   字段与 dwd_loan_debt 完全一致，便于直接复用下游标签和金额口径。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_disburse_sample;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_disburse_sample AS
SELECT *
FROM model.tmp_eliam_wagego_dwd_loan_debt
WHERE apply_status IN ('DISBURSE', 'DISBURSE_SUCCESS', 'DISBURSE_FAILED')
;

-- ============================================================================
-- 第六步：放款成功表（dwd_disbursed_loan）
-- 粒度：借款申请（loan_no），只保留放款成功（is_disburse_success = 1）的记录
-- 上游：dwd_loan_debt
-- 下游：下游分析 / 建模取数
-- 目的：作为通用放款样本表。
-- 加工逻辑：借款明细（dwd_loan_debt）已含申请、放款和标签，这里只保留放款成功（is_disburse_success = 1）的申请（loan_no）；
--   按用户（user_id）放款时间（disburse_time）升序生成放款序号（application_rank），1 表示该用户首笔成功放款；
--   输出放款基础属性（listing_id、金额、期限、应还日）、放款日期（disburse_date）、放款月（disburse_month）
--   和放款序号（application_rank），并打新老客（New/Old）。
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
    ,application_rank
    ,CASE WHEN application_rank = 1 THEN 'New' ELSE 'Old' END AS user_type
FROM disbursed
;

-- ============================================================================
-- 第七步：借款级 Vintage 宽表（dws_vintage_loan）
-- 粒度：借款申请（loan_no），一行一笔
-- 上游：dwd_loan_debt + dwd_disbursed_loan + stg_debt_snp + param_obs_date
-- 下游：暂无
-- 目的：每笔放款一行，输出借款属性、统一窗口（init_due_date + 31 天）的标签，
--       以及 MOB1~MOB12 观察点的 5+ / 30+ 标记。
-- 加工逻辑：借款明细（dwd_loan_debt）已算好观察日标签，放款成功表（dwd_disbursed_loan）已算好放款序号（application_rank），
--   两者按借款申请（loan_no）关联，取放款成功借款的属性和标签，1 表示新客（New），其余为老客（Old）；
--   输出放款属性、全部标签列、标签观察日（label_obs_dt）、数据截止日（data_as_of = obs_dt）和在贷天数（days_on_book）；
--   再把每笔放款按 MOB1~MOB12 展开，观察日（obs_dt）= LAST_DAY(ADD_MONTHS(disburse_time, mob_no))，
--   按借款（listing_id）+ 观察日（stat_date）关联借款日快照（stg_debt_snp）取逾期天数，>= 5 记 5+，> 30 记 30+；
--   观察日超过数据截止日或没有快照时标记为 NULL，最后按借款聚合回一行，输出 mob1_5plus ~ mob12_30plus。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dws_vintage_loan;
CREATE TABLE model.tmp_eliam_wagego_dws_vintage_loan AS
WITH loan AS (
    SELECT
         b.loan_no
        ,b.user_id
        ,b.listing_id
        ,b.disburse_time
        ,b.disburse_month
        ,b.real_amount
        ,b.term_unit
        ,b.init_due_date
        ,a.label_obs_dt
        ,a.is_label_matured
        ,p.obs_dt                                             AS data_as_of
        ,DATEDIFF(p.obs_dt, TO_DATE(b.disburse_time))         AS days_on_book
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
        ,a.is_fpd14_obs
        ,a.is_fpd14_ovd
        ,a.is_fpd30_obs
        ,a.is_fpd30_ovd
        ,b.application_rank
        ,CASE WHEN b.application_rank = 1 THEN 'New' ELSE 'Old' END AS user_type
    FROM model.tmp_eliam_wagego_dwd_loan_debt a
    JOIN model.tmp_eliam_wagego_dwd_disbursed_loan b
      ON a.loan_no = b.loan_no
    CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
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
     w.*
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
FROM loan w
LEFT JOIN mob_wide m
  ON w.loan_no = m.loan_no
;
