/*
===============================================================================
WageGo Vintage 数据同步 SQL
适用语法：Spark SQL / Hive 风格（与《样本表准备以及Y标签表准备.sql》一致）

本文件分两部分，sync.py 按段号顺序执行，结果分别落到两个目录：
1. 原始数据（段 1–6）：本次分析依赖的 6 张底表
     - ods_ewa.aus_ewa_loan_biz_t_loan_application
     - edw_ewa.dwb_asset_cmn_listing
     - edw_ewa.dwb_asset_debt_dtl_snp
     - ods_ewa.aus_ewa_risk_risk_event_task
     - ods_ewa.aus_listing_tb_loan_limit_apply
     - ods_ewa.aus_listing_tb_loan_user_limit_log
2. 查询结果（段 7–14）：《样本表准备以及Y标签表准备.sql》中的 8 张加工表
     param_obs_date / stg_debt_snp / dwd_loan_apply / dwd_loan_debt /
     dwd_loan_disburse_sample / dwd_disbursed_loan / dwd_loan_stamp /
     dws_vintage_loan

重要说明：
- 数据库里没有 model.tmp_eliam_wagego_* 这几张表，因此每个结果段都是自包含查询：
  把上游所有 CTE / 子查询原样内联在本段内，直接返回该表应有的结果，不创建也不依赖任何物理表。
  如果以后在库里持久化了中间表，可以把对应段改回 SELECT * FROM model.tmp_eliam_wagego_xxx。
- 每段以分号结尾。sync.py 按分号切段，段名取自段首注释的「N. 段名」。
- 加工口径以《样本表准备以及Y标签表准备.sql》为准，本文件只是把 CREATE TABLE AS 改成可独立执行的 SELECT。
- 源脚本开头的 SET spark.sql.session.timeZone = Australia/Sydney 由执行环境负责；
  请保持同一时区执行，避免 TO_DATE / DATE_FORMAT 在跨时区会话下产生日期偏移。
- 底表按原表全量取数。风控事件表只保留本流程用到的 biz_id = 20050（借款申请事件）
  和 biz_id = 10000（历史戳额事件），避免把无关风控记录打进数据包。
===============================================================================
*/


/*
===============================================================================
1. 借款申请表（原始数据）
源表：ods_ewa.aus_ewa_loan_biz_t_loan_application
粒度：一行一个借款申请（loan_no）
用途：样本表的主表，提供申请状态、用户、listing 和申请时间。
===============================================================================
*/
SELECT *
FROM ods_ewa.aus_ewa_loan_biz_t_loan_application
;


/*
===============================================================================
2. 放款信息表（原始数据）
源表：edw_ewa.dwb_asset_cmn_listing
粒度：一行一笔放款（listing_id）
用途：补放款金额、期限、是否成交、放款时间和合同应还日。
===============================================================================
*/
SELECT *
FROM edw_ewa.dwb_asset_cmn_listing
;


/*
===============================================================================
3. 债务快照表（原始数据）
源表：edw_ewa.dwb_asset_debt_dtl_snp
粒度：借款（listing_id）× 期次（period_no）× 快照日期（dt）
用途：提供每日债务状态、应还日、还款时间、逾期天数和金额。
===============================================================================
*/
SELECT *
FROM edw_ewa.dwb_asset_debt_dtl_snp
;


/*
===============================================================================
4. 风控事件表（原始数据，按流程裁剪）
源表：ods_ewa.aus_ewa_risk_risk_event_task
粒度：一行一条风控事件
用途：biz_id = 20050 的记录用于补借款申请的策略时间等信息；
      biz_id = 10000 的记录作为历史戳额兜底来源。
说明：只取有效记录（is_active = 1）和本流程用到的两类 biz_id。
===============================================================================
*/
SELECT *
FROM ods_ewa.aus_ewa_risk_risk_event_task
WHERE CAST(is_active AS INT) = 1
  AND CAST(biz_id AS STRING) IN ('20050', '10000')
;


