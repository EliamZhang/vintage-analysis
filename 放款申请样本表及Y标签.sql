SET spark.sql.session.timeZone = Australia/Sydney;
-- 会话时区固定为悉尼时间：后续所有 TO_DATE / DATE_FORMAT / 日期加减都按这个时区解释。

-- ============================================================================
-- 本文件构建“放款申请样本表 + Y 标签”：
--     model.tmp_eliam_wagego_dwd_loan_apply_label
--
-- 整体分三步：
--   第 1 步  tmp_eliam_wagego_param_obs_date
--            取债务快照表里最新的快照日期，作为全局“观察日” obs_dt。
--   第 2 步  tmp_eliam_wagego_stg_debt_snp
--            把“借据 × 期数 × 快照日”的债务明细，汇总成“借据 × 快照日”一行，
--            得到每笔借据每天的状态（是否结清、逾期天数、未还金额等）。
--   第 3 步  tmp_eliam_wagego_dwd_loan_apply_label（本文件的目标表）
--            以“贷款申请”为一行，关联放款信息、观察日状态和各类 Y 标签。
--
-- 最终表一行 = 一笔贷款申请（loan_no），包含：
--   · 申请 / 放款基本信息
--   · 观察日（obs_dt）当天的借据状态
--   · 四组 Y 标签：
--       due : 首期应还日 +31 天这一时点的逾期情况
--       FPD : 首期应还日后 3/7/14/30 天内是否逾期
--       obs : 观察日当天是否逾期
--       MOB : 放款后各月月末的逾期 / 剩余本金
--
-- 名词说明：
--   FPD（First Payment Default）首期还款表现：第一次应还日之后有没有逾期。
--   DPD（Days Past Due）逾期天数。
--   MOB（Month on Book）账龄月数：放款后经过的第几个月。
--   obs_dt（observation date）观察日：全表统一的“当前时点”。
-- ============================================================================

DROP TABLE IF EXISTS model.tmp_eliam_wagego_param_obs_date;
-- 参数表：全局观察日 obs_dt。
-- edw_ewa.dwb_asset_debt_dtl_snp 是债务快照表（按 dt 存放每天的借据状态），
-- 取 MAX(dt) = 目前能拿到的最新快照日，作为全流程统一的“当前时点”。
-- 作用：1) 定义所有“当前状态”字段的时间点；2) 判断标签观察窗口是否已经走完。
CREATE TABLE model.tmp_eliam_wagego_param_obs_date AS
SELECT MAX(TO_DATE(dt)) AS obs_dt
FROM edw_ewa.dwb_asset_debt_dtl_snp
;

