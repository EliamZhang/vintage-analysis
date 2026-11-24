SET spark.sql.session.timeZone = Australia/Sydney;

-- WageGo Vintage 分析：各 FPD 观察窗口的坏率与 cohort 路径
-- 数据源：model.tmp_eliam_wagego_dwd_loan_apply_label
-- 口径：
--   1) 每个窗口用各自成熟 cohort：y_fpdN_obs = 1（is_deal = 1、观察日有借据快照、due+N < obs_dt）
--   2) 坏 = 首期实还日（未还则取 obs_dt）晚于 due + X
--   3) FPD14 主表没有独立字段，用 model.tmp_eliam_wagego_stg_debt_snp 的首期实还日补算，成熟条件同口径
--   4) 金额坏率 = 坏样本 due+N 时点未还本金 / 全部成熟放款本金（real_amount）
--      FPD14 的余额取 due+14 当天借据快照（与主表 FPD 金额字段同机制）
--   5) 块 3 按 user_type 拆分；块 4 按放款周（周一开始）拆 vintage 路径，并输出 ALL / New / Old 三组
--      块 1/3/4 均包含 FPD1、FPD3、FPD7、FPD14、FPD15、FPD30；FPD1 作为最早预警信号
--   6) 块 5-6 模型分固定 5 箱：按新客风险 1.0 阈值切分，套到新老客和放款周
--   7) 块 7 按 application_rank 拆复借期数：1st / 2nd / 3rd / 4th+
--   8) 块 8-9 周度模型监控：排序力（AUC/Gini/KS）与周度新老客拆分；块 8 同样输出 ALL / New / Old
--   9) 块 10 月度排序力：按放款月 × 新老客（New / Old / ALL）
--  10) 块 11 新客戳额全量样本的线上模型分分布（全历史、不设时间窗）
--      样本口径同 wagego_02 的新客戳额样本：每个用户全历史第一次戳额申请
--      分数取戳额时点线上模型日志；11a 覆盖、11b 固定 10 档 × 戳额周（周一开始）
--  11) 块 12 新客出额样本转化漏斗（按戳额周）：出额审批通过率、借款申请审核通过率、成交率
--      出额样本 = 戳额生产打分全量用户；标签取 Y 标签主表，出额结果取出额转化明细表


-- ============================================================
-- 块 1：各窗口成熟样本、坏样本、笔数坏率、金额坏率
-- ============================================================
WITH win AS (
    SELECT
         1 AS window_days
        ,COUNT(*)                                                       AS obs_cnt
        ,SUM(t.y_fpd1_ovd)                                              AS bad_cnt
        ,SUM(t.real_amount)                                             AS total_amt
        ,SUM(CASE WHEN t.y_fpd1_ovd = 1 THEN t.estimate_principal_remaining_fpd1 ELSE 0 END) AS bad_amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd1_obs = 1
    UNION ALL
    SELECT
         3 AS window_days
        ,COUNT(*)                                                       AS obs_cnt
        ,SUM(t.y_fpd3_ovd)                                              AS bad_cnt
        ,SUM(t.real_amount)                                             AS total_amt
        ,SUM(CASE WHEN t.y_fpd3_ovd = 1 THEN t.estimate_principal_remaining_fpd3 ELSE 0 END) AS bad_amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd3_obs = 1
    UNION ALL
    SELECT
         7
        ,COUNT(*)
        ,SUM(t.y_fpd7_ovd)
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN t.y_fpd7_ovd = 1 THEN t.estimate_principal_remaining_fpd7 ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd7_obs = 1
    UNION ALL
    SELECT
         14
        ,COUNT(*)
        ,SUM(CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
                  THEN 1 ELSE 0 END)                                    AS bad_cnt
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
                  THEN CASE WHEN d14.listing_id IS NOT NULL
                            THEN GREATEST(COALESCE(d14.owing_principal, 0), 0) END
                  ELSE 0 END)                                           AS bad_amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.obs_dt
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp d14
      ON t.listing_id = d14.listing_id
     AND d14.stat_date = DATE_ADD(t.init_due_date, 14)
    WHERE t.is_deal = 1
      AND s.listing_id IS NOT NULL
      AND DATE_ADD(t.init_due_date, 14) < t.obs_dt
    UNION ALL
    SELECT
         15
        ,COUNT(*)
        ,SUM(t.y_fpd15_ovd)
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN t.y_fpd15_ovd = 1 THEN t.estimate_principal_remaining_fpd15 ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
    UNION ALL
    SELECT
         30
        ,COUNT(*)
        ,SUM(t.y_fpd30_ovd)
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN t.y_fpd30_ovd = 1 THEN t.estimate_principal_remaining_fpd30 ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd30_obs = 1
),
stat AS (
    SELECT
         window_days
        ,obs_cnt
        ,bad_cnt
        ,total_amt
        ,bad_amt
        ,CAST(bad_cnt AS DOUBLE) / obs_cnt                              AS bad_rate
        ,bad_amt / NULLIF(total_amt, 0)                                 AS bad_rate_amt
    FROM win
)
SELECT
     window_days
    ,obs_cnt
    ,bad_cnt
    ,ROUND(bad_rate * 100, 2)                                           AS bad_rate_pct
    ,ROUND(bad_rate_amt * 100, 2)                                       AS bad_rate_amt_pct
    ,ROUND((bad_rate - LAG(bad_rate) OVER (ORDER BY window_days)) * 100, 2) AS delta_pp
    ,ROUND(total_amt, 2)                                                AS total_amt
    ,ROUND(bad_amt, 2)                                                  AS bad_amt
