# WageGo Vintage 全流程

> [现行vintage计算代码.sql](现行vintage计算代码.sql) 只能作参考，口径以本文档为准。

## 流程总览

| 步骤 | 产出表 | 粒度 | 内容 |
| ---- | ------ | ---- | ---- |
| 第零步 | `model.tmp_eliam_wagego_obs_date` | 一行 | 观察日 |
| 第一步 | `model.tmp_eliam_wagego_application` | 一次场景执行 | 申请事件主表 |
| 第二步 | `model.tmp_eliam_wagego_loan_apply` | 一个 `loan_no` | 借款申请表 |
| 第三步 | `model.tmp_eliam_wagego_loan_listing` | 一个 `loan_no` | 补放款金额、期限 |
| 第四步 | `model.tmp_eliam_wagego_loan_debt` | 一个 `loan_no` | 补应还、实还、逾期 |
| 第五步 | `model.tmp_eliam_wagego_vintage_loan` / `_vintage_month` | loan / 放款月 | 按放款月做 vintage |
| 第六步 | `model.tmp_eliam_wagego_vintage_loan_seg` / `_vintage_mob` / `_vintage_curve` | 分群 / loan×MOB / 分群×MOB | 新老客分群与滚动曲线 |

每日运行顺序：第零步 → 第一~三步 → 第四步 → 第五步 → 第六步。观察日自动取快照表最新分区，SQL 里不需要改日期。

## 第零步：观察日控制表（每日必跑）

**目标**：给第四~六步提供统一的观察日 `obs_dt`。

**口径**：

- `obs_dt = MAX(TO_DATE(dt))`，取 `edw_ewa.dwb_asset_debt_dtl_snp` 的最新分区
- 不用 `current_date()`：ETL 延迟时当天分区可能还没产出，取最新分区才能保证有数可看

**SQL**：

```sql
SET spark.sql.session.timeZone = Australia/Sydney;

DROP TABLE IF EXISTS model.tmp_eliam_wagego_obs_date;
CREATE TABLE model.tmp_eliam_wagego_obs_date AS
SELECT MAX(TO_DATE(dt)) AS obs_dt
FROM edw_ewa.dwb_asset_debt_dtl_snp
WHERE CAST(period_no AS INT) = 1;
```

## 第一步：申请事件主表

**目标**：一行 = 一次场景执行，`flow_id` 唯一。

**口径**：

- `biz_id = 20050` → `loan_apply`（借款申请），`flow_id` 即 `LN` 放款号
- `biz_id = 40000` → `cds_pull`（银行流水拉取，不是申请）
- 其余 → `credit_run`（授信跑额）
- `status`：`20` 成功，`-3` 失败，`10` 处理中

**SQL**：

```sql
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
```

## 第二步：借款申请表

**目标**：一行一个 `loan_no`，覆盖全部申请（成功、拒绝、过期、失败）。

**口径**：

- 底表用原始表 `ods_ewa.aus_ewa_loan_biz_t_loan_application`，只取 `isactive = 1`
- 必须用原始表做底表：27 笔 2026-09-20 的 `EXPIRED` 只在原始表，主表里没有
- 主表（第一步）只补 `app_id`、`retry_count`、`application_id`；`application_id` 仅展示，不参与关联
- 主表 `status = 20` 只代表策略执行成功，审批结果看原始表 `status`
- `apply_seq` = 用户内按申请时间排序的序号，`is_first_apply_in_window` 标记窗口内首笔

**SQL**：

```sql
SET spark.sql.session.timeZone = Australia/Sydney;

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
```

## 第三步：补放款金额、期限

**目标**：在第二步结果上补放款金额、成交标记、期限标签，行数不变。

**口径**：

- 底表第二步结果，`LEFT JOIN edw_ewa.dwb_asset_cmn_listing`，关联键 `listing_id`（该表 `listing_id` 唯一）
- `is_deal = 1` 才是成交放款；`is_deal = 0` 的 3 笔对应第二步的 `DISBURSE_FAILED`，金额保留，下游按 `is_deal` 过滤
- 期限只保留 `term_quantity`、`term_unit`、`total_period`。`term_quantity` 全为 1；`term_unit` 为 `W`/`F`/`M`，是周/双周/月发薪周期，实际合同天数要用第四步借据的 `init_due_date − 放款时间` 计算，**不能**按 7/14/30 折算
- 当天放款的记录在资产表可能尚未同步，保留 NULL，不丢行

**SQL**：

```sql
SET spark.sql.session.timeZone = Australia/Sydney;

DROP TABLE IF EXISTS model.tmp_eliam_wagego_loan_listing;
CREATE TABLE model.tmp_eliam_wagego_loan_listing AS
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
;
```

## 第四步：补应还、实还、逾期

