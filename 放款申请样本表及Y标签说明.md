# 放款申请样本表及Y标签：一个真实用户从头走到尾

- 数据：`原始数据/`（2026-10-22 取数）
- SQL：`放款申请样本表及Y标签.sql`
- 例子：user_id = 1000300，loan_no = LN00000182，listing_id = 111，100 元，1W

## 0. 先看结果

**目的：** 先知道最终一行长什么样，再回头看它是怎么一步步拼出来的。

最终表 `model.tmp_eliam_wagego_dwd_loan_apply_label` 一行 = 一条贷款申请。LN00000182 这一行：

| 字段 | 值 |
|---|---|
| loan_no / user_id / listing_id | LN00000182 / 1000300 / 111 |
| apply_status | DISBURSE_SUCCESS |
| disburse_time | 2026-08-30 08:12:14 |
| real_amount / term | 100 元 / 1W |
| init_due_date | 2026-09-04 |
| label_obs_dt / obs_dt | 2026-10-05 / 2026-10-22 |
| is_label_matured | 1 |
| y_fpd3 / 7 / 14 / 30 | 1 / 0 / 0 / 0 |
| y_due_ovd_cnt / y_due_ever_ovd_cnt | 0 / 1（DPD 0 / 5） |
| y_due_5plus_cnt / y_due_ever_5plus_cnt | 0 / 1 |
| y_obs_ovd_cnt / y_obs_ever_ovd_cnt | 0 / 1 |
| y_mob1_5plus_cnt / y_mob1_ever_5plus_cnt | 0 / 1 |
| days_on_book / 实际借款天数 | 53 / 10（合同 5 天） |
| user_type | Old |

本批数据里，标签成熟的借据有 2,335 笔；下面只看 LN00000182。

## 1. 原始数据

**目的：** 先看清五张源表各自是什么粒度、哪些字段会被用到，后面的每一步都从这里取数。

### 01 申请：`ods_ewa.aus_ewa_loan_biz_t_loan_application`

| loan_no | user_id | listing_id | status | inserttime | apply_disburse_time |
|---|---|---|---|---|---|
| LN00000181 | 1000300 | 110 | DISBURSE_SUCCESS | 2026-08-30 07:59:21 | 2026-08-30 08:04:40 |
| LN00000182 | 1000300 | 111 | DISBURSE_SUCCESS | 2026-08-30 08:11:51 | 2026-08-30 08:12:14 |
| LN00008761 | 1000300 | NULL | AUDIT_REJECTED | 2026-09-25 06:03:53 | NULL |

同一天先放了 LN00000181，再放 LN00000182。按放款成功顺序排名，LN00000181 是 New，LN00000182 是 Old。

### 02 放款：`edw_ewa.dwb_asset_cmn_listing`

| listing_id | real_amount | term_quantity | term_unit | total_period | is_deal | withdraw_time | list_due_date |
|---|---|---|---|---|---|---|---|
| 110 | 100.00 | 1 | W | 1W | 1 | 2026-08-30 08:06:04 | 2026-09-04 |
| 111 | 100.00 | 1 | W | 1W | 1 | 2026-08-30 08:14:04 | 2026-09-04 |

LN00000182 对应 listing 111，`is_deal = 1`，合同应还日 2026-09-04。

### 03 债务快照：`edw_ewa.dwb_asset_debt_dtl_snp`

listing 111 的关键快照日：

| dt | init_due_date | period_no | user_actual_repay_time | debt_status | hist_overdue_days | current_overdue_days | owing_amount |
|---|---|---|---|---|---|---|---|
| 2026-08-31 | 2026-09-04 | 1 | NULL | 1 | 0 | 0 | 105.32 |
| 2026-09-04 | 2026-09-04 | 1 | NULL | 1 | 0 | 0 | 105.32 |
| 2026-09-09 | 2026-09-04 | 1 | NULL | 4 | 5 | 5 | 105.62 |
| 2026-09-10 | 2026-09-04 | 1 | 2026-09-09 18:40:19 | 2 | 5 | 0 | 0.00 |
| 2026-09-30 | 2026-09-04 | 1 | 2026-09-09 18:40:19 | 2 | 5 | 0 | 0.00 |
| 2026-10-05 | 2026-09-04 | 1 | 2026-09-09 18:40:19 | 2 | 5 | 0 | 0.00 |
| 2026-10-22 | 2026-09-04 | 1 | 2026-09-09 18:40:19 | 2 | 5 | 0 | 0.00 |

