SET spark.sql.session.timeZone = Australia/Sydney;

-- WageGo Vintage 分析：各 FPD 观察窗口的坏率与 cohort 路径
-- 数据源：model.tmp_eliam_wagego_dwd_loan_apply_label
-- 口径：
--   1) 每个窗口用各自成熟 cohort：y_fpdN_obs = 1（is_deal = 1、观察日有借据快照、due+N < obs_dt）
--   2) 坏 = 首期实还日（未还则取 obs_dt）晚于 due + X
--   3) FPD14 主表没有独立字段，用 model.tmp_eliam_wagego_stg_debt_snp 的首期实还日补算，成熟条件同口径
--   4) 金额坏率 = 坏样本 real_amount / 全部 real_amount
--   5) 块 3 按 user_type 拆分；块 4 按放款周（周一开始）拆 vintage 路径
--   6) 块 5-6 模型分五分位：FPD15 成熟样本内统一切分，切点固定后套到新老客和放款周
--   7) 块 7 按 application_rank 拆复借期数：1st / 2nd / 3rd / 4th+


-- ============================================================
-- 块 1：各窗口成熟样本、坏样本、笔数坏率、金额坏率
-- ============================================================
WITH win AS (
    SELECT
         3 AS window_days
        ,COUNT(*)                                                       AS obs_cnt
        ,SUM(t.y_fpd3_ovd)                                              AS bad_cnt
        ,SUM(t.real_amount)                                             AS total_amt
        ,SUM(CASE WHEN t.y_fpd3_ovd = 1 THEN t.real_amount ELSE 0 END)  AS bad_amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd3_obs = 1
    UNION ALL
    SELECT
         7
        ,COUNT(*)
        ,SUM(t.y_fpd7_ovd)
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN t.y_fpd7_ovd = 1 THEN t.real_amount ELSE 0 END)
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
                  THEN t.real_amount ELSE 0 END)                        AS bad_amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.obs_dt
    WHERE t.is_deal = 1
      AND s.listing_id IS NOT NULL
      AND DATE_ADD(t.init_due_date, 14) < t.obs_dt
    UNION ALL
    SELECT
         15
        ,COUNT(*)
        ,SUM(t.y_fpd15_ovd)
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN t.y_fpd15_ovd = 1 THEN t.real_amount ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
    UNION ALL
    SELECT
         30
        ,COUNT(*)
        ,SUM(t.y_fpd30_ovd)
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN t.y_fpd30_ovd = 1 THEN t.real_amount ELSE 0 END)
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
         3 AS window_days
        ,t.user_type
        ,t.y_fpd3_ovd                                                    AS label
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd3_obs = 1
    UNION ALL
    SELECT
         7
        ,t.user_type
        ,t.y_fpd7_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd7_obs = 1
    UNION ALL
    SELECT
         14
        ,t.user_type
        ,CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
              THEN 1 ELSE 0 END                                         AS label
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.obs_dt
    WHERE t.is_deal = 1
      AND s.listing_id IS NOT NULL
      AND DATE_ADD(t.init_due_date, 14) < t.obs_dt
    UNION ALL
    SELECT
         15
        ,t.user_type
        ,t.y_fpd15_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
    UNION ALL
    SELECT
         30
        ,t.user_type
        ,t.y_fpd30_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd30_obs = 1
)
SELECT
     window_days
    ,user_type
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
    ,ROUND(SUM(CASE WHEN label = 1 THEN real_amount ELSE 0 END)
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
        ,3 AS window_days
        ,t.y_fpd3_ovd                                                    AS label
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd3_obs = 1
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,7
        ,t.y_fpd7_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd7_obs = 1
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,14
        ,CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
              THEN 1 ELSE 0 END                                         AS label
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.obs_dt
    WHERE t.disburse_time IS NOT NULL
      AND t.is_deal = 1
      AND s.listing_id IS NOT NULL
      AND DATE_ADD(t.init_due_date, 14) < t.obs_dt
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,15
        ,t.y_fpd15_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd15_obs = 1
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,30
        ,t.y_fpd30_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.disburse_time IS NOT NULL
      AND t.y_fpd30_obs = 1
)
SELECT
     week_start
    ,window_days
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
    ,ROUND(SUM(CASE WHEN label = 1 THEN real_amount ELSE 0 END)
           / NULLIF(SUM(real_amount), 0) * 100, 2)                   AS bad_rate_amt_pct
FROM base
GROUP BY week_start, window_days
ORDER BY week_start, window_days
;


-- ============================================================
-- 块 5：模型分五分位（FPD15 成熟样本）
--   5a 分数覆盖：FPD15 成熟样本中有分/缺分
--   5b 五分位 × 新老客：分数区间、样本、坏率
-- Q1=最低分，Q5=最高分；先看 Q1→Q5 是否单调，再决定页面是否合并档位
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
        ,NTILE(5) OVER (ORDER BY b.score, b.loan_no)                  AS q
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
-- 块 6：模型分五分位 × 放款周（五分位沿用 FPD15 成熟样本的 pooled 切点）
-- ============================================================
WITH base AS (
    SELECT
         t.loan_no
        ,DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd') AS week_start
        ,t.y_fpd15_ovd                                               AS label
        ,t.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626            AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.y_fpd15_obs = 1
),
scored AS (
    SELECT
         b.loan_no
        ,b.week_start
        ,b.label
        ,b.score
        ,NTILE(5) OVER (ORDER BY b.score, b.loan_no)                  AS q
    FROM base b
    WHERE b.score IS NOT NULL
)
SELECT
     week_start
    ,q
    ,COUNT(*)                                                        AS obs_cnt
    ,SUM(label)                                                      AS bad_cnt
    ,ROUND(CAST(SUM(label) AS DOUBLE) / COUNT(*) * 100, 2)           AS bad_rate_pct
FROM scored
WHERE week_start IS NOT NULL
GROUP BY week_start, q
ORDER BY week_start, q
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
