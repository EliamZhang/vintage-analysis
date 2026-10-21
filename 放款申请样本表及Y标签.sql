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
-- 下游：dwd_loan_apply_label
-- 日期范围：最早申请日前 1 个月 ~ 观察日（obs_dt）。
-- 目的：把多期快照聚合成一个借款一天一行，供标签窗口（init_due_date + 31 天）和 MOB 观察点取数。
-- 加工逻辑：债务快照表（edw_ewa.dwb_asset_debt_dtl_snp）一行是借款（listing_id）× 期次（period_no）× 日期（dt），
--   这里按借款（listing_id）× 日期（dt）聚合，把多期压成一行：应还日（init_due_date）取 MIN、逾期天数（current_overdue_days、hist_overdue_days）取 MAX、
--   金额（principal、repay_amount、owing_amount）取 SUM、债务状态（debt_status）取最差（4 逾期中 > 1 未结清 > 2 已结清），并输出中文描述（debt_status_desc）；
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
FROM agg
;                                                                 -- 日快照（stat_date），支持任意 init_due_date + 31 标签观察点

-- ============================================================================
-- 第二步：放款申请明细与Y标签（dwd_loan_apply_label）
-- 粒度：放款申请（loan_no），一行一个申请（含成功/拒绝/过期/放款失败）
-- 上游：ods_ewa.aus_ewa_loan_biz_t_loan_application + ods_ewa.aus_ewa_risk_risk_event_task
--       + ods_ewa.aus_listing_tb_loan_limit_apply + edw_ewa.dwb_asset_cmn_listing
--       + stg_debt_snp + param_obs_date
-- 下游：下游分析 / 建模取数
-- 目的：一行一个申请，包含申请状态、放款属性、观察日债务状态、FPD3/7/14/30 标签和 MOB1~MOB3 的 5+ / 30+ 标记；
--       后续分析按 is_disburse_success = 1 筛放款成功样本。
-- 阅读前先认识几个名词：
--   loan_no      一次放款申请的编号，本表一行一个申请，loan_no 唯一；
--   listing_id   借款（标的）编号，申请放款成功后生成，一笔借款对应一个 listing_id；
--   period_no    期次，一笔借款可能分多期还款，period_no = 1 表示首期；
--   init_due_date 首期应还日，用来判断首期是否逾期（FPD）；
--   obs_dt       观察日，取债务快照表的最新一天，"当前状态"都以这一天为准；
--   label_obs_dt 标签观察日 = 首期应还日 + 31 天，用来观察首期到期一个月后的表现；
--   MOB n        放款后的第 n 个表现观察点，取放款日往后推 n 个月所在月的月末；
--   成熟         标签观察日已经真实发生（不早于放款日、且不晚于观察日），否则标签无法判断。
--
-- Y 标签命名规范：
--   统一以 y_ 开头；_cnt 为笔数口径（0/1 标记，SUM 得到逾期笔数、AVG 得到逾期率），
--   _amt 为金额口径，_dpd 为逾期天数；观察点用 obs（观察日）、label（标签日）、fpdN（首期）、mobN（第 N 月）。
--
-- 加工逻辑（与下面 CTE 一一对应）：
--   1) apply：从放款申请表取有效申请（isactive = 1），一行一个申请，保留用户、借款、申请状态、
--      申请时间、放款时间，并按用户申请时间排序生成申请序号 apply_seq（该用户的第几次申请）。
--   2) event：从风控事件表取申请环节的策略事件（biz_id = 20050，flow_id 以 LN 开头）。
--      同一笔申请可能有多条事件，只保留更新时间最新的一条，补充策略时间、重试次数和 app_id。
--   3) stamp / stamp_matched：戳额（额度审批或刷新）有两个来源——额度申请表（biz_type = 400，优先）
--      和风控事件（biz_id = 10000）。对每笔申请，在同一用户、申请时间之前（含）的戳额记录中，
--      先按来源优先级、再按时间倒序取第一条，得到申请前的额度时点 stamp_time 和这次戳额的流水号 stamp_flow_id。
--   4) ranked：只看放款成功的申请，按放款时间排序生成 application_rank；
--      application_rank = 1 表示该用户第一笔成功放款（New），其余为复借（Old）。
--      注意 New/Old 以"首笔成功放款"为准，而不是以首次申请为准。
--   5) loan_apply：把申请、策略事件、放款序号、戳额时点按 loan_no 拼成申请主表，
--      把申请状态翻译成中文，并打上放款成功、拒绝、过期、放款失败等标记。
--   6) latest：按 listing_id 关联借款信息表（dwb_asset_cmn_listing），补充放款金额、利息、服务费、
--      期限、是否成交、合同应还日等放款属性；同时关联观察日 obs_dt 的债务快照，得到截至观察日的
--      首期应还日、首期还款时间、结清时间、债务状态、逾期天数和应还/已还金额。
--   7) base：再以"首期应还日 + 31 天"作为标签观察日，关联同一张债务快照，得到标签日的债务状态；
--      并判断样本是否成熟 is_label_matured（放款成功 + 已成交 + 有债务快照 + 标签观察日在放款日和观察日之间）；
--      同时算出标签日实际还款日 label_obs_day：优先取标签日快照里的首期还款时间，其次取观察日快照里
--      不晚于标签日的首期还款时间，两者都没有则取标签日本身（表示"截至标签日仍未还款"）。
--   8) mob_obs / mob_detail / mob_wide：对放款成功的借款，分别到 MOB1、MOB2、MOB3 的观察点关联当天债务快照，
--      计算 5+（当天逾期天数 >= 5）和 30+（当天逾期天数 > 30），再按借款透视为 y_mob1_5plus_cnt ... y_mob3_30plus_cnt。
--      观察点还没到（晚于 obs_dt）或当天没有快照时，对应标记为 NULL。
--   9) 最终 SELECT：标签日指标（标签日 DPD、5+ / 30+、是否逾期、逾期金额）之外，计算 FPD3/7/14/30：
--      用标签日实际还款日 label_obs_day 与首期应还日比较，晚于"首期应还日 + N 天"记为 FPD_N 逾期 = 1，否则 0；
--      到标签日仍未还款时用标签日参与比较，等价于"截至标签日仍未还清"。最后补充合同期限、实际期限、
--      是否早结清、观察日是否逾期、在贷天数和 New/Old 等派生指标。
-- ============================================================================
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
        ,s.principal                                          AS debt_principal
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
        -- 标签日实际还款日：优先标签日快照的首期还款时间，其次观察日快照中不晚于标签日的首期还款时间，最后取标签日
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
        ,m.mob_no
        ,LAST_DAY(ADD_MONTHS(TO_DATE(b.disburse_time), m.mob_no)) AS mob_obs_dt
    FROM base b
    CROSS JOIN (SELECT EXPLODE(SEQUENCE(1, 3)) AS mob_no) m
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
    FROM mob_obs o
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp d
      ON o.listing_id = d.listing_id
     AND o.mob_obs_dt = d.stat_date
),
mob_wide AS (
    SELECT
         loan_no
        ,MAX(CASE WHEN mob_no = 1  THEN is_5plus END) AS y_mob1_5plus_cnt
        ,MAX(CASE WHEN mob_no = 2  THEN is_5plus END) AS y_mob2_5plus_cnt
        ,MAX(CASE WHEN mob_no = 3  THEN is_5plus END) AS y_mob3_5plus_cnt
        ,MAX(CASE WHEN mob_no = 1  THEN is_30plus END) AS y_mob1_30plus_cnt
        ,MAX(CASE WHEN mob_no = 2  THEN is_30plus END) AS y_mob2_30plus_cnt
        ,MAX(CASE WHEN mob_no = 3  THEN is_30plus END) AS y_mob3_30plus_cnt
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
    ,b.label_dpd                                           AS y_label_dpd
    ,b.label_hist_dpd                                      AS y_label_hist_dpd
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd > 0 THEN 1 ELSE 0 END END AS y_label_ovd_cnt
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd > 0 THEN b.real_amount ELSE 0 END END AS y_label_ovd_amt
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd >= 5 THEN 1 ELSE 0 END END AS y_label_5plus_cnt
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd > 30 THEN 1 ELSE 0 END END AS y_label_30plus_cnt
    ,CASE WHEN b.label_hist_dpd IS NOT NULL THEN CASE WHEN b.label_hist_dpd > 30 THEN 1 ELSE 0 END END AS y_label_ever30plus_cnt
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END END AS y_fpd3_ovd_cnt
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END END AS y_fpd7_ovd_cnt
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END END AS y_fpd14_ovd_cnt
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END END AS y_fpd30_ovd_cnt
    ,CASE WHEN b.debt_listing_id IS NOT NULL THEN DATEDIFF(b.init_due_date, TO_DATE(b.disburse_time)) END AS loan_term_contract_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN DATEDIFF(TO_DATE(b.user_actual_repay_time), TO_DATE(b.disburse_time)) END AS loan_term_actual_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN CASE WHEN TO_DATE(b.user_actual_repay_time) < b.init_due_date THEN 1 ELSE 0 END END AS is_early_settlement
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN 1 ELSE 0 END END AS y_obs_ovd_cnt
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS y_obs_ovd_amt
    ,DATE_FORMAT(b.disburse_time, 'yyyy-MM')                 AS disburse_month
    ,DATEDIFF(b.obs_dt, TO_DATE(b.disburse_time))            AS days_on_book
    ,CASE WHEN b.application_rank = 1 THEN 'New' WHEN b.application_rank IS NOT NULL THEN 'Old' END AS user_type
    ,m.y_mob1_5plus_cnt
    ,m.y_mob2_5plus_cnt
    ,m.y_mob3_5plus_cnt
    ,m.y_mob1_30plus_cnt
    ,m.y_mob2_30plus_cnt
    ,m.y_mob3_30plus_cnt
FROM base b
LEFT JOIN mob_wide m
  ON b.loan_no = m.loan_no
;
