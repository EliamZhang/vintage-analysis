SET spark.sql.session.timeZone = Australia/Sydney;

-- Spark SQL；以本文件重构前的工作区版本为业务基线（见历史材料/优化前_样本表准备以及Y标签表准备.sql）。
-- 执行顺序：先运行 校验/01_保存优化前结果.sql，再运行本文件，最后运行 校验/02_重构验收.sql。
-- 旧版与新版必须读取同一批源数据；校验脚本不将历史查询结果 CSV 作为本次基线。
--
-- 依赖与职责（10 张物理表收敛为 8 张物理表）：
--   param_obs_date ──> stg_debt_snp ──> dwd_loan_sample ──> dws_vintage_loan ──> ads_vintage_month
--                                  │                    └─> dws_vintage_mob ──> ads_vintage_curve
--                                  └─> dwd_loan_stamp（内部过滤成功放款）
--   dwd_loan_sample：全部有效申请、放款属性、观察日债务特征、新老客序号；不加工 Y 标签。
--   dws_vintage_loan：仅成功放款，集中加工固定窗口 Y 标签；不再回连申请号或重复排序。
--
-- 接口变化：原 dwd_loan_apply 内联到 dwd_loan_sample；原 dwd_loan_debt 拆为样本与标签职责。
-- 原 dwd_disbursed_loan 是成功放款属性投影，改为从 dwd_loan_sample 过滤，不重复落盘。
-- 三张旧中间表不再刷新，也不自动删除；其外部消费者应迁移到新样本表/标签表后再清理。
-- dwd_loan_stamp、dws_vintage_loan、dws_vintage_mob、ads_vintage_month、ads_vintage_curve 保持原列名/列序。
--
-- 保持原口径：
--   * 观察日=全量债务源 MAX(TO_DATE(dt))；快照下界=有效申请最早申请日向前 1 个月。
--   * 多期借款首期还款仅取 period_no=1；全部期次 debt_status=2 才取结清时间；状态优先级 4>1>2。
--   * 标签日=观察日快照中的最早 init_due_date+31；成熟与标签日快照存在是两个独立条件。
--   * 标签日快照缺失时 DPD 保留 NULL；FPD 仍可用观察日首期还款时间回补，保持原逻辑。
--   * 5+=DPD>=5，30+=DPD>30；FPD3/7/15/30 共用 +31 天成熟条件，等于阈值日还款不算逾期。
--   * 金额仍用 DOUBLE、原 SUM/ROUND/NULLIF/COALESCE 语义；不改成余额口径或自动补零。
--   * MOB1~12=放款日加相应月数后的月末，未成熟行仍保留；缺快照不补最近一天。
--   * 戳额：存在放款前额度申请时优先取该来源；仅无该来源候选才用风控事件，不能跨来源只按时间取最新。
--   * apply_seq/首申标记沿用全部 isactive=1 申请范围；user_type 沿用全部成功放款时间排序，不另加 is_deal 条件。

-- ============================================================================
-- 0. 源表粒度门禁：异常时失败退出，不用 DISTINCT/MAX/任意 ROW_NUMBER 掩盖业务重复。
-- 源数据需在整次运行及基线比对期间保持稳定；门禁不是事务快照。
-- application：有效 loan_no 唯一；listing：仅核查有效申请实际引用的非空 listing_id。
-- debt：本次日期范围内 listing_id × INT(period_no) × DATE(dt) 唯一；后续有意聚合到借款日粒度。
-- 排序键并列且输出不同的风险事件/戳额/额度日志，另见验收脚本的歧义检查。
-- ============================================================================
SELECT ASSERT_TRUE(COUNT(*) = 0, 'active loan_no is null or duplicated') AS check_application_key
FROM (
    SELECT loan_no
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application
    WHERE CAST(isactive AS INT) = 1
    GROUP BY loan_no
    HAVING loan_no IS NULL OR COUNT(*) > 1
) invalid_application;

SELECT ASSERT_TRUE(COUNT(*) = 0, 'referenced listing_id is duplicated') AS check_listing_key
FROM (
    SELECT l.listing_id
    FROM edw_ewa.dwb_asset_cmn_listing l
    WHERE l.listing_id IN (
        SELECT listing_id FROM ods_ewa.aus_ewa_loan_biz_t_loan_application WHERE CAST(isactive AS INT) = 1
    )
    GROUP BY l.listing_id
    HAVING COUNT(*) > 1
) invalid_listing;