-- ----------------------------------------------------------------------------
-- 第 2 步：借据级日快照宽表 tmp_eliam_wagego_stg_debt_snp
--
-- 源表 edw_ewa.dwb_asset_debt_dtl_snp 是债务明细快照：
-- 同一笔借据（listing_id）的每一期（period_no）在同一个快照日（dt）各占一行。
-- 本段先统一字段类型，再按“借据 × 快照日”把多期汇总成一行。
--
-- 这张表在目标表中会被用在三个不同日期上：
--     obs_dt        → 观察日当天的状态
--     label_obs_dt  → 首期应还日 + 31 天（标签时点）的状态
--     mob_obs_dt    → 各 MOB 月末的状态
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS model.tmp_eliam_wagego_stg_debt_snp;
CREATE TABLE model.tmp_eliam_wagego_stg_debt_snp AS
WITH src AS (
    SELECT
         d.listing_id                                          -- 借据号（放款单号），后续主要关联键
        ,d.user_id                                             -- 用户 ID
        ,TO_DATE(d.dt)                                        AS stat_date  -- 快照日期：这一行描述的是哪一天的状态
        ,CAST(d.init_due_date AS DATE)                        AS init_due_date -- 该期的应还日
        ,CAST(d.period_no AS INT)                             AS period_no  -- 期数（1 = 第 1 期）
        ,CAST(d.user_actual_repay_time AS TIMESTAMP)          AS user_actual_repay_time -- 该期实际还款时间（未还为 NULL）
        ,CAST(d.debt_status AS INT)                           AS debt_status -- 该期状态码（4=逾期中，1=未结清，2=已结清；依据下方映射推断）
        ,CAST(d.hist_overdue_days AS INT)                     AS hist_overdue_days -- 历史最大逾期天数
        ,CAST(d.current_overdue_days AS INT)                  AS current_overdue_days -- 当前逾期天数（未逾期为 0）
        ,CAST(d.principal AS DOUBLE)                          AS principal -- 该期本金
        ,CAST(d.repay_amount AS DOUBLE)                       AS repay_amount -- 该期已还金额
        ,CAST(d.owing_amount AS DOUBLE)                       AS owing_amount -- 该期未还金额
        ,CAST(d.owing_principal AS DOUBLE)                    AS owing_principal -- 该期未还本金
    FROM edw_ewa.dwb_asset_debt_dtl_snp d
    CROSS JOIN model.tmp_eliam_wagego_param_obs_date p        -- 引入观察日，作为快照上限
    WHERE TO_DATE(d.dt) <= p.obs_dt                           -- 只取观察日及以前的快照，避免用到未来数据
      AND TO_DATE(d.dt) >= (
          -- 下限：最早一笔有效申请时间往前推 1 个月。
          -- 目的：覆盖所有样本借据的完整历史，同时裁掉更早的无关数据。
          SELECT ADD_MONTHS(MIN(TO_DATE(a.inserttime)), -1)
          FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
          WHERE CAST(a.isactive AS INT) = 1
      )
),
agg AS (
    -- 把同一借据、同一快照日的多期数据合成一行。
    -- 分组键：listing_id（借据）+ stat_date（快照日）。
    SELECT
         listing_id
        ,MAX(user_id)                                         AS user_id          -- 同一借据的 user_id 相同，取 MAX 只是为了让其出现在结果里
        ,stat_date
        ,MIN(init_due_date)                                   AS init_due_date    -- 最早一期的应还日 = 整笔借据的首个应还日（FPD 标签的基准日）
        ,MAX(CASE WHEN period_no = 1 THEN user_actual_repay_time END) AS first_repay_time -- 第 1 期的实际还款时间（只取第 1 期）
        ,CASE WHEN COUNT(*) = SUM(CASE WHEN debt_status = 2 THEN 1 ELSE 0 END) THEN MAX(user_actual_repay_time) END AS user_actual_repay_time
        -- 上一行：只有“所有期都已结清（debt_status=2）”时，才取各期最大的实还时间 = 整笔借据的结清时间；否则为 NULL
        ,MAX(CASE debt_status WHEN 4 THEN 3 WHEN 1 THEN 2 WHEN 2 THEN 1 ELSE 0 END) AS status_priority
        -- 上一行：给状态排优先级：逾期(4) > 未结清(1) > 已结清(2) > 其它(0)。
        -- 取 MAX 相当于“取最严重的状态”：只要有一期逾期，整笔借据就算逾期。
        ,MAX(debt_status)                                     AS max_debt_status -- 原始状态码最大值，仅在状态码不属于 1/2/4 时作为兜底
        ,MAX(hist_overdue_days)                               AS hist_overdue_days    -- 各期里最差的历史逾期天数
        ,MAX(current_overdue_days)                            AS current_overdue_days -- 各期里最差的当前逾期天数
        ,SUM(principal)                                       AS principal        -- 所有期本金合计
        ,SUM(repay_amount)                                    AS repay_amount     -- 所有期已还金额合计
        ,SUM(owing_amount)                                    AS owing_amount     -- 所有期未还金额合计
        ,SUM(owing_principal)                                 AS owing_principal  -- 所有期未还本金合计
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
    -- 上一行：把优先级还原成状态码：3→4（逾期中）、2→1（未结清）、1→2（已结清），其余用原始状态码兜底
    ,CASE status_priority WHEN 3 THEN '逾期中' WHEN 2 THEN '未结清' WHEN 1 THEN '已结清' ELSE CAST(max_debt_status AS STRING) END AS debt_status_desc
    -- 上一行：状态码的中文说明，与上一行一一对应
    ,hist_overdue_days
    ,current_overdue_days
    ,principal
    ,repay_amount
    ,owing_amount
    ,owing_principal
FROM agg
;

-- ----------------------------------------------------------------------------
-- 第 3 步：目标表 model.tmp_eliam_wagego_dwd_loan_apply_label
--
-- 一行 = 贷款申请表里的一条有效申请（loan_no），把“申请 → 放款 → 还款表现”串起来并打上 Y 标签。
--
-- 下面按 CTE 顺序说明，每个 CTE 是一个加工环节：
--   apply          申请主表
--   ranked         放款成功借据在用户内的排名（用于 New/Old）
--   event          关联风控事件
--   stamp          用户侧的 stamp 事件池（业务含义见 CTE 内说明）
--   stamp_matched  为每笔申请匹配申请前最近一次 stamp
--   loan_apply     申请 + 事件 + 排名 + stamp 合并
--   latest         关联放款主表、观察日债务快照
--   base           关联标签时点（首期应还日 + 31 天）的债务快照
--   mob_obs / mob_detail / mob_wide        MOB 逾期标记（MOB1~3）
--   mob_track / mob_track_wide             MOB 剩余本金与 DPD（MOB0~4）
--
-- 使用提示（不属于代码逻辑）：目标表包含全部有效申请，不只看放款成功的记录；
-- 做 vintage 分析时通常还要按 is_disburse_success / is_deal / is_label_matured 再筛样本。
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS model.tmp_eliam_wagego_dwd_loan_apply_label;
CREATE TABLE model.tmp_eliam_wagego_dwd_loan_apply_label AS
WITH apply AS (
    -- 申请主表：一行对应一条有效申请记录。
    -- 这里没有时间过滤，保留全部历史申请；数据是否可用由后面的标签成熟度判断。
    SELECT
         a.loan_no                                            -- 借据号：后续所有关联的主键
        ,a.user_id                                            -- 用户 ID
        ,a.listing_id                                         -- 放款单号：关联放款主表和债务快照用
        ,a.status                                             AS apply_status -- 申请状态原始英文值
        ,CAST(a.inserttime AS TIMESTAMP)                      AS apply_time   -- 申请时间
        ,CAST(a.apply_disburse_time AS TIMESTAMP)             AS apply_disburse_time -- 申请记录上的放款时间
        ,ROW_NUMBER() OVER (PARTITION BY a.user_id ORDER BY CAST(a.inserttime AS TIMESTAMP), a.loan_no) AS apply_seq
        -- 上一行：用户内申请序号：1 = 该用户第一次申请。
        -- 注意：这只是“申请顺序”，不用于 New/Old 判定（New/Old 用下面 ranked 的放款排名）。
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1                         -- 只取有效申请记录
),
ranked AS (
    -- 只看放款成功的申请，按放款时间先后排序：
    -- application_rank = 1 表示该用户第一笔“放款成功”的借据（New），其余为 Old。
    -- 放款时间为空的记录排在最后（NULLS LAST）；loan_no 用于放款时间相同时的稳定排序。
    SELECT
         loan_no
        ,ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY apply_disburse_time ASC NULLS LAST, loan_no) AS application_rank
    FROM apply
    WHERE apply_status = 'DISBURSE_SUCCESS'
),
event AS (
    -- 风控事件任务表：一笔借据（flow_id = loan_no）可能有多条事件，这里每个 flow_id 只保留最新一条
    -- （先按 updatetime 倒序、再按 inserttime 倒序取第 1 条）。
    -- 筛选条件：有效记录 + biz_id = 20050 + flow_id 以 'LN' 开头（LN 是借据号前缀）。
    -- 说明：biz_id = 20050 的具体业务含义在原 SQL 中没有说明，这里只描述它的筛选作用。
    SELECT
         t.flow_id                                            AS loan_no        -- 事件流程号，对应借据号
        ,CAST(t.application_id AS STRING)                     AS application_id -- 风控事件中的申请 ID
        ,GET_JSON_OBJECT(t.params, '$.appId')                 AS app_id        -- 从事件参数 JSON 中取 appId 字段
        ,CAST(t.inserttime AS TIMESTAMP)                      AS strategy_time -- 事件发生时间
        ,CAST(t.retry_count AS INT)                           AS retry_count   -- 事件重试次数
    FROM (
        SELECT
             e.flow_id
            ,e.application_id
            ,e.params
            ,e.inserttime
            ,e.retry_count
            -- 同一 flow_id 内按更新时间倒序编号，rn = 1 即最新一条
            ,ROW_NUMBER() OVER (PARTITION BY e.flow_id ORDER BY CAST(e.updatetime AS TIMESTAMP) DESC NULLS LAST, CAST(e.inserttime AS TIMESTAMP) DESC NULLS LAST) AS rn
        FROM ods_ewa.aus_ewa_risk_risk_event_task e
        WHERE CAST(e.is_active AS INT) = 1
          AND CAST(e.biz_id AS STRING) = '20050'
          AND e.flow_id LIKE 'LN%'
    ) t
    WHERE t.rn = 1 -- 每个 flow_id 只保留最新一条
),
stamp AS (
    -- “stamp”事件池：把两类记录上下拼接，并标注来源优先级（数值越小越优先）。
    --   来源 1：额度申请记录 aus_listing_tb_loan_limit_apply，biz_type = 400
    --   来源 2：风控事件记录 aus_ewa_risk_risk_event_task，biz_id = 10000
    -- 说明：这两类记录在业务上具体代表什么，原 SQL 没有说明；名称沿用代码中的 stamp。
    --      下游只把它们原样输出为 stamp_time / stamp_flow_id，不参与任何 Y 标签计算。
    SELECT
         a.borrower_id                                        AS user_id
        ,CAST(a.inserttime AS TIMESTAMP)                      AS stamp_time
        ,a.flow_no                                            AS stamp_flow_id
        ,CAST(a.id AS BIGINT)                                 AS stamp_id      -- 记录 ID，用于同一时间下的稳定排序
        ,1                                                    AS source_priority -- 来源 1 优先
    FROM ods_ewa.aus_listing_tb_loan_limit_apply a
    WHERE CAST(a.isactive AS INT) = 1
      AND CAST(a.biz_type AS INT) = 400
    UNION ALL
    SELECT
         e.user_id
        ,CAST(e.inserttime AS TIMESTAMP)
        ,e.flow_id
        ,CAST(e.id AS BIGINT)
        ,2                                                    -- 来源 2 次之
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
stamp_matched AS (
    -- 为每笔申请匹配“申请之前最近的一条 stamp”：
    --   1) 只匹配 stamp_time <= apply_time 的记录，避免用到申请之后的信息；
    --   2) 同一用户可能有多条 stamp，按来源优先级 → 时间倒序 → ID 倒序取第 1 条。
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
    -- 把申请、风控事件、放款排名、stamp 合并成一张宽表，并补充状态中文和标记字段。
    -- 全部使用 LEFT JOIN：某笔申请没有对应事件 / stamp 时记录仍保留，相关字段为 NULL。
    SELECT
         a.loan_no
        ,a.user_id
        ,e.application_id                                     -- 来自风控事件，无事件时为 NULL
        ,e.app_id                                             -- 来自风控事件参数，无事件时为 NULL
        ,a.listing_id
        ,a.apply_status
        ,CASE a.apply_status
             WHEN 'DISBURSE_SUCCESS' THEN '放款成功'  WHEN 'DISBURSE'       THEN '放款中'
             WHEN 'DISBURSE_FAILED'  THEN '放款失败'  WHEN 'AUDIT'          THEN '审核中'
             WHEN 'AUDIT_APPROVED'   THEN '审核通过'  WHEN 'AUDIT_REJECTED' THEN '审核拒绝'
             WHEN 'EXPIRED'          THEN '已过期'    WHEN 'INFO_CHANGED'   THEN '信息变更'
             ELSE a.apply_status
         END                                                      AS apply_status_desc -- 状态中文说明
        ,CASE WHEN a.apply_status = 'DISBURSE_SUCCESS' THEN 1 ELSE 0 END AS is_disburse_success -- 是否放款成功
        ,CASE WHEN a.apply_status = 'AUDIT_REJECTED'   THEN 1 ELSE 0 END AS is_reject   -- 是否审核拒绝
        ,CASE WHEN a.apply_status = 'EXPIRED'          THEN 1 ELSE 0 END AS is_expired  -- 是否已过期
        ,CASE WHEN a.apply_status = 'DISBURSE_FAILED'  THEN 1 ELSE 0 END AS is_disburse_failed -- 是否放款失败
        ,a.apply_time
        ,TO_DATE(a.apply_time)                                    AS apply_date  -- 申请日期
        ,DATE_FORMAT(a.apply_time, 'yyyy-MM')                     AS apply_month -- 申请月份
        ,CASE WHEN a.apply_status = 'DISBURSE_SUCCESS' THEN a.apply_disburse_time END AS disburse_time
        -- 上一行：只有放款成功才保留放款时间，其它状态为 NULL
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
    -- 关联两张“借据级”表：
    --   1) edw_ewa.dwb_asset_cmn_listing（放款主表 l）：金额、期限、成交标记等放款属性；
    --   2) tmp_eliam_wagego_stg_debt_snp（观察日快照 s）：obs_dt 当天的借据状态。
    SELECT
         a.*
        ,CAST(l.real_amount AS DOUBLE)                        AS real_amount   -- 实际放款金额
        ,CAST(l.apply_amount AS DOUBLE)                       AS apply_amount  -- 申请金额
        ,CAST(l.interest AS DOUBLE)                           AS interest      -- 利息
        ,CAST(l.service_fee AS DOUBLE)                        AS service_fee   -- 服务费
        ,CAST(l.term_quantity AS INT)                         AS term_quantity -- 期限数量（配合 term_unit 使用）
        ,l.term_unit                                          -- 期限单位（取值以源表为准）
        ,l.total_period                                       -- 总期数
        ,CAST(l.is_deal AS INT)                               AS is_deal       -- 是否成交：1/0
        ,CAST(l.withdraw_time AS TIMESTAMP)                   AS withdraw_time -- 提现时间
        ,CAST(l.list_due_date AS DATE)                        AS list_due_date -- 放款单上的应还日
        ,s.listing_id                                         AS debt_listing_id -- 观察日快照中是否存在该借据：有值才说明有债务记录
        ,s.init_due_date                                      -- 首期应还日（来自观察日快照）
        ,CASE WHEN s.init_due_date IS NOT NULL THEN DATE_ADD(s.init_due_date, 31) END AS label_obs_dt
        -- 上一行：标签观察点 = 首期应还日 + 31 天。
        -- 比 30 天窗口多 1 天，确保 FPD30 窗口已经完整走完；没有首期应还日时为 NULL。
        ,s.first_repay_time
        ,s.user_actual_repay_time
        ,s.debt_status
        ,s.debt_status_desc
        ,s.hist_overdue_days
        ,s.current_overdue_days
        ,CASE WHEN a.is_disburse_success = 1
              THEN COALESCE(NULLIF(CAST(l.real_amount AS DOUBLE), 0), s.principal) END AS principal
        -- 上一行：本金口径 = 放款金额；若放款金额为 0 或 NULL，退回债务快照的本金合计；未放款为 NULL
        ,s.repay_amount
        ,s.owing_amount
        ,p.obs_dt
        ,CASE WHEN a.is_disburse_success = 1 AND CAST(l.is_deal AS INT) = 1 AND s.listing_id IS NOT NULL
               AND DATE_ADD(s.init_due_date, 31) BETWEEN TO_DATE(a.disburse_time) AND p.obs_dt
              THEN 1 ELSE 0 END                               AS is_label_matured
        -- 上一行：标签是否成熟（能否计算 FPD / 逾期标签）。四个条件同时满足才为 1：
        --   放款成功 + 已成交（is_deal = 1）+ 观察日有债务记录 + 首期应还日+31 落在 [放款日, 观察日] 之间
    FROM loan_apply a
    CROSS JOIN model.tmp_eliam_wagego_param_obs_date p
    LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
      ON a.listing_id = l.listing_id
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON a.listing_id = s.listing_id
     AND s.stat_date = p.obs_dt
),
base AS (
    -- 再取一批债务快照 x：日期 = label_obs_dt（首期应还日 + 31 天）。
    -- 这批字段描述“标签观察点当天”的状态，统一加 label_ 前缀，避免与观察日 obs_dt 的字段混淆。
    -- 注意：如果 label_obs_dt 当天恰好没有快照，label_* 字段会是 NULL，
    --      但 is_label_matured 仍可能为 1（成熟条件只看日期区间，不要求快照存在）。
    SELECT
         l.*
        ,x.first_repay_time                                   AS label_first_repay_time
        ,x.user_actual_repay_time                             AS label_user_actual_repay_time
        ,x.debt_status                                        AS label_debt_status
        ,x.hist_overdue_days                                  AS label_hist_overdue_days
        ,x.current_overdue_days                               AS label_current_overdue_days
        ,x.owing_amount                                       AS label_owing_amount
        ,CASE WHEN l.is_label_matured = 1 THEN x.current_overdue_days END AS label_dpd
        -- 上一行：标签时点的当前逾期天数；标签未成熟为 NULL
        ,CASE WHEN l.is_label_matured = 1 THEN x.hist_overdue_days END    AS label_hist_dpd
        -- 上一行：标签时点的历史最大逾期天数；标签未成熟为 NULL

        ,COALESCE(
             TO_DATE(x.first_repay_time)
            ,CASE WHEN l.first_repay_time IS NOT NULL AND TO_DATE(l.first_repay_time) <= l.label_obs_dt
                  THEN TO_DATE(l.first_repay_time) END
            ,l.label_obs_dt
         )                                                    AS label_obs_day
        -- 上一行：FPD 的“观察日”，按优先级取：
        --   ① 标签时点快照里第 1 期的实际还款日；
        --   ② 观察日快照里第 1 期的实际还款日（仅当它不晚于 label_obs_dt）；
        --   ③ label_obs_dt 本身（仍未还时，用窗口终点代表“一直没还”）。
        -- 这样未还款的记录会被记成 due+31，在所有 FPD 窗口上都会被判为逾期。
    FROM latest l
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp x
      ON l.listing_id = x.listing_id
     AND x.stat_date = l.label_obs_dt
),
mob_obs AS (
    -- 为每笔“放款成功”的借据生成 MOB 观察点：
    --   MOB n 的观察日 = 放款日所在月之后第 n 个月的月末，即 LAST_DAY(ADD_MONTHS(放款日, n))。
    --   例：MOB0 = 放款当月月末，MOB1 = 次月月末，依此类推。
    --   只保留观察日已经到来的 MOB 点（mob_obs_dt <= obs_dt），还没到的 MOB 不生成。
    SELECT
         b.loan_no
        ,b.listing_id
        ,TO_DATE(b.disburse_time)                             AS disburse_date -- 放款日期
        ,m.mob_no                                                              -- MOB 序号 0~4
        ,LAST_DAY(ADD_MONTHS(TO_DATE(b.disburse_time), m.mob_no)) AS mob_obs_dt -- 该 MOB 的观察日（月末）
    FROM base b
    CROSS JOIN (SELECT EXPLODE(SEQUENCE(0, 4)) AS mob_no) m   -- 生成 0,1,2,3,4 五个 MOB 序号
    WHERE b.is_disburse_success = 1
      AND LAST_DAY(ADD_MONTHS(TO_DATE(b.disburse_time), m.mob_no)) <= b.obs_dt
),
mob_detail AS (
    -- 取每个 MOB 观察日当天的债务快照，判断该时点是否逾期。
    -- 说明：没匹配到快照时四个标记都是 NULL（不是 0），表示“没观察到”，而不是“没逾期”。
    SELECT
         o.loan_no
        ,o.mob_no
        ,CASE WHEN d.current_overdue_days IS NOT NULL
              THEN CASE WHEN d.current_overdue_days >= 5  THEN 1 ELSE 0 END END AS is_5plus
        -- 上一行：该时点当前逾期 >= 5 天
        ,CASE WHEN d.current_overdue_days IS NOT NULL
              THEN CASE WHEN d.current_overdue_days > 30 THEN 1 ELSE 0 END END AS is_30plus
        -- 上一行：该时点当前逾期 > 30 天（即 >= 31 天）
        ,CASE WHEN d.hist_overdue_days IS NOT NULL
              THEN CASE WHEN d.hist_overdue_days >= 5  THEN 1 ELSE 0 END END AS is_ever_5plus
        -- 上一行：截至该时点，历史上是否出现过 >= 5 天逾期
        ,CASE WHEN d.hist_overdue_days IS NOT NULL
              THEN CASE WHEN d.hist_overdue_days > 30 THEN 1 ELSE 0 END END AS is_ever_30plus
        -- 上一行：截至该时点，历史上是否出现过 > 30 天逾期
    FROM mob_obs o
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp d
      ON o.listing_id = d.listing_id
     AND o.mob_obs_dt = d.stat_date
),
mob_wide AS (
    -- 把 MOB1~MOB3 的 4 个逾期标记从“长表”透成“宽表”（一行一笔借据）。
    -- 注意：这里只透视 MOB1~MOB3；MOB0 和 MOB4 不输出这类标记。
    -- 命名里的 cnt 实际是 0/1 标记，不是计数。
    SELECT
         loan_no
        ,MAX(CASE WHEN mob_no = 1  THEN is_5plus END) AS y_mob1_5plus_cnt      -- MOB1 月末：当前逾期 >= 5 天
        ,MAX(CASE WHEN mob_no = 1  THEN is_ever_5plus END) AS y_mob1_ever_5plus_cnt -- MOB1 月末：历史曾 >= 5 天
        ,MAX(CASE WHEN mob_no = 2  THEN is_5plus END) AS y_mob2_5plus_cnt      -- MOB2 月末：当前逾期 >= 5 天
        ,MAX(CASE WHEN mob_no = 2  THEN is_ever_5plus END) AS y_mob2_ever_5plus_cnt -- MOB2 月末：历史曾 >= 5 天
        ,MAX(CASE WHEN mob_no = 3  THEN is_5plus END) AS y_mob3_5plus_cnt      -- MOB3 月末：当前逾期 >= 5 天
        ,MAX(CASE WHEN mob_no = 3  THEN is_ever_5plus END) AS y_mob3_ever_5plus_cnt -- MOB3 月末：历史曾 >= 5 天
        ,MAX(CASE WHEN mob_no = 1  THEN is_30plus END) AS y_mob1_30plus_cnt    -- MOB1 月末：当前逾期 > 30 天
        ,MAX(CASE WHEN mob_no = 1  THEN is_ever_30plus END) AS y_mob1_ever_30plus_cnt -- MOB1 月末：历史曾 > 30 天
        ,MAX(CASE WHEN mob_no = 2  THEN is_30plus END) AS y_mob2_30plus_cnt    -- MOB2 月末：当前逾期 > 30 天
        ,MAX(CASE WHEN mob_no = 2  THEN is_ever_30plus END) AS y_mob2_ever_30plus_cnt -- MOB2 月末：历史曾 > 30 天
        ,MAX(CASE WHEN mob_no = 3  THEN is_30plus END) AS y_mob3_30plus_cnt    -- MOB3 月末：当前逾期 > 30 天
        ,MAX(CASE WHEN mob_no = 3  THEN is_ever_30plus END) AS y_mob3_ever_30plus_cnt -- MOB3 月末：历史曾 > 30 天
    FROM mob_detail
    GROUP BY loan_no
),

