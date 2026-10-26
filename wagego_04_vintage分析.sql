SET spark.sql.session.timeZone = Australia/Sydney;

-- WageGo Vintage 分析：各 FPD 观察窗口的坏率与 cohort 路径
-- 数据源：model.tmp_eliam_wagego_dwd_loan_apply_label
-- 口径：
--   1) 每个窗口用各自日历 cohort：is_deal = 1 且 init_due_date + X < obs_dt
--   2) 坏 = 首期实还日（未还则取 obs_dt）晚于 due + X
--   3) FPD14 主表没有独立字段，用 model.tmp_eliam_wagego_stg_debt_snp 的首期实还日补算
--   4) 金额坏率 = 坏样本 real_amount / 全部 real_amount
--   5) 块 3 按 user_type 拆分；块 4 按放款周（周一开始）拆 vintage 路径


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
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 3) < t.obs_dt
    UNION ALL
    SELECT
         7
        ,COUNT(*)
        ,SUM(t.y_fpd7_ovd)
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN t.y_fpd7_ovd = 1 THEN t.real_amount ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 7) < t.obs_dt
    UNION ALL
    SELECT
         14
        ,COUNT(*)
        ,SUM(CASE WHEN s.listing_id IS NOT NULL
                  THEN CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
                            THEN 1 ELSE 0 END
             END)                                                       AS bad_cnt
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN s.listing_id IS NOT NULL
                  THEN CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
                            THEN t.real_amount ELSE 0 END
             END)                                                       AS bad_amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.obs_dt
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 14) < t.obs_dt
    UNION ALL
    SELECT
         15
        ,COUNT(*)
        ,SUM(t.y_fpd15_ovd)
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN t.y_fpd15_ovd = 1 THEN t.real_amount ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 15) < t.obs_dt
    UNION ALL
    SELECT
         30
        ,COUNT(*)
        ,SUM(t.y_fpd30_ovd)
        ,SUM(t.real_amount)
        ,SUM(CASE WHEN t.y_fpd30_ovd = 1 THEN t.real_amount ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 30) < t.obs_dt
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
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 30) < t.obs_dt
      AND t.y_fpd15_ovd IS NOT NULL
      AND t.y_fpd30_ovd IS NOT NULL
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
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 3) < t.obs_dt
    UNION ALL
    SELECT
         7
        ,t.user_type
        ,t.y_fpd7_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 7) < t.obs_dt
    UNION ALL
    SELECT
         14
        ,t.user_type
        ,CASE WHEN s.listing_id IS NOT NULL
              THEN CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
                        THEN 1 ELSE 0 END
         END                                                             AS label
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.obs_dt
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 14) < t.obs_dt
    UNION ALL
    SELECT
         15
        ,t.user_type
        ,t.y_fpd15_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 15) < t.obs_dt
    UNION ALL
    SELECT
         30
        ,t.user_type
        ,t.y_fpd30_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 30) < t.obs_dt
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
    WHERE t.is_deal = 1
      AND t.disburse_time IS NOT NULL
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 3) < t.obs_dt
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,7
        ,t.y_fpd7_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.is_deal = 1
      AND t.disburse_time IS NOT NULL
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 7) < t.obs_dt
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,14
        ,CASE WHEN s.listing_id IS NOT NULL
              THEN CASE WHEN COALESCE(TO_DATE(s.first_repay_time), t.obs_dt) > DATE_ADD(t.init_due_date, 14)
                        THEN 1 ELSE 0 END
         END                                                             AS label
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.obs_dt
    WHERE t.is_deal = 1
      AND t.disburse_time IS NOT NULL
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 14) < t.obs_dt
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,15
        ,t.y_fpd15_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.is_deal = 1
      AND t.disburse_time IS NOT NULL
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 15) < t.obs_dt
    UNION ALL
    SELECT
         DATE_FORMAT(DATE_TRUNC('WEEK', TO_DATE(t.disburse_time)), 'yyyy-MM-dd')
        ,30
        ,t.y_fpd30_ovd
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    WHERE t.is_deal = 1
      AND t.disburse_time IS NOT NULL
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 30) < t.obs_dt
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