FROM stat
ORDER BY window_days
;


-- ============================================================
-- 块 2：共同 cohort 上 FPD15 vs FPD30（due+30 < obs_dt，两个观察窗都完全成熟）
-- 观察窗稳健性检查：30 天窗口的坏率与坏样本保留率
-- ============================================================
WITH base AS (
    SELECT
         t.y_fpd15_ovd                                                 AS fpd15
        ,t.y_fpd30_ovd                                                 AS fpd30
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
      AND t.y_fpd30_obs = 1
),
cohort AS (
    SELECT
         COUNT(*)                                                      AS obs_cnt
        ,SUM(fpd15)                                                    AS bad15
        ,SUM(fpd30)                                                    AS bad30
    FROM base
)
SELECT
     obs_cnt
    ,bad15
    ,bad30
    ,ROUND(bad15 / obs_cnt * 100, 2)                                   AS bad_rate15_pct
    ,ROUND(bad30 / obs_cnt * 100, 2)                                   AS bad_rate30_pct
    ,ROUND(bad30 / bad15 * 100, 2)                                     AS bad_retention_pct
    ,ROUND((bad30 - bad15) / bad15 * 100, 2)                           AS bad_cnt_change_pct
FROM cohort
;


-- ============================================================
-- 块 3：新老客拆分（每个 FPD 观察窗口 × user_type）
-- ============================================================
WITH base AS (
    SELECT
         1 AS window_days
        ,t.user_type
        ,t.y_fpd1_ovd                                                    AS label
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd1                             AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd1_obs = 1
    UNION ALL
    SELECT
         3 AS window_days
        ,t.user_type
        ,t.y_fpd3_ovd                                                    AS label
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd3                             AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd3_obs = 1
    UNION ALL
    SELECT
         7
        ,t.user_type
        ,t.y_fpd7_ovd
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd7                             AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd7_obs = 1
    UNION ALL
    SELECT
         14
        ,t.user_type
        ,CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
              THEN 1 ELSE 0 END                                         AS label
        ,t.real_amount
        ,CASE WHEN d14.listing_id IS NOT NULL
              THEN GREATEST(COALESCE(d14.owing_principal, 0), 0) END     AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.obs_dt
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp d14
      ON t.listing_id = d14.listing_id
     AND d14.stat_date = DATE_ADD(t.init_due_date, 14)
    WHERE t.is_deal = 1
      AND s.listing_id IS NOT NULL
      AND DATE_ADD(t.init_due_date, 14) < t.obs_dt
    UNION ALL
    SELECT
         15
        ,t.user_type
        ,t.y_fpd15_ovd
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd15                            AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
    UNION ALL
    SELECT
         30
        ,t.user_type
        ,t.y_fpd30_ovd
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd30                            AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd30_obs = 1
)
SELECT
     window_days
    ,user_type
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
    ,ROUND(SUM(CASE WHEN label = 1 THEN amt ELSE 0 END)
           / NULLIF(SUM(real_amount), 0) * 100, 2)                   AS bad_rate_amt_pct
FROM base
GROUP BY window_days, user_type
ORDER BY window_days, user_type
;


-- ============================================================
-- 块 4：按放款周的 vintage 路径（每个 FPD 观察窗口 × 放款周，周一开始）
-- ============================================================
WITH base AS (
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd') AS week_start
        ,t.user_type
        ,1 AS window_days
        ,t.y_fpd1_ovd                                                    AS label
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd1                             AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd1_obs = 1
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,t.user_type
        ,3 AS window_days
        ,t.y_fpd3_ovd                                                    AS label
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd3                             AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd3_obs = 1
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,t.user_type
        ,7
        ,t.y_fpd7_ovd
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd7                             AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd7_obs = 1
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,t.user_type
        ,14
        ,CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
              THEN 1 ELSE 0 END                                         AS label
        ,t.real_amount
        ,CASE WHEN d14.listing_id IS NOT NULL
              THEN GREATEST(COALESCE(d14.owing_principal, 0), 0) END     AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.obs_dt
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp d14
      ON t.listing_id = d14.listing_id
     AND d14.stat_date = DATE_ADD(t.init_due_date, 14)
    WHERE t.disburse_time IS NOT NULL
      AND t.is_deal = 1
      AND s.listing_id IS NOT NULL
      AND DATE_ADD(t.init_due_date, 14) < t.obs_dt
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,t.user_type
        ,15
        ,t.y_fpd15_ovd
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd15                            AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd15_obs = 1
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,t.user_type
        ,30
        ,t.y_fpd30_ovd
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd30                            AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd30_obs = 1
),
agg AS (
    SELECT
         week_start
        ,user_type
        ,window_days
        ,COUNT(*)                                                        AS obs_cnt
        ,SUM(label)                                                      AS bad_cnt
        ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
        ,ROUND(SUM(CASE WHEN label = 1 THEN amt ELSE 0 END)
               / NULLIF(SUM(real_amount), 0) * 100, 2)                   AS bad_rate_amt_pct
    FROM base
    GROUP BY week_start, user_type, window_days
)
SELECT
     week_start
    ,'ALL'                                                           AS user_type
    ,window_days
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
    ,ROUND(SUM(CASE WHEN label = 1 THEN amt ELSE 0 END)
           / NULLIF(SUM(real_amount), 0) * 100, 2)                   AS bad_rate_amt_pct
