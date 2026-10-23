SET spark.sql.session.timeZone = Australia/Sydney;

-- 账龄 vintage：按放款月分组，看放款后第 N 天的 5+ 逾期率
-- 数据源：主表 + 借据日快照宽表 stg_debt_snp（listing_id × stat_date）
-- 口径：age_days = 快照日 - 放款日；分母 = 当天有快照的借据
--   cur_5plus  ：当天 current_overdue_days >= 5（当期仍未结清）
--   ever_5plus ：当天 hist_overdue_days    >= 5（账龄内曾出现过 5+，只升不降）
-- 横轴锚在放款日，与 FPD 曲线（锚在到期日）是两套视角

WITH loan AS (
    SELECT
         loan_no
        ,listing_id
        ,disburse_month
        ,TO_DATE(disburse_time)                           AS disburse_date
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND disburse_time IS NOT NULL
),
snap AS (
    SELECT
         l.loan_no
        ,l.disburse_month
        ,DATEDIFF(TO_DATE(d.stat_date), l.disburse_date)  AS age_days
        ,d.current_overdue_days
        ,d.hist_overdue_days
    FROM loan l
    JOIN model.tmp_eliam_wagego_stg_debt_snp d
      ON d.listing_id = l.listing_id
     AND TO_DATE(d.stat_date) >= l.disburse_date
    WHERE DATEDIFF(TO_DATE(d.stat_date), l.disburse_date) BETWEEN 1 AND 60
)
SELECT
     disburse_month
    ,age_days
    ,COUNT(*)                                             AS loan_cnt
    ,SUM(CASE WHEN current_overdue_days >= 5 THEN 1 ELSE 0 END) AS cur_5plus_cnt
    ,SUM(CASE WHEN hist_overdue_days    >= 5 THEN 1 ELSE 0 END) AS ever_5plus_cnt
    ,ROUND(SUM(CASE WHEN current_overdue_days >= 5 THEN 1 ELSE 0 END) / COUNT(*), 4) AS cur_5plus_rate
    ,ROUND(SUM(CASE WHEN hist_overdue_days    >= 5 THEN 1 ELSE 0 END) / COUNT(*), 4) AS ever_5plus_rate
FROM snap
GROUP BY disburse_month, age_days
ORDER BY disburse_month, age_days
;