**目标**：在第三步结果上补借据侧的应还日、实还时间、结清状态、逾期天数，行数不变。

**口径**：

- 底表第三步结果，`LEFT JOIN edw_ewa.dwb_asset_debt_dtl_snp`，关联键 `listing_id`
- 取最新快照 `dt = obs_dt`（第零步控制表）、`period_no = 1`（该表粒度 `listing_id × dt`，全部单期借据）
- `debt_status`：1 未结清、2 已结清、4 逾期中；失败放款在借据表也有一条已结清记录，下游按 `is_deal = 1` 过滤即可
- `current_overdue_days` 是快照当日逾期天数（时点口径）；`hist_overdue_days` 是历史累计逾期天数，但近 1–2 天刚结清的可能尚未回写，Vintage 不要只依赖它
- 合同期限 = `init_due_date − 放款日`，按发薪日对齐：W 0–7 天、F 0–14 天、M 0–32 天
- `loan_term_actual_days` = 实还日 − 放款日；`is_early_settlement` = 实还日早于应还日
- 观察日当天放款的记录可能尚未进快照，保留 NULL

**SQL**：

```sql
SET spark.sql.session.timeZone = Australia/Sydney;

DROP TABLE IF EXISTS model.tmp_eliam_wagego_loan_debt;
CREATE TABLE model.tmp_eliam_wagego_loan_debt AS
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
    ,CASE WHEN d.current_overdue_days IS NOT NULL
          THEN CASE WHEN CAST(d.current_overdue_days AS INT) > 0 THEN 1 ELSE 0 END END
                                         AS is_current_overdue
FROM model.tmp_eliam_wagego_loan_listing a
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
;
```

## 第五步：按放款月做 Vintage

**目标**：按放款月分群，输出放款后第 1/2 个自然月月末的 30+ 逾期，以及截至观察日的累计 30+ 逾期。产出 loan 级 `_vintage_loan` 和放款月汇总 `_vintage_month` 两张表。

**口径**：

- 分群 = `disburse_month`（放款月，实测与申请月完全一致）
- MOB1 / MOB2 观察点 = 放款月后第 1 / 2 个自然月月末；`dpd_mobN` 取该日快照的 `current_overdue_days`（时点口径）
- 30+ 逾期 = `current_overdue_days >= 30`
- `is_ever_30plus_to_date` = 最新快照 `hist_overdue_days >= 30`，即截至 `obs_dt` 曾达到 30+
- 分母 `obs_cnt` = 观察日有借据快照的放款数
- 未到 MOB 观察点的月份不能当完整 vintage 看；每行带 `data_as_of = obs_dt` 标识数据截止日

**SQL**：

```sql
SET spark.sql.session.timeZone = Australia/Sydney;

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
          THEN CASE WHEN m1.current_overdue_days >= 30 THEN 1 ELSE 0 END END AS is_mob1_30plus
    ,CASE WHEN m2.current_overdue_days IS NOT NULL
          THEN CASE WHEN m2.current_overdue_days >= 30 THEN 1 ELSE 0 END END AS is_mob2_30plus
    ,CASE WHEN cur.hist_overdue_days IS NOT NULL
          THEN CASE WHEN cur.hist_overdue_days >= 30 THEN 1 ELSE 0 END END   AS is_ever_30plus_to_date
FROM loan l
LEFT JOIN debt m1  ON l.listing_id = m1.listing_id  AND m1.dt  = l.mob1_dt
LEFT JOIN debt m2  ON l.listing_id = m2.listing_id  AND m2.dt  = l.mob2_dt
LEFT JOIN debt cur ON l.listing_id = cur.listing_id AND TO_DATE(cur.dt) = l.obs_dt
;

DROP TABLE IF EXISTS model.tmp_eliam_wagego_vintage_month;
CREATE TABLE model.tmp_eliam_wagego_vintage_month AS
SELECT
     disburse_month
    ,MAX(data_as_of)                                                             AS data_as_of
    ,COUNT(*)                                                                    AS loan_cnt
    ,ROUND(SUM(real_amount), 2)                                                  AS loan_amt
    ,SUM(CASE WHEN dpd_latest IS NOT NULL THEN 1 ELSE 0 END)                     AS obs_cnt
    ,ROUND(SUM(CASE WHEN dpd_latest IS NOT NULL THEN real_amount ELSE 0 END), 2) AS obs_amt
    ,SUM(CASE WHEN dpd_latest >= 30 THEN 1 ELSE 0 END)                           AS cur_30plus_cnt
    ,ROUND(SUM(CASE WHEN dpd_latest >= 30 THEN real_amount ELSE 0 END), 2)       AS cur_30plus_amt
    ,SUM(is_ever_30plus_to_date)                                                 AS ever_30plus_cnt
    ,ROUND(SUM(CASE WHEN is_ever_30plus_to_date = 1 THEN real_amount ELSE 0 END), 2) AS ever_30plus_amt
    ,ROUND(100.0 * SUM(is_ever_30plus_to_date)
           / NULLIF(SUM(CASE WHEN dpd_latest IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS ever_30plus_rate
    ,ROUND(100.0 * SUM(CASE WHEN is_ever_30plus_to_date = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(CASE WHEN dpd_latest IS NOT NULL THEN real_amount ELSE 0 END), 0), 2) AS ever_30plus_amt_rate
    ,SUM(CASE WHEN dpd_mob1 IS NOT NULL THEN 1 ELSE 0 END)                       AS mob1_obs_cnt
    ,SUM(is_mob1_30plus)                                                         AS mob1_30plus_cnt
    ,ROUND(100.0 * SUM(is_mob1_30plus)
           / NULLIF(SUM(CASE WHEN dpd_mob1 IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS mob1_30plus_rate
    ,SUM(CASE WHEN dpd_mob2 IS NOT NULL THEN 1 ELSE 0 END)                       AS mob2_obs_cnt
    ,SUM(is_mob2_30plus)                                                         AS mob2_30plus_cnt
    ,ROUND(100.0 * SUM(is_mob2_30plus)
           / NULLIF(SUM(CASE WHEN dpd_mob2 IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS mob2_30plus_rate
FROM model.tmp_eliam_wagego_vintage_loan
GROUP BY disburse_month
;
```