`debt_status`：1 未结清、2 已结清、4 逾期中。09-09 晚上 18:40:19 还款，09-10 的快照才变成已结清；快照是每天一个时点。

### 04 / 05 辅助表

| 表 | 用来做什么 | 本例的值 |
|---|---|---|
| `ods_ewa.aus_ewa_risk_risk_event_task` | `biz_id = 20050` 取策略时间 | `strategy_time = 2026-08-30 08:11:52` |
| `ods_ewa.aus_listing_tb_loan_limit_apply` | `biz_type = 400` 取戳额时间 | `stamp_time = 2026-08-30 07:42:16` |

这两张表只补事件/戳额字段（`application_id`、`app_id`、`retry_count`、`strategy_time`、`stamp_time`），不参与 Y 标签计算。04 里还有一条 `biz_id = 10000` 的同一次戳额（07:42:17），优先级低于 05，所以取 05 的时间。

## 2. 第 1 步：obs_dt

**目的：** 给整批数据定一个统一的“今天”，存进 `model.tmp_eliam_wagego_param_obs_date`；后面所有“当前”指标都截止到这一天。

```sql
SELECT MAX(TO_DATE(dt)) AS obs_dt
FROM edw_ewa.dwb_asset_debt_dtl_snp
```

结果 `2026-10-22`。

## 3. 第 2 步：stg（借据 × 日期）

**目的：** 把 03 的每日快照压成“一笔借据一天一行”，存进 `model.tmp_eliam_wagego_stg_debt_snp`；后面想取哪一天的状态，直接查它就行。

本批数据 `period_no` 都是 1，所以 03 的“借据 × 期数 × 日期”和 stg 的“借据 × 日期”一一对应。listing 111 在 stg 里：

| stat_date | init_due_date | first_repay_time | debt_status_desc | current_dpd | hist_dpd | owing_amount |
|---|---|---|---|---|---|---|
| 2026-08-31 | 2026-09-04 | NULL | 未结清 | 0 | 0 | 105.32 |
| 2026-09-09 | 2026-09-04 | NULL | 逾期中 | 5 | 5 | 105.62 |
| 2026-09-10 | 2026-09-04 | 2026-09-09 18:40:19 | 已结清 | 0 | 5 | 0.00 |
| 2026-09-30 | 2026-09-04 | 2026-09-09 18:40:19 | 已结清 | 0 | 5 | 0.00 |
| 2026-10-22 | 2026-09-04 | 2026-09-09 18:40:19 | 已结清 | 0 | 5 | 0.00 |

字段变化：`dt → stat_date`、`current_overdue_days → current_dpd`、`hist_overdue_days → hist_dpd`，并补了 `first_repay_time` 和 `debt_status_desc`。

多期产品的合并规则（本批数据用不到，但 SQL 里保留了）：`init_due_date` 取 `MIN`；`first_repay_time` 只取第 1 期；`debt_status` 取最差（4 > 1 > 2）；DPD 取 `MAX`；金额求和。

## 4. 第 3 步：组装成一行

**目的：** 把申请、放款和两份快照拼成“一条申请一行”，存进 `model.tmp_eliam_wagego_dwd_loan_apply_label`，并算出算标签要用的日期和状态。

| 来源 | 本例取到的值 |
|---|---|
| 01 申请 | LN00000182，user 1000300，`DISBURSE_SUCCESS`，放款 2026-08-30 08:12:14 |
| 02 放款 | 100 元，1W，`is_deal = 1` |
| 03 观察日快照（2026-10-22） | `init_due_date = 2026-09-04`，当前 DPD 0，历史 DPD 5，欠款 0 |
| 03 标签日快照（2026-10-05） | 当前 DPD 0，历史 DPD 5，欠款 0，还款日 2026-09-09 |

四个关键日期：

| 字段 | 值 |
|---|---|
| `disburse_time` | 2026-08-30 08:12:14 |
| `init_due_date` | 2026-09-04 |
| `label_obs_dt` | 2026-10-05（= 2026-09-04 + 31） |
| `obs_dt` | 2026-10-22 |