mob_track AS (
    -- 为每个 MOB 观察点找一条“最接近”的债务快照，用来估算该时点的剩余本金和 DPD：
    --   1) 优先取观察日当天或之前最近的快照（日期差越小越优先）；
    --   2) 如果之前没有任何快照，才退而取观察日之后最近的一条；
    --   3) MOB0 允许往后多看 7 天（月初数据可能延迟），其它 MOB 不允许。
    SELECT
         t.loan_no
        ,t.mob_no
        ,GREATEST(COALESCE(t.owing_principal, 0), 0) AS estimate_principal_remaining
        -- 上一行：该时点剩余未还本金（估算值）；负数按 0 处理
        ,COALESCE(t.current_overdue_days, 0)         AS dpd_days      -- 该时点当前逾期天数，NULL 记 0
        ,COALESCE(t.hist_overdue_days, 0)            AS dpd_days_ever -- 该时点历史最大逾期天数，NULL 记 0
    FROM (
        SELECT
             o.loan_no
            ,o.mob_no
            ,d.owing_principal
            ,d.current_overdue_days
            ,d.hist_overdue_days
            ,ROW_NUMBER() OVER (
                 PARTITION BY o.loan_no, o.mob_no
                 ORDER BY CASE WHEN d.stat_date <= o.mob_obs_dt THEN 0 ELSE 1 END  -- 观察日当天或之前的快照优先
                         ,CASE WHEN d.stat_date <= o.mob_obs_dt THEN DATEDIFF(o.mob_obs_dt, d.stat_date)
                               ELSE DATEDIFF(d.stat_date, o.mob_obs_dt) END      -- 距离观察日越近越优先
             ) AS rn
        FROM mob_obs o
        JOIN model.tmp_eliam_wagego_stg_debt_snp d
          ON o.listing_id = d.listing_id
         AND d.stat_date >= o.disburse_date       -- 只看放款之后的快照
         AND d.stat_date <= DATE_ADD(o.mob_obs_dt, CASE WHEN o.mob_no = 0 THEN 7 ELSE 0 END) -- MOB0 允许 +7 天
    ) t
    WHERE t.rn = 1
),
mob_track_wide AS (
    -- 把 MOB0~MOB4 的三个指标（剩余本金、当前 DPD、历史 DPD）透成宽表。
    SELECT
         loan_no
        ,MAX(CASE WHEN mob_no = 0 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob0 -- MOB0 剩余未还本金
        ,MAX(CASE WHEN mob_no = 0 THEN dpd_days END)                     AS dpd_days_mob0                     -- MOB0 当前逾期天数
        ,MAX(CASE WHEN mob_no = 0 THEN dpd_days_ever END)                AS dpd_days_ever_mob0                -- MOB0 历史最大逾期天数
        ,MAX(CASE WHEN mob_no = 1 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob1 -- MOB1 剩余未还本金
        ,MAX(CASE WHEN mob_no = 1 THEN dpd_days END)                     AS dpd_days_mob1                     -- MOB1 当前逾期天数
        ,MAX(CASE WHEN mob_no = 1 THEN dpd_days_ever END)                AS dpd_days_ever_mob1                -- MOB1 历史最大逾期天数
        ,MAX(CASE WHEN mob_no = 2 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob2 -- MOB2 剩余未还本金
        ,MAX(CASE WHEN mob_no = 2 THEN dpd_days END)                     AS dpd_days_mob2                     -- MOB2 当前逾期天数
        ,MAX(CASE WHEN mob_no = 2 THEN dpd_days_ever END)                AS dpd_days_ever_mob2                -- MOB2 历史最大逾期天数
        ,MAX(CASE WHEN mob_no = 3 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob3 -- MOB3 剩余未还本金
        ,MAX(CASE WHEN mob_no = 3 THEN dpd_days END)                     AS dpd_days_mob3                     -- MOB3 当前逾期天数
        ,MAX(CASE WHEN mob_no = 3 THEN dpd_days_ever END)                AS dpd_days_ever_mob3                -- MOB3 历史最大逾期天数
        ,MAX(CASE WHEN mob_no = 4 THEN estimate_principal_remaining END) AS estimate_principal_remaining_mob4 -- MOB4 剩余未还本金
        ,MAX(CASE WHEN mob_no = 4 THEN dpd_days END)                     AS dpd_days_mob4                     -- MOB4 当前逾期天数
        ,MAX(CASE WHEN mob_no = 4 THEN dpd_days_ever END)                AS dpd_days_ever_mob4                -- MOB4 历史最大逾期天数
    FROM mob_track
    GROUP BY loan_no
)
-- ============================================================================
-- 最终输出：一行 = 一条有效申请（loan_no）。
-- 字段按“基本信息 → 观察日状态 → 标签时点状态 → Y 标签 → 维度/衍生字段”排列。
-- 说明：所有 CASE 里只要条件字段为 NULL，结果就是 NULL，
--      因此“NULL”表示无法计算或没有观察到，和 0（明确未发生）不是一回事。
-- ============================================================================
SELECT
     b.loan_no                                              -- 借据号：一行一笔申请/借据
    ,b.user_id                                              -- 用户 ID
    ,b.application_id                                       -- 风控事件里的申请 ID（无对应事件为 NULL）
    ,b.app_id                                               -- 风控事件参数中的 appId（无对应事件为 NULL）
    ,b.listing_id                                           -- 放款单号
    ,b.apply_status                                         -- 申请状态原始英文值
    ,b.apply_status_desc                                    -- 申请状态中文说明
    ,b.is_disburse_success                                  -- 是否放款成功：1/0
    ,b.is_reject                                            -- 是否审核拒绝：1/0
    ,b.is_expired                                           -- 是否已过期：1/0
    ,b.is_disburse_failed                                   -- 是否放款失败：1/0
    ,b.apply_time                                           -- 申请时间
    ,b.apply_date                                           -- 申请日期
    ,b.apply_month                                          -- 申请月份（yyyy-MM）
    ,b.disburse_time                                        -- 放款时间（仅放款成功有值）
    ,b.apply_seq                                            -- 用户内申请序号：1 = 第一次申请（含未放款申请）
    ,b.application_rank                                     -- 用户内放款成功排名：1 = 首笔放款成功（仅放款成功有值）
    ,b.strategy_time                                        -- 风控事件时间
    ,b.retry_count                                          -- 风控事件重试次数
    ,b.stamp_time                                           -- 申请前最近一次 stamp 事件时间
    ,b.stamp_flow_id                                        -- 该 stamp 事件的流程号
    ,b.real_amount                                          -- 实际放款金额（来自放款主表）
    ,b.apply_amount                                         -- 申请金额
    ,b.interest                                             -- 利息
    ,b.service_fee                                          -- 服务费
    ,b.term_quantity                                        -- 期限数量
    ,b.term_unit                                            -- 期限单位
    ,b.total_period                                         -- 总期数
    ,b.is_deal                                              -- 是否成交：1/0
    ,b.withdraw_time                                        -- 提现时间
    ,b.list_due_date                                        -- 放款单上的应还日
    ,b.init_due_date                                        -- 首期应还日（观察日快照中的最早应还日）
    ,b.user_actual_repay_time                               -- 结清时间：所有期都结清时才有值
    ,b.debt_status                                          -- 观察日（obs_dt）借据状态码
    ,b.debt_status_desc                                     -- 观察日借据状态中文
    ,b.hist_overdue_days                                    -- 观察日历史最大逾期天数
    ,b.current_overdue_days                                 -- 观察日当前逾期天数
    ,b.principal                                            -- 本金口径：放款金额，缺失时用债务本金合计
    ,b.repay_amount                                         -- 观察日已还金额合计
    ,b.owing_amount                                         -- 观察日未还金额合计
    ,b.obs_dt                                               -- 全局观察日（所有行的同一个“当前日期”）
    ,b.label_obs_dt                                         -- 标签观察点：首期应还日 + 31 天
    ,b.is_label_matured                                     -- 标签是否成熟：1/0
    ,b.label_user_actual_repay_time                         -- 标签时点的结清时间
    ,b.label_debt_status                                    -- 标签时点的借据状态码
    ,b.label_current_overdue_days                           -- 标签时点的当前逾期天数
    ,b.label_hist_overdue_days                              -- 标签时点的历史最大逾期天数
    ,b.label_owing_amount                                   -- 标签时点的未还金额
    ,b.label_dpd                                           AS y_due_dpd        -- 标签时点的当前 DPD（未成熟为 NULL）
    ,b.label_hist_dpd                                      AS y_due_ever_dpd   -- 标签时点的历史最大 DPD（未成熟为 NULL）
    -- ---- due 组：首期应还日 + 31 天（label_obs_dt）这一时点的表现 ----
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd > 0 THEN 1 ELSE 0 END END AS y_due_ovd_cnt
    -- 上一行：标签时点是否逾期（DPD > 0）：1/0；无法计算为 NULL
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd > 0 THEN b.real_amount ELSE 0 END END AS y_due_ovd_amt
    -- 上一行：标签时点逾期金额：逾期则记放款金额，否则 0（注意未使用 label_owing_amount）
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd >= 5 THEN 1 ELSE 0 END END AS y_due_5plus_cnt
    -- 上一行：标签时点是否逾期 >= 5 天
    ,CASE WHEN b.label_dpd IS NOT NULL THEN CASE WHEN b.label_dpd > 30 THEN 1 ELSE 0 END END AS y_due_30plus_cnt
    -- 上一行：标签时点是否逾期 > 30 天（即 >= 31 天）
    ,CASE WHEN b.label_hist_dpd IS NOT NULL THEN CASE WHEN b.label_hist_dpd > 0 THEN 1 ELSE 0 END END AS y_due_ever_ovd_cnt
    -- 上一行：截至标签时点，历史上是否出现过逾期
    ,CASE WHEN b.label_hist_dpd IS NOT NULL THEN CASE WHEN b.label_hist_dpd > 0 THEN b.real_amount ELSE 0 END END AS y_due_ever_ovd_amt
    -- 上一行：截至标签时点曾逾期时的金额（曾逾期则记放款金额）
    ,CASE WHEN b.label_hist_dpd IS NOT NULL THEN CASE WHEN b.label_hist_dpd >= 5 THEN 1 ELSE 0 END END AS y_due_ever_5plus_cnt
    -- 上一行：截至标签时点，历史最大逾期是否 >= 5 天
    ,CASE WHEN b.label_hist_dpd IS NOT NULL THEN CASE WHEN b.label_hist_dpd > 30 THEN 1 ELSE 0 END END AS y_due_ever_30plus_cnt
    -- 上一行：截至标签时点，历史最大逾期是否 > 30 天

    -- ---- FPD 组：首期实际还款日（label_obs_day）是否晚于应还日 + N 天 ----
    -- 未还款时 label_obs_day 被兜底为应还日 + 31，因此必然晚于所有阈值，记为逾期。
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 3) THEN 1 ELSE 0 END END AS y_fpd3_ovd_cnt
    -- 上一行：FPD3 —— 首期还款是否晚于应还日 + 3 天
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 7) THEN 1 ELSE 0 END END AS y_fpd7_ovd_cnt
    -- 上一行：FPD7 —— 阈值改为应还日 + 7 天
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 14) THEN 1 ELSE 0 END END AS y_fpd14_ovd_cnt
    -- 上一行：FPD14 —— 阈值改为应还日 + 14 天
    ,CASE WHEN b.is_label_matured = 1 THEN CASE WHEN b.label_obs_day > DATE_ADD(b.init_due_date, 30) THEN 1 ELSE 0 END END AS y_fpd30_ovd_cnt
    -- 上一行：FPD30 —— 阈值改为应还日 + 30 天

    -- ---- 期限与提前结清 ----
    ,CASE WHEN b.debt_listing_id IS NOT NULL THEN DATEDIFF(b.init_due_date, TO_DATE(b.disburse_time)) END AS loan_term_contract_days
    -- 上一行：合同期限天数 = 首期应还日 - 放款日；没有债务记录时为 NULL
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN DATEDIFF(TO_DATE(b.user_actual_repay_time), TO_DATE(b.disburse_time)) END AS loan_term_actual_days
    -- 上一行：实际结清天数 = 结清时间 - 放款日；未结清为 NULL
    ,CASE WHEN b.user_actual_repay_time IS NOT NULL THEN CASE WHEN TO_DATE(b.user_actual_repay_time) < b.init_due_date THEN 1 ELSE 0 END END AS is_early_settlement
    -- 上一行：是否提前结清：结清日期早于首期应还日

    -- ---- obs 组：观察日 obs_dt 当天的表现（仅已成交借据） ----
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN 1 ELSE 0 END END AS y_obs_ovd_cnt
    -- 上一行：观察日当天是否逾期
    ,CASE WHEN b.is_deal = 1 AND b.current_overdue_days IS NOT NULL THEN CASE WHEN b.current_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS y_obs_ovd_amt
    -- 上一行：观察日逾期金额（逾期则记放款金额）
    ,CASE WHEN b.is_deal = 1 AND b.hist_overdue_days IS NOT NULL THEN CASE WHEN b.hist_overdue_days > 0 THEN 1 ELSE 0 END END AS y_obs_ever_ovd_cnt
    -- 上一行：截至观察日是否曾经逾期
    ,CASE WHEN b.is_deal = 1 AND b.hist_overdue_days IS NOT NULL THEN CASE WHEN b.hist_overdue_days > 0 THEN b.real_amount ELSE 0 END END AS y_obs_ever_ovd_amt
    -- 上一行：截至观察日曾逾期时的金额（曾逾期则记放款金额）
    -- ---- 维度 / 衍生字段 ----
    ,DATE_FORMAT(b.disburse_time, 'yyyy-MM')                 AS disburse_month -- 放款月份（yyyy-MM）
    ,DATEDIFF(b.obs_dt, TO_DATE(b.disburse_time))            AS days_on_book   -- 账龄天数 = 观察日 - 放款日
    ,CASE WHEN b.application_rank = 1 THEN 'New' WHEN b.application_rank IS NOT NULL THEN 'Old' END AS user_type
    -- 上一行：新老客：首笔“放款成功” = New，其余放款成功 = Old；从未放款成功为 NULL

    -- ---- MOB 逾期标记（MOB1~MOB3，均为 0/1；NULL 表示该 MOB 点没观察到数据） ----
    ,m.y_mob1_5plus_cnt                                     -- MOB1 月末当天逾期 >= 5 天
    ,m.y_mob1_ever_5plus_cnt                                -- 截至 MOB1 月末，历史曾逾期 >= 5 天
    ,m.y_mob2_5plus_cnt                                     -- MOB2 月末当天逾期 >= 5 天
    ,m.y_mob2_ever_5plus_cnt                                -- 截至 MOB2 月末，历史曾逾期 >= 5 天
    ,m.y_mob3_5plus_cnt                                     -- MOB3 月末当天逾期 >= 5 天
    ,m.y_mob3_ever_5plus_cnt                                -- 截至 MOB3 月末，历史曾逾期 >= 5 天
    ,m.y_mob1_30plus_cnt                                    -- MOB1 月末当天逾期 > 30 天
    ,m.y_mob1_ever_30plus_cnt                               -- 截至 MOB1 月末，历史曾逾期 > 30 天
    ,m.y_mob2_30plus_cnt                                    -- MOB2 月末当天逾期 > 30 天
    ,m.y_mob2_ever_30plus_cnt                               -- 截至 MOB2 月末，历史曾逾期 > 30 天
    ,m.y_mob3_30plus_cnt                                    -- MOB3 月末当天逾期 > 30 天
    ,m.y_mob3_ever_30plus_cnt                               -- 截至 MOB3 月末，历史曾逾期 > 30 天

    -- ---- MOB 时点指标（MOB0~MOB4；取距离该 MOB 月末最近的一条快照） ----
    -- 完全没匹配到快照时，对应字段为 NULL；匹配到快照但 DPD 为 NULL 时按 0 处理。
    ,t.estimate_principal_remaining_mob0                    -- MOB0 剩余未还本金
    ,t.dpd_days_mob0                                        -- MOB0 当前逾期天数
    ,t.dpd_days_ever_mob0                                   -- MOB0 历史最大逾期天数
    ,t.estimate_principal_remaining_mob1                    -- MOB1 剩余未还本金
    ,t.dpd_days_mob1                                        -- MOB1 当前逾期天数
    ,t.dpd_days_ever_mob1                                   -- MOB1 历史最大逾期天数
    ,t.estimate_principal_remaining_mob2                    -- MOB2 剩余未还本金
    ,t.dpd_days_mob2                                        -- MOB2 当前逾期天数
    ,t.dpd_days_ever_mob2                                   -- MOB2 历史最大逾期天数
    ,t.estimate_principal_remaining_mob3                    -- MOB3 剩余未还本金
    ,t.dpd_days_mob3                                        -- MOB3 当前逾期天数
    ,t.dpd_days_ever_mob3                                   -- MOB3 历史最大逾期天数
    ,t.estimate_principal_remaining_mob4                    -- MOB4 剩余未还本金
    ,t.dpd_days_mob4                                        -- MOB4 当前逾期天数
    ,t.dpd_days_ever_mob4                                   -- MOB4 历史最大逾期天数
FROM base b
LEFT JOIN mob_wide m
  ON b.loan_no = m.loan_no
LEFT JOIN mob_track_wide t
  ON b.loan_no = t.loan_no
;