-- ============================================================================
-- 1. 运行参数：一行，统一观察日期与快照扫描边界。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_param_obs_date;
CREATE TABLE model.tmp_eliam_wagego_param_obs_date
COMMENT '运行参数；恒为一行；obs_dt 为全量最新快照日，snapshot_start_dt 为有效申请最早申请日前一月'
AS
SELECT
     (SELECT MAX(TO_DATE(dt)) FROM edw_ewa.dwb_asset_debt_dtl_snp) AS obs_dt
    ,(SELECT ADD_MONTHS(MIN(TO_DATE(inserttime)), -1)
      FROM ods_ewa.aus_ewa_loan_biz_t_loan_application
      WHERE CAST(isactive AS INT) = 1) AS snapshot_start_dt
;

SELECT ASSERT_TRUE(obs_dt IS NOT NULL AND snapshot_start_dt IS NOT NULL,
                   'observation date or snapshot start date is null') AS check_date_parameters
FROM model.tmp_eliam_wagego_param_obs_date;

SELECT ASSERT_TRUE(COUNT(*) = 0, 'debt source listing/period/date is null or duplicated') AS check_debt_source_key
FROM (
    SELECT d.listing_id, CAST(d.period_no AS INT) AS period_no, TO_DATE(d.dt) AS stat_date
    FROM edw_ewa.dwb_asset_debt_dtl_snp d
    CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
    WHERE TO_DATE(d.dt) BETWEEN p.snapshot_start_dt AND p.obs_dt
    GROUP BY d.listing_id, CAST(d.period_no AS INT), TO_DATE(d.dt)
    HAVING d.listing_id IS NULL OR CAST(d.period_no AS INT) IS NULL OR COUNT(*) > 1
) invalid_debt;

-- ============================================================================
-- 2. 借款日快照：listing_id × stat_date；一期金额仅参与一次聚合。
-- 金额 SUM、首期 MAX、全期结清判断、未知状态兜底全部沿用原表达式。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_stg_debt_snp;
CREATE TABLE model.tmp_eliam_wagego_stg_debt_snp
COMMENT '借款日债务快照；唯一键 listing_id/stat_date；期次聚合，支持最新日、标签日与MOB取数'
AS
SELECT
     d.listing_id
    ,TO_DATE(d.dt) AS stat_date
    ,MIN(CAST(d.init_due_date AS DATE)) AS init_due_date
    ,MAX(CASE WHEN CAST(d.period_no AS INT) = 1 THEN CAST(d.user_actual_repay_time AS TIMESTAMP) END) AS first_repay_time
    ,CASE WHEN COUNT(*) = SUM(CASE WHEN CAST(d.debt_status AS INT) = 2 THEN 1 ELSE 0 END) THEN MAX(CAST(d.user_actual_repay_time AS TIMESTAMP)) END AS user_actual_repay_time
    ,CASE MAX(CASE CAST(d.debt_status AS INT) WHEN 4 THEN 3 WHEN 1 THEN 2 WHEN 2 THEN 1 ELSE 0 END) WHEN 3 THEN 4 WHEN 2 THEN 1 WHEN 1 THEN 2 ELSE MAX(CAST(d.debt_status AS INT)) END AS debt_status
    ,MAX(CAST(d.hist_overdue_days AS INT)) AS hist_overdue_days
    ,MAX(CAST(d.current_overdue_days AS INT)) AS current_overdue_days
    ,SUM(CAST(d.principal AS DOUBLE)) AS principal
    ,SUM(CAST(d.repay_amount AS DOUBLE)) AS repay_amount
    ,SUM(CAST(d.owing_amount AS DOUBLE)) AS owing_amount
FROM edw_ewa.dwb_asset_debt_dtl_snp d
CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
WHERE TO_DATE(d.dt) BETWEEN p.snapshot_start_dt AND p.obs_dt
GROUP BY d.listing_id, TO_DATE(d.dt)
;

