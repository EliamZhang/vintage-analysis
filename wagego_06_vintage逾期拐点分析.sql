SET spark.sql.session.timeZone = Australia/Sydney;

-- Vintage 逾期拐点分析：用来确定模型分 Y 标签选哪个 FPD 窗口
-- 数据源：主表 + 借据日快照宽表 stg_debt_snp（按 listing_id 取到期日后的逐日快照）
-- 口径：FPD-X = 到期日后第 X 天仍未还清首期；分母只算已观察到第 X 天的放款
-- 拐点：bad_rate 随 window_days 增长趋于平缓（bad_rate_chg 接近 0）的窗口即可作 Y 标签

WITH loan AS (
    SELECT
         loan_no
        ,listing_id
        ,disburse_month
        ,init_due_date
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
),
snap AS (
    SELECT
         l.loan_no
        ,l.disburse_month
        ,l.init_due_date
        ,TO_DATE(d.first_repay_time)                      AS first_repay_time
        ,DATEDIFF(TO_DATE(d.stat_date), l.init_due_date)  AS days_since_due
    FROM loan l
    JOIN model.tmp_eliam_wagego_stg_debt_snp d
      ON d.listing_id = l.listing_id
     AND TO_DATE(d.stat_date) >= l.init_due_date
),
loan_state AS (
    SELECT
         loan_no
        ,disburse_month
        ,init_due_date
        ,MIN(first_repay_time)                            AS first_repay_date
        ,MAX(days_since_due)                              AS max_obs_day
    FROM snap
    GROUP BY loan_no, disburse_month, init_due_date
),
loan_day AS (
    SELECT
         loan_no
        ,disburse_month
        ,max_obs_day
        ,DATEDIFF(first_repay_date, init_due_date)        AS fpd_day
    FROM loan_state
),
windows AS (
    SELECT EXPLODE(SEQUENCE(1, 60))                       AS window_days
),
curve_all AS (
    SELECT
         'ALL'                                            AS dimension
        ,CAST(NULL AS STRING)                             AS disburse_month
        ,w.window_days
        ,COUNT(*)                                         AS loan_cnt
        ,SUM(CASE WHEN l.fpd_day IS NULL OR l.fpd_day > w.window_days THEN 1 ELSE 0 END) AS bad_cnt
    FROM loan_day l
    CROSS JOIN windows w
    WHERE l.max_obs_day >= w.window_days
    GROUP BY w.window_days
),
curve_month AS (
    SELECT
         'disburse_month'                                 AS dimension
        ,l.disburse_month
        ,w.window_days
        ,COUNT(*)                                         AS loan_cnt
        ,SUM(CASE WHEN l.fpd_day IS NULL OR l.fpd_day > w.window_days THEN 1 ELSE 0 END) AS bad_cnt
    FROM loan_day l
    CROSS JOIN windows w
    WHERE l.max_obs_day >= w.window_days
    GROUP BY l.disburse_month, w.window_days
),
curve AS (
    SELECT * FROM curve_all
    UNION ALL
    SELECT * FROM curve_month
)
SELECT
     dimension
    ,disburse_month
    ,window_days
    ,loan_cnt
    ,bad_cnt
    ,ROUND(bad_rate, 4)                                   AS bad_rate
    ,ROUND(bad_rate - LAG(bad_rate) OVER (PARTITION BY dimension, disburse_month ORDER BY window_days), 4) AS bad_rate_chg
FROM (
    SELECT
         *
        ,bad_cnt / loan_cnt                               AS bad_rate
    FROM curve
) c
ORDER BY dimension, disburse_month, window_days
;