FROM base
GROUP BY week_start, window_days
UNION ALL
SELECT
     week_start
    ,user_type
    ,window_days
    ,obs_cnt
    ,bad_cnt
    ,bad_rate_pct
    ,bad_rate_amt_pct
FROM agg
ORDER BY week_start, user_type, window_days
;


-- ============================================================
-- 块 5：模型分固定 5 箱（FPD15 成熟样本）
--   5a 分数覆盖：FPD15 成熟样本中有分/缺分
--   5b 5 箱 × 新老客：分数区间、样本、坏率
-- 第1箱=最低分，第5箱=最高分；按新客风险 1.0 的固定上限阈值切分
-- ============================================================
WITH base AS (
    SELECT
         t.user_type
        ,t.y_fpd15_ovd                                               AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
)
SELECT
     COUNT(*)                                                        AS obs_cnt
    ,COUNT(score)                                                    AS scored_cnt
    ,SUM(CASE WHEN score IS NULL THEN 1 ELSE 0 END)                  AS missing_cnt
    ,ROUND(CAST(COUNT(score) AS DOUBLE) / COUNT(*) * 100, 2)         AS coverage_pct
FROM base
;

WITH base AS (
    SELECT
         t.loan_no
        ,t.user_type
        ,t.y_fpd15_ovd                                               AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
),
scored AS (
    SELECT
         b.loan_no
        ,b.user_type
        ,b.label
        ,b.score
        ,CASE
             WHEN b.score <= 0.062086 THEN 1
             WHEN b.score <= 0.091284 THEN 2
             WHEN b.score <= 0.128392 THEN 3
             WHEN b.score <= 0.188973 THEN 4
             ELSE 5
         END                                                          AS q
    FROM base b
    WHERE b.score IS NOT NULL
)
SELECT
     'ALL'                                                           AS segment
    ,q
    ,MIN(score)                                                      AS score_min
    ,MAX(score)                                                      AS score_max
    ,ROUND(AVG(score), 4)                                            AS score_avg
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
FROM scored
GROUP BY q
UNION ALL
SELECT
     user_type                                                       AS segment
    ,q
    ,MIN(score)                                                      AS score_min
    ,MAX(score)                                                      AS score_max
    ,ROUND(AVG(score), 4)                                            AS score_avg
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
FROM scored
GROUP BY user_type, q
ORDER BY CASE segment WHEN 'ALL' THEN 0 WHEN 'New' THEN 1 ELSE 2 END, q
;


-- ============================================================
-- 块 6：模型分固定 5 箱 × 放款周（沿用新客风险 1.0 的固定阈值）
--   输出 ALL / New / Old 三组
-- ============================================================
WITH base AS (
    SELECT
         t.loan_no
        ,DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd') AS week_start
        ,t.user_type
        ,t.y_fpd15_ovd                                               AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
),
scored AS (
    SELECT
         b.loan_no
        ,b.week_start
        ,b.user_type
        ,b.label
        ,b.score
        ,CASE
             WHEN b.score <= 0.062086 THEN 1
             WHEN b.score <= 0.091284 THEN 2
             WHEN b.score <= 0.128392 THEN 3
             WHEN b.score <= 0.188973 THEN 4
             ELSE 5
         END                                                          AS q
    FROM base b
    WHERE b.score IS NOT NULL
),
agg AS (
    SELECT
         week_start
        ,user_type
        ,q
        ,COUNT(*)                                                    AS obs_cnt
        ,SUM(label)                                                  AS bad_cnt
        ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)       AS bad_rate_pct
    FROM scored
    WHERE week_start IS NOT NULL
    GROUP BY week_start, user_type, q
)
SELECT
     week_start
    ,'ALL'                                                           AS user_type
    ,q
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
FROM scored
WHERE week_start IS NOT NULL
GROUP BY week_start, q
UNION ALL
SELECT
     week_start
    ,user_type
    ,q
    ,obs_cnt
    ,bad_cnt
    ,bad_rate_pct
FROM agg
ORDER BY week_start, user_type, q
;


