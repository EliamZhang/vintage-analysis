/*
===============================================================================
WageGo Vintage 数据同步 SQL
适用语法：Spark SQL / Hive 风格（与《放款申请样本表及Y标签.sql》一致）

本文件按段号顺序执行，结果落到 原始数据/：
  1~6  原始表（《放款申请样本表及Y标签.sql》直接依赖）
    1. ods_ewa.aus_ewa_loan_biz_t_loan_application          借款申请
    2. edw_ewa.dwb_asset_cmn_listing                        放款信息
    3. edw_ewa.dwb_asset_debt_dtl_snp                       债务快照
    4. ods_ewa.aus_ewa_risk_risk_event_task                 风控事件（按 biz_id 裁剪）
    5. ods_ewa.aus_listing_tb_loan_limit_apply              额度申请（戳额）
    6. ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log     模型调用日志（按 model_code 裁剪）
  7~9  加工表（库中原本没有，由本文件建表后导出）
    7. model.tmp_eliam_wagego_param_obs_date                观察日参数
    8. model.tmp_eliam_wagego_stg_debt_snp                  借据日快照宽表
    9. model.tmp_eliam_wagego_dwd_loan_apply_label          放款申请样本表及Y标签

说明：
- 段首用注释块标注「N. 段名」，段号从 1 连续排列，并与 sync.py 的 SEGMENT_SPECS 对应。
- 每段可包含多条以分号分隔的语句：前面的语句是建表等准备动作，最后一条语句的结果写入 CSV。
- 7~9 段需按顺序执行：第 8 段使用第 7 段建的观察日参数表，第 9 段使用第 8 段的宽表。
- 底表按原表全量取数；风控事件表只保留本流程用到的 biz_id = 20050（借款申请事件）
  和 biz_id = 10000（历史戳额事件）；模型调用日志只保留本流程用到的
  model_code = aus_wagego_new_risk_3rd_v1_0（放款阶段三方模型分），避免把无关记录打进数据包。
- 源脚本开头的 SET spark.sql.session.timeZone = Australia/Sydney 由执行环境负责；
  请保持同一时区执行，避免 TO_DATE / DATE_FORMAT 在跨时区会话下产生日期偏移。
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
6. 模型调用日志表（原始数据，按 model_code 裁剪）
源表：ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log
粒度：一行一次模型调用
用途：scene_id 为放款号时提供放款阶段三方模型分，分值在 model_output 的
      $.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 字段。
说明：只保留本流程用到的 model_code，避免把无关模型日志打进数据包。
===============================================================================
*/
SELECT *
FROM ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log
WHERE model_code = 'aus_wagego_new_risk_3rd_v1_0'
;


/*
===============================================================================
7. 观察日参数表（加工表）
目标表：model.tmp_eliam_wagego_param_obs_date
粒度：一行一个全局观察日 obs_dt
用途：取债务快照表的最新快照日，作为后续加工步骤统一的“当前时点”。
说明：库里没有这张表，本段包含建表语句；建表后立即导出结果。
===============================================================================
*/
DROP TABLE IF EXISTS model.tmp_eliam_wagego_param_obs_date;
CREATE TABLE model.tmp_eliam_wagego_param_obs_date AS
SELECT MAX(TO_DATE(dt)) AS obs_dt
FROM edw_ewa.dwb_asset_debt_dtl_snp
;
SELECT *
FROM model.tmp_eliam_wagego_param_obs_date
;


/*
===============================================================================
8. 借据日快照宽表（加工表）
目标表：model.tmp_eliam_wagego_stg_debt_snp
粒度：一行一个借据（listing_id）× 快照日期（stat_date）
用途：把“借据 × 期数 × 快照日”的债务明细汇总成借据级日状态。
说明：库里没有这张表，本段包含建表语句；依赖第 7 段的观察日参数表。
===============================================================================
*/
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
SELECT *
FROM model.tmp_eliam_wagego_stg_debt_snp
;