-- ============================================================================
-- 3. 申请样本与观察日特征：loan_no 唯一，保留未成功申请。
-- 申请序号只计算一次；成功放款序号也只计算一次；无 Y 标签字段。
-- 风控事件以 flow_id 取最新；updatetime/inserttime 并列沿用原规则，歧义由验收检查报告。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_sample;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_sample
COMMENT '申请样本及观察日债务特征；唯一键 loan_no；含全部有效申请，disburse_seq/user_type仅成功放款赋值'
AS
WITH application_base AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,a.status AS apply_status
        ,CAST(a.inserttime AS TIMESTAMP) AS apply_time
        ,CAST(a.apply_disburse_time AS TIMESTAMP) AS apply_disburse_time
        ,ROW_NUMBER() OVER (PARTITION BY a.user_id ORDER BY CAST(a.inserttime AS TIMESTAMP), a.loan_no) AS apply_seq
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
),
latest_risk_event AS (
    SELECT
         t.flow_id AS loan_no
        ,CAST(t.application_id AS STRING) AS application_id  -- 仅展示，不参与关联
        ,GET_JSON_OBJECT(t.params, '$.appId') AS app_id
        ,CAST(t.inserttime AS TIMESTAMP) AS strategy_time
        ,CAST(t.retry_count AS INT) AS retry_count
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
        ,TO_DATE(a.apply_time) AS apply_date
        ,DATE_FORMAT(a.apply_time, 'yyyy-MM') AS apply_month
        ,CASE WHEN a.apply_status = 'DISBURSE_SUCCESS' THEN a.apply_disburse_time END AS disburse_time
        ,a.apply_seq
        ,CASE WHEN a.apply_seq = 1 THEN 1 ELSE 0 END AS is_first_apply_in_window
        ,e.strategy_time
        ,e.retry_count
    FROM application_base a
    LEFT JOIN latest_risk_event e
      ON a.loan_no = e.loan_no
),
loan_snapshot AS (
    SELECT
         a.*
        ,CAST(l.real_amount AS DOUBLE) AS real_amount
        ,CAST(l.apply_amount AS DOUBLE) AS apply_amount
        ,CAST(l.interest AS DOUBLE) AS interest
        ,CAST(l.service_fee AS DOUBLE) AS service_fee
        ,CAST(l.term_quantity AS INT) AS term_quantity
        ,l.term_unit
        ,l.total_period
        ,CAST(l.is_deal AS INT) AS is_deal
        ,CAST(l.withdraw_time AS TIMESTAMP) AS withdraw_time
        ,CAST(l.list_due_date AS DATE) AS list_due_date
        ,s.listing_id AS debt_listing_id
        ,s.init_due_date
        ,s.first_repay_time
        ,s.user_actual_repay_time
        ,s.debt_status
        ,CASE s.debt_status WHEN 1 THEN '未结清' WHEN 2 THEN '已结清' WHEN 4 THEN '逾期中' ELSE CAST(s.debt_status AS STRING) END AS debt_status_desc
        ,s.hist_overdue_days
        ,s.current_overdue_days
        ,s.principal AS debt_principal
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
ranked_sample AS (
    SELECT
         s.*
        -- 非成功申请只贡献 0；成功申请的累计数等价于先过滤成功申请再 ROW_NUMBER。
        -- 显式转 INT，与原 application_rank 的类型一致；NULL 时间/用户沿用 Spark 原排序与分组规则。
        ,CASE WHEN s.is_disburse_success = 1 THEN
             CAST(SUM(s.is_disburse_success) OVER (
                 PARTITION BY s.user_id ORDER BY s.disburse_time, s.loan_no
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
             ) AS INT) END AS disburse_seq
    FROM loan_snapshot s
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
    ,b.debt_listing_id
    ,b.first_repay_time
    ,b.disburse_seq
    ,CASE WHEN b.is_disburse_success = 1
          THEN CASE WHEN b.disburse_seq = 1 THEN 'New' ELSE 'Old' END END AS user_type
    ,CASE WHEN b.debt_listing_id IS NOT NULL THEN DATEDIFF(b.init_due_date, TO_DATE(b.disburse_time)) END AS loan_term_contract_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN DATEDIFF(TO_DATE(b.user_actual_repay_time), TO_DATE(b.disburse_time)) END AS loan_term_actual_days
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN CASE WHEN TO_DATE(b.user_actual_repay_time) < b.init_due_date THEN 1 ELSE 0 END END AS is_early_settlement
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN 1 ELSE 0 END END AS is_current_overdue
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS current_ovd_amt
FROM ranked_sample b
;

-- ============================================================================
-- 4. 戳额匹配：loan_no 唯一；来源优先级先于时间，额度日志按 relate_id 取最大 id。
-- 候选只传递匹配所需字段，用户和放款时间最终从放款样本取回。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_stamp;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_stamp
COMMENT '成功放款的最近戳额及授信额度；唯一键 loan_no；额度申请优先，风险事件兜底'
AS
WITH disbursed_loan AS (
    SELECT loan_no, user_id, disburse_time
    FROM model.tmp_eliam_wagego_dwd_loan_sample
    WHERE is_disburse_success = 1
),
apply_stamp AS (
    SELECT
         a.borrower_id AS user_id
        ,CAST(a.inserttime AS TIMESTAMP) AS stamp_time
        ,a.limit_apply_no
        ,a.flow_no
        ,CAST(a.id AS BIGINT) AS stamp_id
    FROM ods_ewa.aus_listing_tb_loan_limit_apply a
    WHERE CAST(a.isactive AS INT) = 1
      AND CAST(a.biz_type AS INT) = 400
),
event_stamp AS (
    SELECT
         e.user_id
        ,CAST(e.inserttime AS TIMESTAMP) AS stamp_time
        ,CAST(NULL AS STRING) AS limit_apply_no
        ,e.flow_id AS flow_no
        ,CAST(e.id AS BIGINT) AS stamp_id
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
stamp_candidates AS (
    SELECT user_id, stamp_time, limit_apply_no, flow_no, stamp_id,
           'limit_apply' AS stamp_source, 1 AS source_priority
    FROM apply_stamp
    UNION ALL
    SELECT user_id, stamp_time, limit_apply_no, flow_no, stamp_id,
           'risk_event' AS stamp_source, 2 AS source_priority
    FROM event_stamp
),
ranked_stamp AS (
    SELECT
         d.loan_no
        ,s.stamp_time
        ,s.limit_apply_no
        ,s.flow_no
        ,s.stamp_source
        ,ROW_NUMBER() OVER (
            PARTITION BY d.loan_no
            ORDER BY s.source_priority, s.stamp_time DESC, s.stamp_id DESC
         ) AS rn
    FROM disbursed_loan d
    JOIN stamp_candidates s
      ON d.user_id = s.user_id
     AND s.stamp_time <= d.disburse_time
),
matched AS (
    SELECT loan_no, stamp_time, limit_apply_no, flow_no, stamp_source
    FROM ranked_stamp
    WHERE rn = 1
),
limit_grant AS (
    SELECT
         l.relate_id
        ,CAST(l.total_amount_before AS DOUBLE) AS limit_total_before
        ,CAST(l.total_amount_after AS DOUBLE) AS limit_total_after
        ,CAST(l.available_amount_after AS DOUBLE) AS limit_available_after
        ,CAST(l.occupied_amount_after AS DOUBLE) AS limit_occupied_after
        ,CAST(l.expire_time_after AS TIMESTAMP) AS limit_expire_time
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
    ,m.flow_no AS stamp_flow_no
    ,g.limit_total_before
    ,g.limit_total_after
    ,g.limit_available_after
    ,g.limit_occupied_after
    ,g.limit_expire_time
FROM disbursed_loan d
LEFT JOIN matched m
  ON d.loan_no = m.loan_no
LEFT JOIN limit_grant g
  ON m.flow_no = g.relate_id
 AND g.rn = 1
;

-- ============================================================================
-- 5. 借款级 Y 标签：loan_no 唯一，仅成功放款；直接按 listing_id × label_obs_dt 取快照。
-- is_label_matured 不代表标签日快照存在；DPD 与 FPD 的缺失处理沿用原口径。
-- application_rank 为既有对外字段名，来自样本 disburse_seq；不新增第二次窗口排序。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dws_vintage_loan;
CREATE TABLE model.tmp_eliam_wagego_dws_vintage_loan
COMMENT '成功放款固定窗口Y标签；唯一键 loan_no；标签日为首个应还日加31天，保留缺快照的NULL语义'
AS
WITH successful_loan AS (
    SELECT
         s.loan_no
        ,s.user_id
        ,s.listing_id
        ,s.disburse_time
        ,s.real_amount
        ,s.term_unit
        ,s.init_due_date
        ,s.debt_listing_id
        ,s.first_repay_time
        ,s.is_deal
        ,s.obs_dt
        ,s.disburse_seq
        ,s.user_type
        ,DATE_ADD(s.init_due_date, 31) AS label_obs_dt
    FROM model.tmp_eliam_wagego_dwd_loan_sample s
    WHERE s.is_disburse_success = 1
),
label_snapshot AS (
    SELECT
         l.*
        ,d.current_overdue_days AS label_current_overdue_days
        ,d.hist_overdue_days AS label_hist_overdue_days
        ,CASE WHEN l.is_deal = 1 AND l.debt_listing_id IS NOT NULL
                   AND l.label_obs_dt IS NOT NULL
                   AND l.label_obs_dt >= TO_DATE(l.disburse_time)
                   AND l.label_obs_dt <= l.obs_dt
              THEN 1 ELSE 0 END AS is_label_matured
        ,COALESCE(d.first_repay_time,
                  CASE WHEN l.first_repay_time IS NOT NULL
                             AND TO_DATE(l.first_repay_time) <= l.label_obs_dt
                       THEN l.first_repay_time END) AS repay_at_label_obs
    FROM successful_loan l
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp d
      ON l.listing_id = d.listing_id
     AND l.label_obs_dt = d.stat_date
)
SELECT
     l.loan_no
    ,l.user_id
    ,l.listing_id
    ,l.disburse_time
    ,DATE_FORMAT(l.disburse_time, 'yyyy-MM') AS disburse_month
    ,l.real_amount
    ,l.term_unit
    ,l.init_due_date
    ,l.label_obs_dt
    ,l.is_label_matured
    ,l.obs_dt AS data_as_of
    ,DATEDIFF(l.obs_dt, TO_DATE(l.disburse_time)) AS days_on_book
    ,CASE WHEN l.is_label_matured = 1 THEN l.label_current_overdue_days END AS dpd_at_label_obs
    ,CASE WHEN l.is_label_matured = 1 THEN l.label_hist_overdue_days END AS hist_dpd_at_label_obs
    ,CASE WHEN l.is_label_matured = 1 AND l.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN l.label_current_overdue_days > 0 THEN 1 ELSE 0 END END AS is_current_overdue_at_label_obs
    ,CASE WHEN l.is_label_matured = 1 AND l.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN l.label_current_overdue_days > 0 THEN l.real_amount ELSE 0 END END AS current_ovd_amt_at_label_obs
    ,CASE WHEN l.is_label_matured = 1 AND l.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN l.label_current_overdue_days >= 5 THEN 1 ELSE 0 END END AS is_5plus_at_label_obs
    ,CASE WHEN l.is_label_matured = 1 AND l.label_current_overdue_days IS NOT NULL
          THEN CASE WHEN l.label_current_overdue_days > 30 THEN 1 ELSE 0 END END AS is_30plus_at_label_obs
    ,CASE WHEN l.is_label_matured = 1 AND l.label_hist_overdue_days IS NOT NULL
          THEN CASE WHEN l.label_hist_overdue_days > 30 THEN 1 ELSE 0 END END AS is_ever_30plus_in_window
    ,CASE WHEN l.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd3_obs
    ,CASE WHEN l.is_label_matured = 1
          THEN CASE WHEN l.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(l.repay_at_label_obs) > DATE_ADD(l.init_due_date, 3) THEN 1 ELSE 0 END
                    ELSE CASE WHEN l.label_obs_dt > DATE_ADD(l.init_due_date, 3) THEN 1 ELSE 0 END END END AS is_fpd3_ovd
    ,CASE WHEN l.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd7_obs
    ,CASE WHEN l.is_label_matured = 1
          THEN CASE WHEN l.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(l.repay_at_label_obs) > DATE_ADD(l.init_due_date, 7) THEN 1 ELSE 0 END
                    ELSE CASE WHEN l.label_obs_dt > DATE_ADD(l.init_due_date, 7) THEN 1 ELSE 0 END END END AS is_fpd7_ovd
    ,CASE WHEN l.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd15_obs
    ,CASE WHEN l.is_label_matured = 1
          THEN CASE WHEN l.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(l.repay_at_label_obs) > DATE_ADD(l.init_due_date, 15) THEN 1 ELSE 0 END
                    ELSE CASE WHEN l.label_obs_dt > DATE_ADD(l.init_due_date, 15) THEN 1 ELSE 0 END END END AS is_fpd15_ovd
    ,CASE WHEN l.is_label_matured = 1 THEN 1 ELSE NULL END AS is_fpd30_obs
    ,CASE WHEN l.is_label_matured = 1
          THEN CASE WHEN l.repay_at_label_obs IS NOT NULL THEN CASE WHEN TO_DATE(l.repay_at_label_obs) > DATE_ADD(l.init_due_date, 30) THEN 1 ELSE 0 END
                    ELSE CASE WHEN l.label_obs_dt > DATE_ADD(l.init_due_date, 30) THEN 1 ELSE 0 END END END AS is_fpd30_ovd
    ,l.disburse_seq AS application_rank
    ,l.user_type
FROM label_snapshot l
;

-- ============================================================================
-- 6. MOB 明细：loan_no × mob_no 唯一；每笔成功放款固定保留 12 行。
-- obs_dt 为各 MOB 月末，data_as_of 为本次最新快照日，两者含义不同。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dws_vintage_mob;
CREATE TABLE model.tmp_eliam_wagego_dws_vintage_mob
COMMENT '借款MOB长表；唯一键 loan_no/mob_no；MOB1至12，未成熟或缺快照的逾期标签为NULL'
AS
WITH mob AS (
    SELECT EXPLODE(SEQUENCE(1, 12)) AS mob_no
),
obs AS (
    SELECT
         s.loan_no
        ,s.user_id
        ,s.listing_id
        ,TO_DATE(s.disburse_time) AS disburse_date
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
    ,CASE WHEN o.obs_dt <= o.data_as_of THEN 1 ELSE 0 END AS is_matured
    ,d.current_overdue_days AS dpd
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
-- 7. 固定窗口月报：disburse_month 唯一（允许 NULL 放款月分组）。
-- monthly_metrics 只汇总一次；外层才舍入和算比率，避免用舍入金额或补零计数改变原比率。
-- 历史30+仍沿用当前DPD可观测样本作分母；FPD仍沿用统一成熟样本作分母。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_ads_vintage_month;
CREATE TABLE model.tmp_eliam_wagego_ads_vintage_month
COMMENT '固定窗口Vintage月报；粒度为放款月；金额与笔数双口径，百分比及NULL分母处理沿用原规则'
AS
WITH monthly_metrics AS (
    SELECT
         disburse_month
        ,MAX(data_as_of) AS data_as_of_raw
        ,COUNT(*) AS loan_cnt_raw
        ,SUM(real_amount) AS loan_amt_raw
        ,SUM(is_label_matured) AS matured_cnt_raw
        ,SUM(CASE WHEN is_label_matured = 1 THEN real_amount ELSE 0 END) AS matured_amt_raw
        ,SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN 1 ELSE 0 END) AS obs_cnt_raw
        ,SUM(CASE WHEN is_label_matured = 1 AND dpd_at_label_obs IS NOT NULL THEN real_amount ELSE 0 END) AS obs_amt_raw
        ,SUM(CASE WHEN is_30plus_at_label_obs = 1 THEN 1 ELSE 0 END) AS cur_30plus_cnt_raw
        ,SUM(CASE WHEN is_30plus_at_label_obs = 1 THEN real_amount ELSE 0 END) AS cur_30plus_amt_raw
        ,SUM(CASE WHEN is_current_overdue_at_label_obs = 1 THEN 1 ELSE 0 END) AS cur_ovd_cnt_raw
        ,SUM(current_ovd_amt_at_label_obs) AS cur_ovd_amt_raw
        ,SUM(is_ever_30plus_in_window) AS ever_30plus_cnt_raw
        ,SUM(CASE WHEN is_ever_30plus_in_window = 1 THEN real_amount ELSE 0 END) AS ever_30plus_amt_raw
        ,SUM(is_fpd3_obs) AS fpd3_obs_cnt_raw
        ,SUM(is_fpd3_ovd) AS fpd3_ovd_cnt_raw
        ,SUM(CASE WHEN is_fpd3_obs = 1 THEN real_amount ELSE 0 END) AS fpd3_obs_amt_raw
        ,SUM(CASE WHEN is_fpd3_ovd = 1 THEN real_amount ELSE 0 END) AS fpd3_ovd_amt_raw
        ,SUM(is_fpd7_obs) AS fpd7_obs_cnt_raw
        ,SUM(is_fpd7_ovd) AS fpd7_ovd_cnt_raw
        ,SUM(CASE WHEN is_fpd7_obs = 1 THEN real_amount ELSE 0 END) AS fpd7_obs_amt_raw
        ,SUM(CASE WHEN is_fpd7_ovd = 1 THEN real_amount ELSE 0 END) AS fpd7_ovd_amt_raw
        ,SUM(is_fpd15_obs) AS fpd15_obs_cnt_raw
        ,SUM(is_fpd15_ovd) AS fpd15_ovd_cnt_raw
        ,SUM(CASE WHEN is_fpd15_obs = 1 THEN real_amount ELSE 0 END) AS fpd15_obs_amt_raw
        ,SUM(CASE WHEN is_fpd15_ovd = 1 THEN real_amount ELSE 0 END) AS fpd15_ovd_amt_raw
        ,SUM(is_fpd30_obs) AS fpd30_obs_cnt_raw
        ,SUM(is_fpd30_ovd) AS fpd30_ovd_cnt_raw
        ,SUM(CASE WHEN is_fpd30_obs = 1 THEN real_amount ELSE 0 END) AS fpd30_obs_amt_raw
        ,SUM(CASE WHEN is_fpd30_ovd = 1 THEN real_amount ELSE 0 END) AS fpd30_ovd_amt_raw
    FROM model.tmp_eliam_wagego_dws_vintage_loan
    GROUP BY disburse_month
)
SELECT
     disburse_month
    ,data_as_of_raw AS data_as_of
    ,loan_cnt_raw AS loan_cnt
    ,ROUND(loan_amt_raw, 2) AS loan_amt
    ,matured_cnt_raw AS matured_cnt
    ,ROUND(matured_amt_raw, 2) AS matured_amt
    ,obs_cnt_raw AS obs_cnt
    ,ROUND(obs_amt_raw, 2) AS obs_amt
    ,cur_30plus_cnt_raw AS cur_30plus_cnt
    ,ROUND(cur_30plus_amt_raw, 2) AS cur_30plus_amt
    ,cur_ovd_cnt_raw AS cur_ovd_cnt
    ,ROUND(COALESCE(cur_ovd_amt_raw, 0), 2) AS cur_ovd_amt
    ,ROUND(100.0 * cur_ovd_cnt_raw / NULLIF(obs_cnt_raw, 0), 2) AS cur_ovd_rate
    ,ROUND(100.0 * cur_ovd_amt_raw / NULLIF(obs_amt_raw, 0), 2) AS cur_ovd_amt_rate
    ,COALESCE(ever_30plus_cnt_raw, 0) AS ever_30plus_cnt
    ,ROUND(ever_30plus_amt_raw, 2) AS ever_30plus_amt
    ,ROUND(100.0 * ever_30plus_cnt_raw / NULLIF(obs_cnt_raw, 0), 2) AS ever_30plus_rate
    ,ROUND(100.0 * ever_30plus_amt_raw / NULLIF(obs_amt_raw, 0), 2) AS ever_30plus_amt_rate
    ,COALESCE(fpd3_obs_cnt_raw, 0) AS fpd3_obs_cnt
    ,COALESCE(fpd3_ovd_cnt_raw, 0) AS fpd3_ovd_cnt
    ,ROUND(fpd3_obs_amt_raw, 2) AS fpd3_obs_amt
    ,ROUND(fpd3_ovd_amt_raw, 2) AS fpd3_ovd_amt
    ,ROUND(100.0 * fpd3_ovd_cnt_raw / NULLIF(fpd3_obs_cnt_raw, 0), 2) AS fpd3_ovd_rate
    ,ROUND(100.0 * fpd3_ovd_amt_raw / NULLIF(fpd3_obs_amt_raw, 0), 2) AS fpd3_ovd_amt_rate
    ,COALESCE(fpd7_obs_cnt_raw, 0) AS fpd7_obs_cnt
    ,COALESCE(fpd7_ovd_cnt_raw, 0) AS fpd7_ovd_cnt
    ,ROUND(fpd7_obs_amt_raw, 2) AS fpd7_obs_amt
    ,ROUND(fpd7_ovd_amt_raw, 2) AS fpd7_ovd_amt
    ,ROUND(100.0 * fpd7_ovd_cnt_raw / NULLIF(fpd7_obs_cnt_raw, 0), 2) AS fpd7_ovd_rate
    ,ROUND(100.0 * fpd7_ovd_amt_raw / NULLIF(fpd7_obs_amt_raw, 0), 2) AS fpd7_ovd_amt_rate
    ,COALESCE(fpd15_obs_cnt_raw, 0) AS fpd15_obs_cnt
    ,COALESCE(fpd15_ovd_cnt_raw, 0) AS fpd15_ovd_cnt
    ,ROUND(fpd15_obs_amt_raw, 2) AS fpd15_obs_amt
    ,ROUND(fpd15_ovd_amt_raw, 2) AS fpd15_ovd_amt
    ,ROUND(100.0 * fpd15_ovd_cnt_raw / NULLIF(fpd15_obs_cnt_raw, 0), 2) AS fpd15_ovd_rate
    ,ROUND(100.0 * fpd15_ovd_amt_raw / NULLIF(fpd15_obs_amt_raw, 0), 2) AS fpd15_ovd_amt_rate
    ,COALESCE(fpd30_obs_cnt_raw, 0) AS fpd30_obs_cnt
    ,COALESCE(fpd30_ovd_cnt_raw, 0) AS fpd30_ovd_cnt
    ,ROUND(fpd30_obs_amt_raw, 2) AS fpd30_obs_amt
    ,ROUND(fpd30_ovd_amt_raw, 2) AS fpd30_ovd_amt
    ,ROUND(100.0 * fpd30_ovd_cnt_raw / NULLIF(fpd30_obs_cnt_raw, 0), 2) AS fpd30_ovd_rate
    ,ROUND(100.0 * fpd30_ovd_amt_raw / NULLIF(fpd30_obs_amt_raw, 0), 2) AS fpd30_ovd_amt_rate
FROM monthly_metrics
;

-- ============================================================================
-- 8. MOB 曲线：disburse_month × user_type × mob_no 唯一；允许 NULL 放款月。
-- curve_metrics 只汇总一次；未观测组的 SUM 标签保留 NULL，不统一 COALESCE 为0。
-- ============================================================================
DROP TABLE IF EXISTS model.tmp_eliam_wagego_ads_vintage_curve;
CREATE TABLE model.tmp_eliam_wagego_ads_vintage_curve
COMMENT 'Vintage MOB分群曲线；粒度为放款月/新老客/MOB；5+和30+按有DPD且成熟的样本计算'
AS
WITH curve_metrics AS (
    SELECT
         disburse_month
        ,user_type
        ,mob_no
        ,MAX(data_as_of) AS data_as_of_raw
        ,COUNT(*) AS cohort_cnt_raw
        ,SUM(real_amount) AS cohort_amt_raw
        ,SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN 1 ELSE 0 END) AS obs_cnt_raw
        ,SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN real_amount ELSE 0 END) AS obs_amt_raw
        ,SUM(is_5plus) AS cnt_5plus_raw
        ,SUM(CASE WHEN is_5plus = 1 THEN real_amount ELSE 0 END) AS amt_5plus_raw
        ,SUM(is_30plus) AS cnt_30plus_raw
        ,SUM(CASE WHEN is_30plus = 1 THEN real_amount ELSE 0 END) AS amt_30plus_raw
    FROM model.tmp_eliam_wagego_dws_vintage_mob
    GROUP BY disburse_month, user_type, mob_no
)
SELECT
     disburse_month
    ,user_type
    ,mob_no
    ,data_as_of_raw AS data_as_of
    ,cohort_cnt_raw AS cohort_cnt
    ,ROUND(cohort_amt_raw, 2) AS cohort_amt
    ,obs_cnt_raw AS obs_cnt
    ,ROUND(obs_amt_raw, 2) AS obs_amt
    ,cnt_5plus_raw AS cnt_5plus
    ,ROUND(amt_5plus_raw, 2) AS amt_5plus
    ,ROUND(100.0 * cnt_5plus_raw / NULLIF(obs_cnt_raw, 0), 2) AS rate_5plus
    ,ROUND(100.0 * amt_5plus_raw / NULLIF(obs_amt_raw, 0), 2) AS rate_5plus_amt
    ,cnt_30plus_raw AS cnt_30plus
    ,ROUND(amt_30plus_raw, 2) AS amt_30plus
    ,ROUND(100.0 * cnt_30plus_raw / NULLIF(obs_cnt_raw, 0), 2) AS rate_30plus
    ,ROUND(100.0 * amt_30plus_raw / NULLIF(obs_amt_raw, 0), 2) AS rate_30plus_amt
FROM curve_metrics
;