/*
===============================================================================
5. 额度申请表（原始数据）
源表：ods_ewa.aus_listing_tb_loan_limit_apply
粒度：一行一次额度申请（limit_apply_no）
用途：biz_type = 400 的记录是用户主动戳额，用于匹配放款前最近一次戳额时点。
===============================================================================
*/
SELECT *
FROM ods_ewa.aus_listing_tb_loan_limit_apply
;


/*
===============================================================================
6. 额度日志表（原始数据）
源表：ods_ewa.aus_listing_tb_loan_user_limit_log
粒度：一行一条额度变动日志（id）
用途：event_type = 1、limit_category = 1 的记录带出戳额时点的额度。
===============================================================================
*/
SELECT *
FROM ods_ewa.aus_listing_tb_loan_user_limit_log
;


/*
===============================================================================
7. 观察日参数表（查询结果）
对应加工表：model.tmp_eliam_wagego_param_obs_date
粒度：1 行
上游：edw_ewa.dwb_asset_debt_dtl_snp
加工逻辑：取债务快照表全表最新快照日 MAX(TO_DATE(dt)) 作为本次分析的观察日（obs_dt），
  下游所有快照取数都以这一天为准。
===============================================================================
*/
SELECT MAX(TO_DATE(dt)) AS obs_dt
FROM edw_ewa.dwb_asset_debt_dtl_snp
;


/*
===============================================================================
8. 债务快照子集（查询结果）
对应加工表：model.tmp_eliam_wagego_stg_debt_snp
粒度：借款（listing_id）× 快照日期（stat_date），一个借款一天一行
上游：
  edw_ewa.dwb_asset_debt_dtl_snp
  ods_ewa.aus_ewa_loan_biz_t_loan_application
加工逻辑：债务快照一行是借款 × 期次 × 日期，这里按借款 × 日期聚合：
  应还日（init_due_date）取 MIN、逾期天数（current_overdue_days、hist_overdue_days）取 MAX、
  金额（principal、repay_amount、owing_amount）取 SUM、债务状态（debt_status）取最差
  （4 逾期中 > 1 未结清 > 2 已结清）；
  首期还款时间（first_repay_time）只取 period_no = 1，供 FPD 判定；
  结清时间（user_actual_repay_time）只在全部期次结清时取 MAX，否则为 NULL；
  扫描范围为最早有效申请日前 1 个月到观察日（obs_dt）。
===============================================================================
*/
WITH param_obs_date AS (
    SELECT MAX(TO_DATE(dt)) AS obs_dt
    FROM edw_ewa.dwb_asset_debt_dtl_snp
)
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
CROSS JOIN param_obs_date p
WHERE TO_DATE(d.dt) <= p.obs_dt
  AND TO_DATE(d.dt) >= (
      SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
      FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
      WHERE CAST(a.isactive AS INT) = 1
  )
GROUP BY d.listing_id, TO_DATE(d.dt)
;


/*
===============================================================================
9. 借款申请明细（查询结果）
对应加工表：model.tmp_eliam_wagego_dwd_loan_apply
粒度：借款申请（loan_no），一行一个申请（含成功 / 拒绝 / 过期 / 放款失败）
上游：
  ods_ewa.aus_ewa_loan_biz_t_loan_application
  ods_ewa.aus_ewa_risk_risk_event_task
加工逻辑：以有效申请（isactive = 1）为主表，补申请状态中文、成功 / 拒绝 / 过期 /
  放款失败标记和放款时间；风控事件只取 biz_id = 20050、flow_id 以 LN 开头的事件，
  按 flow_id 取最新一条（updatetime 优先、inserttime 兜底），避免一次流程多条事件放大行数；
  按用户申请时间生成申请序号（apply_seq）。
===============================================================================
*/
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