-- ============================================================
-- 块 7：老客复借期数（FPD15）
--   application_rank = 1 为首借（= New）；2 / 3 / 4+ 为老客复借
-- ============================================================
WITH base AS (
    SELECT
         CASE
             WHEN CAST(t.application_rank AS INT) = 1 THEN '1st'
             WHEN CAST(t.application_rank AS INT) = 2 THEN '2nd'
             WHEN CAST(t.application_rank AS INT) = 3 THEN '3rd'
             ELSE '4th+'
         END                                                         AS rank_band
        ,CASE
             WHEN CAST(t.application_rank AS INT) = 1 THEN 1
             WHEN CAST(t.application_rank AS INT) = 2 THEN 2
             WHEN CAST(t.application_rank AS INT) = 3 THEN 3
             ELSE 4
         END                                                         AS rank_order
        ,t.user_type
        ,t.y_fpd15_ovd                                               AS label
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
      AND t.application_rank IS NOT NULL
)
SELECT
     rank_order
    ,rank_band
    ,user_type
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
FROM base
GROUP BY rank_order, rank_band, user_type
ORDER BY rank_order, user_type
;


-- ============================================================
-- 块 8：周度排序力（FPD1 / FPD3 / FPD7 / FPD15 成熟样本）
--   AUC 对分数并列取平均秩：AUC = (坏样本秩和 - n_bad(n_bad+1)/2) / (n_bad*n_good)
--   Gini = 2*AUC - 1；KS = max |坏累计占比 - 好累计占比|（按分数分组）
--   输出 window_days × user_type（New / Old / ALL）
-- ============================================================
WITH base AS (
    SELECT
         1                                                           AS window_days
        ,DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd') AS week_start
        ,t.user_type                                                 AS user_type
        ,t.y_fpd1_ovd                                                AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd1_obs = 1
      AND t.disburse_time IS NOT NULL
    UNION ALL
    SELECT
         3                                                           AS window_days
        ,DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd') AS week_start
        ,t.user_type                                                 AS user_type
        ,t.y_fpd3_ovd                                                AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd3_obs = 1
      AND t.disburse_time IS NOT NULL
    UNION ALL
    SELECT
         7                                                           AS window_days
        ,DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd') AS week_start
        ,t.user_type                                                 AS user_type
        ,t.y_fpd7_ovd                                                AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd7_obs = 1
      AND t.disburse_time IS NOT NULL
    UNION ALL
    SELECT
         15                                                          AS window_days
        ,DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd') AS week_start
        ,t.user_type                                                 AS user_type
        ,t.y_fpd15_ovd                                               AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
      AND t.disburse_time IS NOT NULL
),
scored AS (
    SELECT window_days, week_start, user_type, label, score
    FROM base
    WHERE score IS NOT NULL
      AND week_start IS NOT NULL
    UNION ALL
    SELECT window_days, week_start, 'ALL' AS user_type, label, score
    FROM base
    WHERE score IS NOT NULL
      AND week_start IS NOT NULL
),
ranked AS (
    SELECT
         window_days
        ,week_start
        ,user_type
        ,label
        ,RANK() OVER (
            PARTITION BY window_days, week_start, user_type ORDER BY score
        )                                                                    AS r_min
        ,COUNT(*) OVER (
            PARTITION BY window_days, week_start, user_type, score
        )                                                                    AS tie_cnt
    FROM scored
),
rank_avg AS (
    SELECT
         window_days
        ,week_start
        ,user_type
        ,label
        ,r_min + (tie_cnt - 1) / 2.0                                         AS avg_rank
    FROM ranked
),
auc AS (
    SELECT
         window_days
        ,week_start
        ,user_type
        ,COUNT(*)                                                            AS obs_cnt
        ,SUM(label)                                                          AS bad_cnt
        ,SUM(CASE WHEN label = 1 THEN avg_rank ELSE 0 END)                   AS bad_rank_sum
    FROM rank_avg
    GROUP BY window_days, week_start, user_type
),
score_grp AS (
    SELECT
         window_days
        ,week_start
        ,user_type
        ,score
        ,COUNT(*)                                                            AS obs_cnt
        ,SUM(label)                                                          AS bad_cnt
    FROM scored
    GROUP BY window_days, week_start, user_type, score
),
cum AS (
    SELECT
         window_days
        ,week_start
        ,user_type
        ,score
        ,SUM(bad_cnt) OVER (
            PARTITION BY window_days, week_start, user_type ORDER BY score
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                    AS cum_bad
        ,SUM(obs_cnt - bad_cnt) OVER (
            PARTITION BY window_days, week_start, user_type ORDER BY score
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                    AS cum_good
        ,SUM(bad_cnt) OVER (
            PARTITION BY window_days, week_start, user_type
        )                                                                    AS tot_bad
        ,SUM(obs_cnt - bad_cnt) OVER (
            PARTITION BY window_days, week_start, user_type
        )                                                                    AS tot_good
    FROM score_grp
),
ks AS (
    SELECT
         window_days
        ,week_start
        ,user_type
        ,MAX(ABS(CAST(cum_bad AS DOUBLE) / NULLIF(tot_bad, 0)
                 - CAST(cum_good AS DOUBLE) / NULLIF(tot_good, 0)))          AS ks
    FROM cum
    GROUP BY window_days, week_start, user_type
)
SELECT
     a.window_days
    ,a.week_start
    ,a.user_type
    ,a.obs_cnt
    ,a.bad_cnt
    ,ROUND(CAST(a.bad_cnt AS DOUBLE) / a.obs_cnt * 100, 2)                     AS bad_rate_pct
    ,ROUND((a.bad_rank_sum - CAST(a.bad_cnt AS DOUBLE) * (a.bad_cnt + 1) / 2)
           / NULLIF(CAST(a.bad_cnt AS DOUBLE) * (a.obs_cnt - a.bad_cnt), 0), 4) AS auc
    ,ROUND(2 * (a.bad_rank_sum - CAST(a.bad_cnt AS DOUBLE) * (a.bad_cnt + 1) / 2)
           / NULLIF(CAST(a.bad_cnt AS DOUBLE) * (a.obs_cnt - a.bad_cnt), 0) - 1, 4) AS gini
    ,ROUND(k.ks, 4)                                                            AS ks
FROM auc a
LEFT JOIN ks k
  ON a.window_days = k.window_days
 AND a.week_start = k.week_start
 AND a.user_type = k.user_type
ORDER BY a.window_days, a.week_start, a.user_type
;


-- ============================================================
-- 块 9：放款周 × 新老客（FPD15 笔数与金额坏率）
--   用于看周度客群结构变化，以及整体坏率的组内 / 结构贡献拆分
-- ============================================================
WITH base AS (
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd') AS week_start
        ,t.user_type
        ,t.y_fpd15_ovd                                               AS label
        ,t.real_amount
        ,t.estimate_principal_remaining_fpd15                        AS amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd15_obs = 1
)
SELECT
     week_start
    ,user_type
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
    ,ROUND(SUM(CASE WHEN label = 1 THEN amt ELSE 0 END)
           / NULLIF(SUM(real_amount), 0) * 100, 2)                   AS bad_rate_amt_pct
FROM base
GROUP BY week_start, user_type
ORDER BY week_start, user_type
;

-- ============================================================
-- 块 10：月度排序力（FPD1 / FPD3 / FPD7 / FPD15）× 新老客
--   月度口径 = 放款日所在自然月；AUC / Gini / KS 算法与块 8 一致
--   输出 window_days × user_type（New / Old / ALL）
-- ============================================================
WITH base AS (
    SELECT
         1                                                           AS window_days
        ,DATE_FORMAT(TO_DATE(t.disburse_time), 'yyyy-MM')            AS month_key
        ,t.user_type                                                 AS user_type
        ,t.y_fpd1_ovd                                                AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd1_obs = 1
      AND t.disburse_time IS NOT NULL
    UNION ALL
    SELECT
         3                                                           AS window_days
        ,DATE_FORMAT(TO_DATE(t.disburse_time), 'yyyy-MM')            AS month_key
        ,t.user_type                                                 AS user_type
        ,t.y_fpd3_ovd                                                AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd3_obs = 1
      AND t.disburse_time IS NOT NULL
    UNION ALL
    SELECT
         7                                                           AS window_days
        ,DATE_FORMAT(TO_DATE(t.disburse_time), 'yyyy-MM')            AS month_key
        ,t.user_type                                                 AS user_type
        ,t.y_fpd7_ovd                                                AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd7_obs = 1
      AND t.disburse_time IS NOT NULL
    UNION ALL
    SELECT
         15                                                          AS window_days
        ,DATE_FORMAT(TO_DATE(t.disburse_time), 'yyyy-MM')            AS month_key
        ,t.user_type                                                 AS user_type
        ,t.y_fpd15_ovd                                               AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
      AND t.disburse_time IS NOT NULL
),
scored AS (
    SELECT window_days, month_key, user_type, label, score
    FROM base
    WHERE score IS NOT NULL
      AND month_key IS NOT NULL
    UNION ALL
    SELECT window_days, month_key, 'ALL' AS user_type, label, score
    FROM base
    WHERE score IS NOT NULL
      AND month_key IS NOT NULL
),
ranked AS (
    SELECT
         window_days
        ,month_key
        ,user_type
        ,label
        ,RANK() OVER (
            PARTITION BY window_days, month_key, user_type ORDER BY score
        )                                                                    AS r_min
        ,COUNT(*) OVER (
            PARTITION BY window_days, month_key, user_type, score
        )                                                                    AS tie_cnt
    FROM scored
),
rank_avg AS (
    SELECT
         window_days
        ,month_key
        ,user_type
        ,label
        ,r_min + (tie_cnt - 1) / 2.0                                         AS avg_rank
    FROM ranked
),
auc AS (
    SELECT
         window_days
        ,month_key
        ,user_type
        ,COUNT(*)                                                            AS obs_cnt
        ,SUM(label)                                                          AS bad_cnt
        ,SUM(CASE WHEN label = 1 THEN avg_rank ELSE 0 END)                   AS bad_rank_sum
    FROM rank_avg
    GROUP BY window_days, month_key, user_type
),
score_grp AS (
    SELECT
         window_days
        ,month_key
        ,user_type
        ,score
        ,COUNT(*)                                                            AS obs_cnt
        ,SUM(label)                                                          AS bad_cnt
    FROM scored
    GROUP BY window_days, month_key, user_type, score
),
cum AS (
    SELECT
         window_days
        ,month_key
        ,user_type
        ,score
        ,SUM(bad_cnt) OVER (
            PARTITION BY window_days, month_key, user_type ORDER BY score
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                    AS cum_bad
        ,SUM(obs_cnt - bad_cnt) OVER (
            PARTITION BY window_days, month_key, user_type ORDER BY score
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                    AS cum_good
        ,SUM(bad_cnt) OVER (
            PARTITION BY window_days, month_key, user_type
        )                                                                    AS tot_bad
        ,SUM(obs_cnt - bad_cnt) OVER (
            PARTITION BY window_days, month_key, user_type
        )                                                                    AS tot_good
    FROM score_grp
),
ks AS (
    SELECT
         window_days
        ,month_key
        ,user_type
        ,MAX(ABS(CAST(cum_bad AS DOUBLE) / NULLIF(tot_bad, 0)
                 - CAST(cum_good AS DOUBLE) / NULLIF(tot_good, 0)))          AS ks
    FROM cum
    GROUP BY window_days, month_key, user_type
)
SELECT
     a.window_days
    ,a.month_key
    ,a.user_type
    ,a.obs_cnt
    ,a.bad_cnt
    ,ROUND(CAST(a.bad_cnt AS DOUBLE) / a.obs_cnt * 100, 2)                     AS bad_rate_pct
    ,ROUND((a.bad_rank_sum - CAST(a.bad_cnt AS DOUBLE) * (a.bad_cnt + 1) / 2)
           / NULLIF(CAST(a.bad_cnt AS DOUBLE) * (a.obs_cnt - a.bad_cnt), 0), 4) AS auc
    ,ROUND(2 * (a.bad_rank_sum - CAST(a.bad_cnt AS DOUBLE) * (a.bad_cnt + 1) / 2)
           / NULLIF(CAST(a.bad_cnt AS DOUBLE) * (a.obs_cnt - a.bad_cnt), 0) - 1, 4) AS gini
    ,ROUND(k.ks, 4)                                                            AS ks
FROM auc a
LEFT JOIN ks k
  ON a.window_days = k.window_days
 AND a.month_key = k.month_key
 AND a.user_type = k.user_type
ORDER BY a.window_days, a.month_key, a.user_type
;


-- ============================================================
-- 块 11a：新客戳额全量样本的线上模型分覆盖（全历史，不设时间窗）
--   样本：每个用户全历史第一次戳额申请（额度申请表优先，风控事件兜底）
--         与 wagego_02 新客戳额样本同一构建逻辑，仅去掉时间窗筛选
--   分数：戳额时点的线上模型分，按 scene_id = 戳额流水取模型运行日志最新一条
-- ============================================================
WITH credit AS (
    SELECT
         a.borrower_id                                        AS user_id
        ,CAST(a.inserttime AS TIMESTAMP)                      AS credit_time
        ,a.flow_no                                            AS flow_id
        ,1                                                    AS source_priority
    FROM ods_ewa.aus_listing_tb_loan_limit_apply a
    WHERE CAST(a.isactive AS INT) = 1
      AND CAST(a.biz_type AS INT) = 400
    UNION ALL
    SELECT
         e.user_id
        ,CAST(e.inserttime AS TIMESTAMP)
        ,e.flow_id
        ,2
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
ranked AS (
    SELECT
         user_id
        ,credit_time
        ,flow_id
        ,ROW_NUMBER() OVER (
             PARTITION BY user_id
             ORDER BY credit_time ASC NULLS LAST, source_priority, flow_id
         )                                                    AS rn
    FROM credit
),
first_credit AS (
    SELECT user_id, credit_time, flow_id
    FROM ranked
    WHERE rn = 1
      AND credit_time IS NOT NULL
),
credit_score AS (
    SELECT
         c.user_id
        ,DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(c.credit_time)), 'yyyy-MM-dd') AS week_start
        ,CASE WHEN s.old_score < 0 THEN NULL ELSE s.old_score END AS score
    FROM first_credit c
    LEFT JOIN (
        SELECT t.flow_id, t.old_score
        FROM (
            SELECT
                 r.scene_id                                   AS flow_id
                ,CAST(GET_JSON_OBJECT(
                     r.model_output,
                     '$.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626'
                 ) AS DOUBLE)                                 AS old_score
                ,ROW_NUMBER() OVER (
                     PARTITION BY r.scene_id
                     ORDER BY CAST(r.start_time AS TIMESTAMP) DESC,
                              CAST(r.inserttime AS TIMESTAMP) DESC
                 )                                            AS rn
            FROM ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log r
            JOIN first_credit c2
              ON CAST(r.scene_id AS STRING) = CAST(c2.flow_id AS STRING)
            WHERE r.model_code = 'aus_wagego_new_risk_3rd_v1_0'
        ) t
        WHERE t.rn = 1
    ) s
      ON CAST(c.flow_id AS STRING) = CAST(s.flow_id AS STRING)
)
SELECT
     week_start
    ,COUNT(*)                                                 AS sample_cnt
    ,COUNT(score)                                             AS scored_cnt
    ,SUM(CASE WHEN score IS NULL THEN 1 ELSE 0 END)           AS missing_cnt
    ,ROUND(CAST(COUNT(score) AS DOUBLE) / COUNT(*) * 100, 2)  AS coverage_pct
FROM credit_score
GROUP BY week_start
UNION ALL
SELECT
     'ALL'                                                    AS week_start
    ,COUNT(*)
    ,COUNT(score)
    ,SUM(CASE WHEN score IS NULL THEN 1 ELSE 0 END)
    ,ROUND(CAST(COUNT(score) AS DOUBLE) / COUNT(*) * 100, 2)
FROM credit_score
ORDER BY CASE WHEN week_start = 'ALL' THEN 0 ELSE 1 END, week_start
;


-- ============================================================
-- 块 11b：新客戳额全量样本的线上模型分固定 10 档分布（按戳额周）
--   切点与线上模型固定十等分一致；看板按相邻两档合并为 5 档
--   仅统计有分用户；负分按缺分处理
-- ============================================================
WITH credit AS (
    SELECT
         a.borrower_id                                        AS user_id
        ,CAST(a.inserttime AS TIMESTAMP)                      AS credit_time
        ,a.flow_no                                            AS flow_id
        ,1                                                    AS source_priority
    FROM ods_ewa.aus_listing_tb_loan_limit_apply a
    WHERE CAST(a.isactive AS INT) = 1
      AND CAST(a.biz_type AS INT) = 400
    UNION ALL
    SELECT
         e.user_id
        ,CAST(e.inserttime AS TIMESTAMP)
        ,e.flow_id
        ,2
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
ranked AS (
    SELECT
         user_id
        ,credit_time
        ,flow_id
        ,ROW_NUMBER() OVER (
             PARTITION BY user_id
             ORDER BY credit_time ASC NULLS LAST, source_priority, flow_id
         )                                                    AS rn
    FROM credit
),
first_credit AS (
    SELECT user_id, credit_time, flow_id
    FROM ranked
    WHERE rn = 1
      AND credit_time IS NOT NULL
),
credit_score AS (
    SELECT
         c.user_id
        ,DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(c.credit_time)), 'yyyy-MM-dd') AS week_start
        ,CASE WHEN s.old_score < 0 THEN NULL ELSE s.old_score END AS score
    FROM first_credit c
    LEFT JOIN (
        SELECT t.flow_id, t.old_score
        FROM (
            SELECT
                 r.scene_id                                   AS flow_id
                ,CAST(GET_JSON_OBJECT(
                     r.model_output,
                     '$.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626'
                 ) AS DOUBLE)                                 AS old_score
                ,ROW_NUMBER() OVER (
                     PARTITION BY r.scene_id
                     ORDER BY CAST(r.start_time AS TIMESTAMP) DESC,
                              CAST(r.inserttime AS TIMESTAMP) DESC
                 )                                            AS rn
            FROM ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log r
            JOIN first_credit c2
              ON CAST(r.scene_id AS STRING) = CAST(c2.flow_id AS STRING)
            WHERE r.model_code = 'aus_wagego_new_risk_3rd_v1_0'
        ) t
        WHERE t.rn = 1
    ) s
      ON CAST(c.flow_id AS STRING) = CAST(s.flow_id AS STRING)
),
scored AS (
    SELECT
         week_start
        ,score
        ,CASE
             WHEN score <= 0.048577 THEN 1
             WHEN score <= 0.062086 THEN 2
             WHEN score <= 0.075629 THEN 3
             WHEN score <= 0.091284 THEN 4
             WHEN score <= 0.109224 THEN 5
             WHEN score <= 0.128392 THEN 6
             WHEN score <= 0.154584 THEN 7
             WHEN score <= 0.188973 THEN 8
             WHEN score <= 0.240037 THEN 9
             ELSE 10
         END                                                      AS q
    FROM credit_score
    WHERE score IS NOT NULL
),
week_agg AS (
    SELECT week_start, q, COUNT(*) AS obs_cnt
    FROM scored
    GROUP BY week_start, q
),
week_tot AS (
    SELECT week_start, SUM(obs_cnt) AS total_cnt
    FROM week_agg
    GROUP BY week_start
),
all_agg AS (
    SELECT q, COUNT(*) AS obs_cnt
    FROM scored
    GROUP BY q
),
all_tot AS (
    SELECT SUM(obs_cnt) AS total_cnt
    FROM all_agg
)
SELECT
     m.week_start
    ,m.q
    ,m.obs_cnt
    ,ROUND(CAST(m.obs_cnt AS DOUBLE) / t.total_cnt * 100, 2)  AS share_pct
FROM week_agg m
JOIN week_tot t
  ON m.week_start = t.week_start
UNION ALL
SELECT
     'ALL'                                                    AS week_start
    ,a.q
    ,a.obs_cnt
    ,ROUND(CAST(a.obs_cnt AS DOUBLE) / t.total_cnt * 100, 2)  AS share_pct
FROM all_agg a
CROSS JOIN all_tot t
ORDER BY week_start, q
;


-- ============================================================
-- 块 12：新客出额样本转化漏斗（按戳额周）
--   出额样本：model.tmp_eliam_wagego_new_user_credit_full_samples（全历史、不设时间窗）
--           每个用户一行，sample_datetime = 戳额申请时间；
--   出额审批通过率 = 有额用户 / 出额明细可匹配用户
--           出额结果取 edw_ewa.dwb_user_fst_conv_dtl 的首次有额时间/额度；
--           若该表用户主键不是 user_id，请按实际字段调整 join
--   借款申请审核通过率 = 审核通过用户 / 有借款申请用户
--           审核通过 = AUDIT_APPROVED / DISBURSE_SUCCESS / DISBURSE_FAILED
--   成交率 = 放款成功用户 / 有借款申请用户
--   只取戳额日之后的借款申请；用户级去重，避免多次申请抬高分母
-- ============================================================
WITH credit AS (
    SELECT
         user_id
        ,MIN(sample_datetime) AS sample_datetime
    FROM model.tmp_eliam_wagego_new_user_credit_full_samples
    GROUP BY user_id
),
credit_w AS (
    SELECT
         user_id
        ,TO_DATE(sample_datetime)                                      AS credit_date
        ,DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(sample_datetime)), 'yyyy-MM-dd') AS week_start
    FROM credit
),
limit_user AS (
    SELECT
         c.user_id
        ,1                                                             AS has_limit_detail
        ,MAX(CASE WHEN l.fst_has_limit_time IS NOT NULL
                   AND TO_DATE(l.fst_has_limit_time) >= c.credit_date
                  THEN 1 ELSE 0 END)                                   AS has_limit
    FROM credit_w c
    JOIN edw_ewa.dwb_user_fst_conv_dtl l
      ON l.user_id = c.user_id
    GROUP BY c.user_id
),
app_user AS (
    SELECT
         a.user_id
        ,COUNT(*)                                                      AS apply_cnt
        ,SUM(CASE WHEN a.apply_status IN ('AUDIT_APPROVED', 'DISBURSE_SUCCESS', 'DISBURSE_FAILED')
                  THEN 1 ELSE 0 END)                                   AS pass_cnt
        ,SUM(CASE WHEN a.apply_status = 'DISBURSE_SUCCESS' THEN 1 ELSE 0 END) AS deal_cnt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label a
    JOIN credit_w c
      ON a.user_id = c.user_id
     AND TO_DATE(a.apply_time) >= c.credit_date
    GROUP BY a.user_id
),
agg AS (
    SELECT
         c.week_start
        ,COUNT(*)                                                      AS credit_users
        ,SUM(COALESCE(l.has_limit_detail, 0))                          AS limit_detail_users
        ,SUM(COALESCE(l.has_limit, 0))                                 AS limit_users
        ,SUM(CASE WHEN a.user_id IS NOT NULL THEN 1 ELSE 0 END)        AS apply_users
        ,SUM(CASE WHEN COALESCE(a.pass_cnt, 0) > 0 THEN 1 ELSE 0 END)  AS pass_users
        ,SUM(CASE WHEN COALESCE(a.deal_cnt, 0) > 0 THEN 1 ELSE 0 END)  AS deal_users
        ,SUM(COALESCE(a.apply_cnt, 0))                                 AS apply_cnt
        ,SUM(COALESCE(a.pass_cnt, 0))                                  AS pass_cnt
        ,SUM(COALESCE(a.deal_cnt, 0))                                  AS deal_cnt
    FROM credit_w c
    LEFT JOIN limit_user l
      ON l.user_id = c.user_id
    LEFT JOIN app_user a
      ON a.user_id = c.user_id
    GROUP BY c.week_start
)
SELECT
     week_start
    ,credit_users
    ,limit_detail_users
    ,limit_users
    ,apply_users
    ,pass_users
    ,deal_users
    ,apply_cnt
    ,pass_cnt
    ,deal_cnt
    ,ROUND(CAST(limit_users AS DOUBLE) / NULLIF(limit_detail_users, 0) * 100, 2) AS limit_pass_rate_pct
    ,ROUND(CAST(apply_users AS DOUBLE) / NULLIF(credit_users, 0) * 100, 2)       AS apply_rate_pct
    ,ROUND(CAST(pass_users AS DOUBLE) / NULLIF(apply_users, 0) * 100, 2)         AS audit_pass_rate_pct
    ,ROUND(CAST(deal_users AS DOUBLE) / NULLIF(apply_users, 0) * 100, 2)         AS deal_rate_pct
    ,ROUND(CAST(pass_cnt AS DOUBLE) / NULLIF(apply_cnt, 0) * 100, 2)             AS audit_pass_rate_cnt_pct
    ,ROUND(CAST(deal_cnt AS DOUBLE) / NULLIF(pass_cnt, 0) * 100, 2)              AS deal_rate_cnt_pct
    ,ROUND(CAST(deal_users AS DOUBLE) / NULLIF(credit_users, 0) * 100, 2)        AS credit_deal_rate_pct
    ,GREATEST(0, DATEDIFF(CURRENT_DATE(), DATE_ADD(TO_DATE(week_start), 7))) AS cohort_days
FROM agg
ORDER BY week_start
;