/*
===============================================================================
9. 放款申请样本表及Y标签（加工表）
目标表：model.tmp_eliam_wagego_dwd_loan_apply_label
粒度：一行一条有效贷款申请（loan_no）
用途：以申请为一行，关联放款信息、观察日状态、标签时点状态和各类 Y 标签。
说明：库里没有这张表，本段包含建表语句；依赖第 7 段的观察日参数表和第 8 段的宽表。
===============================================================================
*/
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
credit AS (
    SELECT
         a.borrower_id                                        AS user_id
        ,CAST(a.inserttime AS TIMESTAMP)                      AS credit_time
        ,a.flow_no                                            AS credit_flow_id
        ,CAST(a.id AS BIGINT)                                 AS credit_id
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
credit_matched AS (
    SELECT
         t.loan_no
        ,t.credit_time
        ,t.credit_flow_id
    FROM (
        SELECT
             a.loan_no
            ,s.credit_time
            ,s.credit_flow_id
            ,ROW_NUMBER() OVER (PARTITION BY a.loan_no ORDER BY s.source_priority, s.credit_time DESC, s.credit_id DESC) AS rn
        FROM apply a
        JOIN credit s
          ON a.user_id = s.user_id
         AND s.credit_time <= a.apply_time
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
        ,sm.credit_time
        ,sm.credit_flow_id
    FROM apply a
    LEFT JOIN event e
      ON a.loan_no = e.loan_no
    LEFT JOIN ranked r
      ON a.loan_no = r.loan_no
    LEFT JOIN credit_matched sm
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
              THEN 1 ELSE 0 END                               AS is_due_matured
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
        ,CASE WHEN l.is_due_matured = 1 THEN x.current_overdue_days END AS label_dpd
        ,CASE WHEN l.is_due_matured = 1 THEN x.hist_overdue_days END    AS label_hist_dpd
        ,COALESCE(
             TO_DATE(x.first_repay_time)
            ,CASE WHEN l.first_repay_time IS NOT NULL AND TO_DATE(l.first_repay_time) <= l.label_obs_dt
                  THEN TO_DATE(l.first_repay_time) END
            ,l.label_obs_dt
         )                                                    AS label_obs_day
        ,CASE WHEN l.is_deal = 1 AND l.debt_listing_id IS NOT NULL
               AND LEAST(COALESCE(TO_DATE(l.first_repay_time), l.obs_dt), DATE_ADD(l.init_due_date, 3)) < l.obs_dt
              THEN 1 ELSE 0 END                               AS y_fpd3_obs_cnt
        ,CASE WHEN l.is_deal = 1 AND l.debt_listing_id IS NOT NULL
               AND LEAST(COALESCE(TO_DATE(l.first_repay_time), l.obs_dt), DATE_ADD(l.init_due_date, 7)) < l.obs_dt
              THEN 1 ELSE 0 END                               AS y_fpd7_obs_cnt
        ,CASE WHEN l.is_deal = 1 AND l.debt_listing_id IS NOT NULL
               AND LEAST(COALESCE(TO_DATE(l.first_repay_time), l.obs_dt), DATE_ADD(l.init_due_date, 14)) < l.obs_dt
              THEN 1 ELSE 0 END                               AS y_fpd14_obs_cnt
        ,CASE WHEN l.is_deal = 1 AND l.debt_listing_id IS NOT NULL
               AND LEAST(COALESCE(TO_DATE(l.first_repay_time), l.obs_dt), DATE_ADD(l.init_due_date, 15)) < l.obs_dt
              THEN 1 ELSE 0 END                               AS y_fpd15_obs_cnt
        ,CASE WHEN l.is_deal = 1 AND l.debt_listing_id IS NOT NULL
               AND LEAST(COALESCE(TO_DATE(l.first_repay_time), l.obs_dt), DATE_ADD(l.init_due_date, 30)) < l.obs_dt
              THEN 1 ELSE 0 END                               AS y_fpd30_obs_cnt
        ,CASE WHEN l.is_disburse_success = 1
              THEN CASE WHEN LAST_DAY(ADD_MONTHS(TO_DATE(l.disburse_time), 1)) <= l.obs_dt THEN 1 ELSE 0 END
         END                                                  AS y_mob1_obs_cnt
        ,CASE WHEN l.is_disburse_success = 1
              THEN CASE WHEN LAST_DAY(ADD_MONTHS(TO_DATE(l.disburse_time), 2)) <= l.obs_dt THEN 1 ELSE 0 END
         END                                                  AS y_mob2_obs_cnt
        ,CASE WHEN l.is_disburse_success = 1
              THEN CASE WHEN LAST_DAY(ADD_MONTHS(TO_DATE(l.disburse_time), 3)) <= l.obs_dt THEN 1 ELSE 0 END
         END                                                  AS y_mob3_obs_cnt
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
mob_label_detail AS (
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
mob_label_wide AS (
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
    FROM mob_label_detail
    GROUP BY loan_no
),
mob_track_detail AS (
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
    FROM mob_track_detail
    GROUP BY loan_no
),
model_log AS (
    SELECT
         t.scene_id                                                                                   AS loan_no
        ,CAST(GET_JSON_OBJECT(t.model_output, '$.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626') AS DOUBLE) AS aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
    FROM (
        SELECT
             r.scene_id
            ,r.model_output
            ,ROW_NUMBER() OVER (PARTITION BY r.scene_id ORDER BY CAST(r.start_time AS TIMESTAMP) DESC, CAST(r.inserttime AS TIMESTAMP) DESC) AS rn
        FROM ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log r
        WHERE r.model_code = 'aus_wagego_new_risk_3rd_v1_0'
    ) t
    WHERE t.rn = 1
),
labeled AS (
    SELECT
         b.*
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
        ,CASE WHEN b.y_fpd3_obs_cnt = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END END AS y_fpd3_ovd_cnt
        ,CASE WHEN b.y_fpd7_obs_cnt = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END END AS y_fpd7_ovd_cnt
        ,CASE WHEN b.y_fpd14_obs_cnt = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END END AS y_fpd14_ovd_cnt
        ,CASE WHEN b.y_fpd15_obs_cnt = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 15) THEN 1 ELSE 0 END END AS y_fpd15_ovd_cnt
        ,CASE WHEN b.y_fpd30_obs_cnt = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END END AS y_fpd30_ovd_cnt
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
        ,CASE WHEN b.y_mob1_obs_cnt = 1 THEN b.real_amount WHEN b.y_mob1_obs_cnt = 0 THEN 0 END AS y_mob1_obs_amt
        ,CASE WHEN b.y_mob2_obs_cnt = 1 THEN b.real_amount WHEN b.y_mob2_obs_cnt = 0 THEN 0 END AS y_mob2_obs_amt
        ,CASE WHEN b.y_mob3_obs_cnt = 1 THEN b.real_amount WHEN b.y_mob3_obs_cnt = 0 THEN 0 END AS y_mob3_obs_amt
        ,CASE WHEN m.y_mob1_5plus_cnt = 1 THEN b.real_amount WHEN m.y_mob1_5plus_cnt = 0 THEN 0 END AS y_mob1_5plus_amt
        ,CASE WHEN m.y_mob1_ever_5plus_cnt = 1 THEN b.real_amount WHEN m.y_mob1_ever_5plus_cnt = 0 THEN 0 END AS y_mob1_ever_5plus_amt
        ,CASE WHEN m.y_mob2_5plus_cnt = 1 THEN b.real_amount WHEN m.y_mob2_5plus_cnt = 0 THEN 0 END AS y_mob2_5plus_amt
        ,CASE WHEN m.y_mob2_ever_5plus_cnt = 1 THEN b.real_amount WHEN m.y_mob2_ever_5plus_cnt = 0 THEN 0 END AS y_mob2_ever_5plus_amt
        ,CASE WHEN m.y_mob3_5plus_cnt = 1 THEN b.real_amount WHEN m.y_mob3_5plus_cnt = 0 THEN 0 END AS y_mob3_5plus_amt
        ,CASE WHEN m.y_mob3_ever_5plus_cnt = 1 THEN b.real_amount WHEN m.y_mob3_ever_5plus_cnt = 0 THEN 0 END AS y_mob3_ever_5plus_amt
        ,CASE WHEN m.y_mob1_30plus_cnt = 1 THEN b.real_amount WHEN m.y_mob1_30plus_cnt = 0 THEN 0 END AS y_mob1_30plus_amt
        ,CASE WHEN m.y_mob1_ever_30plus_cnt = 1 THEN b.real_amount WHEN m.y_mob1_ever_30plus_cnt = 0 THEN 0 END AS y_mob1_ever_30plus_amt
        ,CASE WHEN m.y_mob2_30plus_cnt = 1 THEN b.real_amount WHEN m.y_mob2_30plus_cnt = 0 THEN 0 END AS y_mob2_30plus_amt
        ,CASE WHEN m.y_mob2_ever_30plus_cnt = 1 THEN b.real_amount WHEN m.y_mob2_ever_30plus_cnt = 0 THEN 0 END AS y_mob2_ever_30plus_amt
        ,CASE WHEN m.y_mob3_30plus_cnt = 1 THEN b.real_amount WHEN m.y_mob3_30plus_cnt = 0 THEN 0 END AS y_mob3_30plus_amt
        ,CASE WHEN m.y_mob3_ever_30plus_cnt = 1 THEN b.real_amount WHEN m.y_mob3_ever_30plus_cnt = 0 THEN 0 END AS y_mob3_ever_30plus_amt
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
        ,ml.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
    FROM base b
    LEFT JOIN mob_label_wide m
      ON b.loan_no = m.loan_no
    LEFT JOIN mob_track_wide t
      ON b.loan_no = t.loan_no
    LEFT JOIN model_log ml
      ON b.loan_no = ml.loan_no
)
SELECT
     loan_no
    ,user_id
    ,application_id
    ,app_id
    ,listing_id
    ,apply_status
    ,apply_status_desc
    ,is_disburse_success
    ,is_reject
    ,is_expired
    ,is_disburse_failed
    ,apply_time
    ,apply_date
    ,apply_month
    ,disburse_time
    ,apply_seq
    ,application_rank
    ,strategy_time
    ,retry_count
    ,credit_time AS last_limit_time
    ,credit_flow_id AS last_limit_flow_id
    ,real_amount
    ,apply_amount
    ,interest
    ,service_fee
    ,term_quantity
    ,term_unit
    ,total_period
    ,is_deal
    ,withdraw_time
    ,list_due_date
    ,init_due_date
    ,user_actual_repay_time
    ,debt_status
    ,debt_status_desc
    ,hist_overdue_days
    ,current_overdue_days
    ,principal
    ,repay_amount
    ,owing_amount
    ,obs_dt
    ,label_obs_dt
    ,label_user_actual_repay_time
    ,label_debt_status
    ,label_current_overdue_days
    ,label_hist_overdue_days
    ,label_owing_amount
    ,y_due_dpd
    ,y_due_ever_dpd
    ,y_due_ovd_cnt
    ,y_due_ovd_amt
    ,y_due_5plus_cnt
    ,y_due_30plus_cnt
    ,y_due_ever_ovd_cnt
    ,y_due_ever_ovd_amt
    ,y_due_ever_5plus_cnt
    ,y_due_ever_30plus_cnt
    ,y_fpd3_obs_cnt
    ,y_fpd3_ovd_cnt
    ,y_fpd7_obs_cnt
    ,y_fpd7_ovd_cnt
    ,y_fpd14_obs_cnt
    ,y_fpd14_ovd_cnt
    ,y_fpd15_obs_cnt
    ,y_fpd15_ovd_cnt
    ,y_fpd30_obs_cnt
    ,y_fpd30_ovd_cnt
    ,loan_term_contract_days
    ,loan_term_actual_days
    ,is_early_settlement
    ,y_obs_ovd_cnt
    ,y_obs_ovd_amt
    ,y_obs_ever_ovd_cnt
    ,y_obs_ever_ovd_amt
    ,disburse_month
    ,days_on_book
    ,user_type
    ,y_mob1_obs_cnt
    ,y_mob1_obs_amt
    ,y_mob1_5plus_cnt
    ,y_mob1_5plus_amt
    ,y_mob1_ever_5plus_cnt
    ,y_mob1_ever_5plus_amt
    ,y_mob1_30plus_cnt
    ,y_mob1_30plus_amt
    ,y_mob1_ever_30plus_cnt
    ,y_mob1_ever_30plus_amt
    ,y_mob2_obs_cnt
    ,y_mob2_obs_amt
    ,y_mob2_5plus_cnt
    ,y_mob2_5plus_amt
    ,y_mob2_ever_5plus_cnt
    ,y_mob2_ever_5plus_amt
    ,y_mob2_30plus_cnt
    ,y_mob2_30plus_amt
    ,y_mob2_ever_30plus_cnt
    ,y_mob2_ever_30plus_amt
    ,y_mob3_obs_cnt
    ,y_mob3_obs_amt
    ,y_mob3_5plus_cnt
    ,y_mob3_5plus_amt
    ,y_mob3_ever_5plus_cnt
    ,y_mob3_ever_5plus_amt
    ,y_mob3_30plus_cnt
    ,y_mob3_30plus_amt
    ,y_mob3_ever_30plus_cnt
    ,y_mob3_ever_30plus_amt
    ,estimate_principal_remaining_mob0
    ,dpd_days_mob0
    ,dpd_days_ever_mob0
    ,estimate_principal_remaining_mob1
    ,dpd_days_mob1
    ,dpd_days_ever_mob1
    ,estimate_principal_remaining_mob2
    ,dpd_days_mob2
    ,dpd_days_ever_mob2
    ,estimate_principal_remaining_mob3
    ,dpd_days_mob3
    ,dpd_days_ever_mob3
    ,estimate_principal_remaining_mob4
    ,dpd_days_mob4
    ,dpd_days_ever_mob4
    ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
FROM labeled
;
SELECT *
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
;