/*
===============================================================================
10. 借款 / 债务明细（查询结果）
对应加工表：model.tmp_eliam_wagego_dwd_loan_debt
粒度：借款申请（loan_no），行数与 dwd_loan_apply 一致
上游：
  dwd_loan_apply
  edw_ewa.dwb_asset_cmn_listing
  stg_debt_snp
加工逻辑：以借款申请明细为主表，CROSS JOIN 观察日参数拿到 obs_dt；
  1) 按 listing_id 关联放款信息表，补放款金额、利息费用、期限、是否成交和合同应还日；
  2) 按 listing_id + stat_date = obs_dt 关联借款日快照，取观察日当天的债务状态和金额，
     并用 init_due_date + 31 算出标签观察日（label_obs_dt）；
  3) 再按 listing_id + stat_date = label_obs_dt 关联一次快照，得到标签日口径；
  4) 判定标签是否成熟（is_label_matured）；
  5) 成熟后计算标签日 DPD、历史最大 DPD、当前逾期、5+、30+、窗口内曾 30+ 和 FPD3/7/14/30；
  6) 计算合同期限、实际期限、早结清和观察日当前逾期。
===============================================================================
*/
WITH param_obs_date AS (
    SELECT MAX(TO_DATE(dt)) AS obs_dt
    FROM edw_ewa.dwb_asset_debt_dtl_snp
),
stg_debt_snp AS (
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
    CROSS JOIN param_obs_date p
    WHERE TO_DATE(d.dt) <= p.obs_dt
      AND TO_DATE(d.dt) >= (
          SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
          FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
          WHERE CAST(a.isactive AS INT) = 1
      )
    GROUP BY d.listing_id, TO_DATE(d.dt)
),
apply AS (
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
         END AS apply_status_desc
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
),
latest AS (
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
    FROM loan_apply a
    CROSS JOIN param_obs_date p
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
    LEFT JOIN stg_debt_snp s
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
    LEFT JOIN stg_debt_snp s
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
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd14_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END END END AS is_fpd14_ovd
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


/*
===============================================================================
11. 放款成功表（查询结果）
对应加工表：model.tmp_eliam_wagego_dwd_disbursed_loan
粒度：借款申请（loan_no），只保留放款成功的记录
上游：dwd_loan_debt
加工逻辑：从借款债务明细中保留 is_disburse_success = 1 的申请，按用户放款时间升序
  生成放款序号（application_rank），1 表示该用户首笔成功放款；
  输出放款基础属性、放款日期和放款月，并打新老客（New / Old）。
说明：本段只需要放款相关字段，内联的 dwd_loan_debt 只保留必要列，结果与全量版本一致。
===============================================================================
*/
WITH param_obs_date AS (
    SELECT MAX(TO_DATE(dt)) AS obs_dt
    FROM edw_ewa.dwb_asset_debt_dtl_snp
),
stg_debt_snp AS (
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
    CROSS JOIN param_obs_date p
    WHERE TO_DATE(d.dt) <= p.obs_dt
      AND TO_DATE(d.dt) >= (
          SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
          FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
          WHERE CAST(a.isactive AS INT) = 1
      )
    GROUP BY d.listing_id, TO_DATE(d.dt)
),
apply AS (
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
         END AS apply_status_desc
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
),
latest AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,a.is_disburse_success
        ,a.disburse_time
        ,CAST(l.real_amount AS DOUBLE)                        AS real_amount
        ,CAST(l.term_quantity AS INT)                         AS term_quantity
        ,l.term_unit
        ,s.init_due_date
    FROM loan_apply a
    CROSS JOIN param_obs_date p
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
    LEFT JOIN stg_debt_snp s
      ON a.listing_id = s.listing_id
     AND s.stat_date = p.obs_dt
),
disbursed AS (
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
    FROM latest
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


/*
===============================================================================
12. 戳额表（查询结果）
对应加工表：model.tmp_eliam_wagego_dwd_loan_stamp
粒度：借款申请（loan_no），一行一笔放款
上游：
  dwd_disbursed_loan
  ods_ewa.aus_listing_tb_loan_limit_apply
  ods_ewa.aus_ewa_risk_risk_event_task
  ods_ewa.aus_listing_tb_loan_user_limit_log
加工逻辑：额度申请表中 biz_type = 400 为主动戳额；风控事件表中 biz_id = 10000 为历史戳额，
  仅在额度申请表没有匹配记录时兜底；每笔放款按 user_id 取放款时间之前最近一条戳额，
  得到戳额来源（stamp_source）和戳额流水（flow_no）；
  再用 flow_no = relate_id 关联额度日志表，取 event_type = 1、limit_category = 1 的记录带出额度。
===============================================================================
*/
WITH param_obs_date AS (
    SELECT MAX(TO_DATE(dt)) AS obs_dt
    FROM edw_ewa.dwb_asset_debt_dtl_snp
),
stg_debt_snp AS (
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
    CROSS JOIN param_obs_date p
    WHERE TO_DATE(d.dt) <= p.obs_dt
      AND TO_DATE(d.dt) >= (
          SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
          FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
          WHERE CAST(a.isactive AS INT) = 1
      )
    GROUP BY d.listing_id, TO_DATE(d.dt)
),
apply AS (
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
         END AS apply_status_desc
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
),
latest AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,a.is_disburse_success
        ,a.disburse_time
        ,CAST(l.real_amount AS DOUBLE)                        AS real_amount
        ,CAST(l.term_quantity AS INT)                         AS term_quantity
        ,l.term_unit
        ,s.init_due_date
    FROM loan_apply a
    CROSS JOIN param_obs_date p
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
    LEFT JOIN stg_debt_snp s
      ON a.listing_id = s.listing_id
     AND s.stat_date = p.obs_dt
),
disbursed AS (
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
    FROM latest
    WHERE is_disburse_success = 1
),
apply_stamp AS (
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
    FROM disbursed d
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
    FROM disbursed d
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
FROM disbursed d
LEFT JOIN matched m
  ON d.loan_no = m.loan_no
LEFT JOIN limit_grant g
  ON m.flow_no = g.relate_id
 AND g.rn = 1
;


/*
===============================================================================
13. 借款级 Vintage 宽表（查询结果）
对应加工表：model.tmp_eliam_wagego_dws_vintage_loan
粒度：借款申请（loan_no），只保留放款成功的借款
上游：dwd_loan_debt + stg_debt_snp + param_obs_date
加工逻辑：借款债务明细已算好观察日标签，这里只保留放款成功的借款，
  按用户放款时间升序生成放款序号（1 为新客 New，其余为老客 Old）；
  输出放款属性、全部标签列、标签观察日、数据截止日（data_as_of = obs_dt）和在贷天数；
  再把每笔放款按 MOB1–MOB12 展开，观察日为 LAST_DAY(ADD_MONTHS(disburse_time, mob_no))，
  按借款（listing_id）+ 观察日（stat_date）关联借款日快照取逾期天数，
  观察日超过数据截止日或没有快照时该 MOB 标记为 NULL，不计入分母；
  逾期天数 >= 5 记 5+，> 30 记 30+，最后按借款聚合回一行，
  输出 mob1_5plus ~ mob12_5plus 与 mob1_30plus ~ mob12_30plus。
===============================================================================
*/
WITH param_obs_date AS (
    SELECT MAX(TO_DATE(dt)) AS obs_dt
    FROM edw_ewa.dwb_asset_debt_dtl_snp
),
stg_debt_snp AS (
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
    CROSS JOIN param_obs_date p
    WHERE TO_DATE(d.dt) <= p.obs_dt
      AND TO_DATE(d.dt) >= (
          SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
          FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
          WHERE CAST(a.isactive AS INT) = 1
      )
    GROUP BY d.listing_id, TO_DATE(d.dt)
),
apply AS (
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
         END AS apply_status_desc
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
),
latest AS (
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
    FROM loan_apply a
    CROSS JOIN param_obs_date p
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
    LEFT JOIN stg_debt_snp s
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
    LEFT JOIN stg_debt_snp s
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
loan_debt AS (
    SELECT
         b.loan_no
        ,b.user_id
        ,b.listing_id
        ,b.is_disburse_success
        ,b.disburse_time
        ,b.real_amount
        ,b.term_unit
        ,b.init_due_date
        ,b.label_obs_dt
        ,b.is_label_matured
        ,b.label_current_overdue_days
        ,b.label_hist_overdue_days
        ,b.repay_at_label_obs
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
        ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd14_obs
        ,CASE WHEN b.is_label_matured = 1
              THEN CASE WHEN b.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END
                        ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END END END AS is_fpd14_ovd
        ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd30_obs
        ,CASE WHEN b.is_label_matured = 1
              THEN CASE WHEN b.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END
                        ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END END END AS is_fpd30_ovd
    FROM base b
),
loan AS (
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
        ,a.is_fpd14_obs
        ,a.is_fpd14_ovd
        ,a.is_fpd30_obs
        ,a.is_fpd30_ovd
        ,ROW_NUMBER() OVER (PARTITION BY a.user_id ORDER BY a.disburse_time, a.loan_no) AS application_rank
    FROM loan_debt a
    WHERE a.is_disburse_success = 1
),
loan_wide AS (
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
        ,l.is_fpd14_obs
        ,l.is_fpd14_ovd
        ,l.is_fpd30_obs
        ,l.is_fpd30_ovd
        ,l.application_rank
        ,CASE WHEN l.application_rank = 1 THEN 'New' ELSE 'Old' END AS user_type
        ,l.disburse_date
    FROM loan l
    CROSS JOIN param_obs_date p
),
mob AS (
    SELECT EXPLODE(SEQUENCE(1, 12)) AS mob_no
),
mob_obs AS (
    SELECT
         w.loan_no
        ,w.listing_id
        ,w.disburse_date
        ,w.data_as_of
        ,m.mob_no
        ,LAST_DAY(ADD_MONTHS(w.disburse_date, m.mob_no))       AS obs_dt
    FROM loan_wide w
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
    LEFT JOIN stg_debt_snp d
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
     w.loan_no
    ,w.user_id
    ,w.listing_id
    ,w.disburse_time
    ,w.disburse_month
    ,w.real_amount
    ,w.term_unit
    ,w.init_due_date
    ,w.label_obs_dt
    ,w.is_label_matured
    ,w.data_as_of
    ,w.days_on_book
    ,w.dpd_at_label_obs
    ,w.hist_dpd_at_label_obs
    ,w.is_current_overdue_at_label_obs
    ,w.current_ovd_amt_at_label_obs
    ,w.is_5plus_at_label_obs
    ,w.is_30plus_at_label_obs
    ,w.is_ever_30plus_in_window
    ,w.is_fpd3_obs
    ,w.is_fpd3_ovd
    ,w.is_fpd7_obs
    ,w.is_fpd7_ovd
    ,w.is_fpd14_obs
    ,w.is_fpd14_ovd
    ,w.is_fpd30_obs
    ,w.is_fpd30_ovd
    ,w.application_rank
    ,w.user_type
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
FROM loan_wide w
LEFT JOIN mob_wide m
  ON w.loan_no = m.loan_no
;


/*
===============================================================================
14. 放款样本表（查询结果）
对应加工表：model.tmp_eliam_wagego_dwd_loan_disburse_sample
粒度：借款申请（loan_no），一行一个申请
上游：dwd_loan_debt
加工逻辑：复用第 10 段借款 / 债务明细的完整逻辑，最后只保留申请状态为
  DISBURSE（放款中）、DISBURSE_SUCCESS（放款成功）、DISBURSE_FAILED（放款失败）的记录；
  不要求 is_deal = 1，字段与 dwd_loan_debt 完全一致。
===============================================================================
*/
WITH param_obs_date AS (
    SELECT MAX(TO_DATE(dt)) AS obs_dt
    FROM edw_ewa.dwb_asset_debt_dtl_snp
),
stg_debt_snp AS (
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
    CROSS JOIN param_obs_date p
    WHERE TO_DATE(d.dt) <= p.obs_dt
      AND TO_DATE(d.dt) >= (
          SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
          FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
          WHERE CAST(a.isactive AS INT) = 1
      )
    GROUP BY d.listing_id, TO_DATE(d.dt)
),
apply AS (
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
         END AS apply_status_desc
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
),
latest AS (
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
    FROM loan_apply a
    CROSS JOIN param_obs_date p
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
    LEFT JOIN stg_debt_snp s
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
    LEFT JOIN stg_debt_snp s
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
    ,CASE WHEN b.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd14_obs
    ,CASE WHEN b.is_label_matured = 1
          THEN CASE WHEN b.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(b.repay_at_label_obs) > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END
                    ELSE CASE WHEN b.label_obs_dt > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END END END AS is_fpd14_ovd
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
WHERE b.apply_status IN ('DISBURSE', 'DISBURSE_SUCCESS', 'DISBURSE_FAILED')
;