为什么 +31：FPD30 的窗口是应还日 + 30 天，多留 1 天保证窗口完整。

`is_label_matured = 1`：放款成功、`is_deal = 1`、10-22 有快照、10-05 在 08-30 和 10-22 之间，四个条件都满足。若 `label_obs_dt > obs_dt`，标签未成熟，FPD/due 为 NULL。

New/Old：同一天的 LN00000181 是第 1 笔放款（New），LN00000182 是第 2 笔（Old）。

## 5. 算标签

**目的：** 用前面准备好的日期和状态，直接算出每个标签是 0、1 还是 NULL。

### FPD：看还款日

**目的：** 看这笔钱在应还后第 3/7/14/30 天之前有没有还上。

`label_obs_day` 取标签日快照里的还款日：2026-09-09（当天 18:40:19 还款）。如果标签日快照没有还款时间，会退到观察日快照，再用 `label_obs_dt` 兜底（一直没还的情况）。

| 标签 | 比较 | 值 |
|---|---|---|
| `y_fpd3_ovd_cnt` | 09-09 > 09-04 + 3 = 09-07 | 1 |
| `y_fpd7_ovd_cnt` | 09-09 > 09-11 | 0 |
| `y_fpd14_ovd_cnt` | 09-09 > 09-18 | 0 |
| `y_fpd30_ovd_cnt` | 09-09 > 10-04 | 0 |

### due / obs：看某一天的状态

**目的：** 看某一天是否还欠着：due 看标签日，obs 看观察日；每个时点再分“当天”和“曾经”。

| 标签 | 口径 | 值 |
|---|---|---|
| `y_due_ovd_cnt` | 10-05 当前 DPD > 0 | 0 |
| `y_due_ever_ovd_cnt` | 10-05 历史 DPD > 0 | 1 |
| `y_due_5plus_cnt` | 10-05 当前 DPD >= 5 | 0 |
| `y_due_ever_5plus_cnt` | 10-05 历史 DPD >= 5 | 1 |
| `y_due_30plus_cnt` | 10-05 当前 DPD > 30 | 0 |
| `y_due_ever_30plus_cnt` | 10-05 历史 DPD > 30 | 0 |
| `y_obs_ovd_cnt` | 10-22 当前 DPD > 0 | 0 |
| `y_obs_ever_ovd_cnt` | 10-22 历史 DPD > 0 | 1 |

10-05 已经还清（当前 DPD 0），但历史确实逾期过 5 天（历史 DPD 5），所以 `due = 0`、`due_ever = 1`。

### MOB：看每个月末

**目的：** 看放款后第 1/2/3 个月末的逾期情况。

MOB n 的观察日 = `LAST_DAY(ADD_MONTHS(放款日, n))`，只生成 `<= obs_dt` 的月份。

| MOB | 观察日 | 当前 DPD | 历史 DPD | 剩余本金 | 5plus | ever_5plus |
|---|---|---|---|---|---|---|
| MOB0 | 2026-08-31 | 0 | 0 | 100 | 0 | 0 |
| MOB1 | 2026-09-30 | 0 | 5 | 0 | 0 | 1 |
| MOB2 | 2026-10-31 | 晚于 obs_dt，不生成 | — | — | NULL | NULL |

`y_mob1_5plus_cnt = 0`（当天已还清），`y_mob1_ever_5plus_cnt = 1`（历史逾期 5 天）。MOB2/3 为 NULL，表示还没观察到，不是 0。

## 6. 记住这四点

**目的：** 把最容易混的四组概念一次分清。

1. **FPD 看还款日，due 看某一天的状态**：本例晚还 5 天，FPD3 = 1；但到 10-05 已还清，due = 0、due_ever = 1。
2. **current 和 ever 是两套口径**：MOB1 当天当前 DPD 0、历史 DPD 5，所以 5plus = 0、ever_5plus = 1。
3. **NULL 不是 0**：MOB2 的观察日 10-31 还没到，标签为 NULL；标签未成熟时 FPD/due 也是 NULL。
4. **New/Old 按放款成功排名**：同一天的 LN00000181 是第 1 笔（New），LN00000182 是第 2 笔（Old）；从未放款成功的申请为 NULL。
