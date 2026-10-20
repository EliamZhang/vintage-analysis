# WageGo Vintage 全流程（当前：第二步）

## 进度

- [x] 第一步：申请事件主表 `model.tmp_eliam_wagego_application`（181,477 行）
- [ ] 第二步：借款申请表 `model.tmp_eliam_wagego_loan_apply` ← 现在做
- [ ] 第三步：补放款金额、期限（等资产 / 放款标的表）
- [ ] 第四步：补应还、实还、逾期（等借据 / 债务快照表）
- [ ] 第五步：按放款月做 vintage

## 第一步：申请事件主表（已完成）

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

**验收**：

```sql
SELECT event_type,
       COUNT(*)                AS cnt,
       COUNT(DISTINCT flow_id) AS flow_cnt,
       SUM(is_success)         AS success_cnt
FROM model.tmp_eliam_wagego_application
GROUP BY event_type;
```

预期：`loan_apply` 33,478；`cds_pull` 38,363；`credit_run` 109,636；合计 181,477，`flow_id` 无重复。

## 第二步：借款申请表（当前）

**目标**：一行一个 `loan_no`，覆盖全部申请（成功、拒绝、过期、失败）。

**口径**：

- 底表用原始表 `ods_ewa.aus_ewa_loan_biz_t_loan_application`，只取 `isactive = 1`
- 主表 left join 只补 `app_id`、`retry_count`、`application_id`；`application_id` 仅展示，不参与关联
- 主表 `status = 20` 只代表策略执行成功，审批结果看原始表 `status`
- 27 笔 2026-09-20 的 `EXPIRED` 只在原始表，所以必须用原始表做底表

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

**验收**：

```sql
SELECT COUNT(*)                 AS apply_cnt,
       COUNT(DISTINCT loan_no)  AS loan_no_cnt,
       SUM(is_disburse_success) AS disburse_success_cnt,
       SUM(is_reject)           AS reject_cnt,
       SUM(is_expired)          AS expired_cnt,
       SUM(is_disburse_failed)  AS disburse_failed_cnt
FROM model.tmp_eliam_wagego_loan_apply;
```

预期：`apply_cnt = loan_no_cnt = 33,491`；`disburse_success_cnt = 25,549`；`reject_cnt = 5,517`；`expired_cnt = 2,280`；`disburse_failed_cnt = 137`。

**下一步**：先跑这一步。资产表和债务表下载后，再补金额、期限、应还/逾期。