## 第六步：分群与滚动 Vintage 曲线

**目标**：在第五步结果上补新老客分群、显式成熟度标记、长表 MOB 曲线（1–12 个月、5+/30+ 双阈值）。产出 `_loan_seg`（分群）、`_mob`（长表）、`_curve`（分群 × MOB 汇总）三张表。

**口径**：

- `application_rank` = 用户内按 `disburse_time, loan_no` 排序的序号；`user_type`：序号 1 = New，其余 = Old
- New/Old 只基于本数据集：取数窗口前已有放款的老客会被误判为 New，分群结论要带这个前提
- `mob_no` = 1–12；观察点 = 放款日后第 `mob_no` 个自然月月末，与第五步 MOB 定义一致
- `is_matured` = 观察点 <= `data_as_of`；未到期的记录不给逾期标记，聚合自动排除
- `dpd` = 观察点当日快照的 `current_overdue_days`，只取月末分区
- `is_5plus` / `is_30plus` 仅在已到期且快照存在时取值
- 不借鉴 Fundo 的时点 DPD 算法（观察点前已结清一律记 0，会漏掉「曾 30+ 后结清」的笔）；累计口径仍以 `hist_overdue_days` 为准

### 6.1 新老客分群

```sql
SET spark.sql.session.timeZone = Australia/Sydney;

DROP TABLE IF EXISTS model.tmp_eliam_wagego_vintage_loan_seg;
CREATE TABLE model.tmp_eliam_wagego_vintage_loan_seg AS
WITH ranked AS (
    SELECT
         *
        ,ROW_NUMBER() OVER (
             PARTITION BY user_id
             ORDER BY disburse_time, loan_no
         ) AS application_rank
    FROM model.tmp_eliam_wagego_vintage_loan
)
SELECT
     *
    ,CASE WHEN application_rank = 1 THEN 'New' ELSE 'Old' END AS user_type
FROM ranked
;
```

### 6.2 长表 MOB

```sql
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
    FROM model.tmp_eliam_wagego_vintage_loan_seg s
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
          THEN CASE WHEN d.current_overdue_days >= 30 THEN 1 ELSE 0 END END AS is_30plus
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
```

### 6.3 分群 × MOB 曲线

```sql
DROP TABLE IF EXISTS model.tmp_eliam_wagego_vintage_curve;
CREATE TABLE model.tmp_eliam_wagego_vintage_curve AS
SELECT
     disburse_month
    ,user_type
    ,mob_no
    ,MAX(data_as_of)                                                                            AS data_as_of
    ,COUNT(*)                                                                                  AS cohort_cnt
    ,SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN 1 ELSE 0 END)                       AS obs_cnt
    ,SUM(is_5plus)                                                                             AS cnt_5plus
    ,ROUND(100.0 * SUM(is_5plus)
           / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS rate_5plus
    ,SUM(is_30plus)                                                                            AS cnt_30plus
    ,ROUND(100.0 * SUM(is_30plus)
           / NULLIF(SUM(CASE WHEN is_matured = 1 AND dpd IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS rate_30plus
FROM model.tmp_eliam_wagego_vintage_mob
GROUP BY disburse_month, user_type, mob_no
;
```
