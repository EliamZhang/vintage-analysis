SET spark.sql.session.timeZone = Australia/Sydney;

-- Y 标签选型评估：在坏率拐点之外，补信息增量、模型区分度、稳定性、最终风险对齐四个维度
-- 数据源：model.tmp_eliam_wagego_dwd_loan_apply_label
-- 分数：aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626（越高越坏；若 AUC < 0.5 说明方向相反）
-- 口径说明：
--   1) 跨窗口比较使用日历 cohort：is_deal = 1 且 init_due_date + X < obs_dt，所有候选窗口在同一日历边界上完全观察
--      不能用 y_fpdX_obs_cnt 过滤：它把已还清的近期借据也算成熟，长窗口坏率会被严重稀释
--   2) 相邻窗口（14 vs 15）用 due+15 的日历 cohort，样本更大
--   3) label_* 字段是 init_due_date + 31 天的快照；放款太新、尚未到 due+31 的样本该快照不存在，
--      涉及 label_* 的分析要求 label_hist_overdue_days IS NOT NULL


-- ============================================================
-- 块 1：各候选窗口的成熟覆盖与坏率（笔数 + 金额，含 Wilson 95% 置信区间）
-- 每个窗口用各自的日历 cohort（due+X < obs_dt），看窗口拉长后坏率下降多少、样本损失多少
-- ============================================================
WITH win AS (
    SELECT
         3 AS window_days
        ,COUNT(*)                                                  AS obs_cnt
        ,SUM(y_fpd3_ovd_cnt)                                       AS bad_cnt
        ,SUM(real_amount)                                          AS total_amt
        ,SUM(CASE WHEN y_fpd3_ovd_cnt = 1 THEN real_amount ELSE 0 END) AS bad_amt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 3) < obs_dt
    UNION ALL
    SELECT
         7
        ,COUNT(*)
        ,SUM(y_fpd7_ovd_cnt)
        ,SUM(real_amount)
        ,SUM(CASE WHEN y_fpd7_ovd_cnt = 1 THEN real_amount ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 7) < obs_dt
    UNION ALL
    SELECT
         14
        ,COUNT(*)
        ,SUM(y_fpd14_ovd_cnt)
        ,SUM(real_amount)
        ,SUM(CASE WHEN y_fpd14_ovd_cnt = 1 THEN real_amount ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 14) < obs_dt
    UNION ALL
    SELECT
         15
        ,COUNT(*)
        ,SUM(y_fpd15_ovd_cnt)
        ,SUM(real_amount)
        ,SUM(CASE WHEN y_fpd15_ovd_cnt = 1 THEN real_amount ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 15) < obs_dt
    UNION ALL
    SELECT
         30
        ,COUNT(*)
        ,SUM(y_fpd30_ovd_cnt)
        ,SUM(real_amount)
        ,SUM(CASE WHEN y_fpd30_ovd_cnt = 1 THEN real_amount ELSE 0 END)
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
),
stat AS (
    SELECT
         window_days
        ,obs_cnt
        ,bad_cnt
        ,CAST(bad_cnt AS DOUBLE) / obs_cnt                      AS bad_rate
        ,bad_amt
        ,total_amt
        ,bad_amt / NULLIF(total_amt, 0)                          AS bad_rate_amt
    FROM win
)
SELECT
     window_days
    ,obs_cnt
    ,bad_cnt
    ,ROUND(bad_rate, 4)                                         AS bad_rate
    ,ROUND((bad_rate + 1.96 * 1.96 / (2.0 * obs_cnt)
            - 1.96 * SQRT(bad_rate * (1 - bad_rate) / obs_cnt
                          + 1.96 * 1.96 / (4.0 * obs_cnt * obs_cnt)))
           / (1 + 1.96 * 1.96 / obs_cnt), 4)                    AS bad_rate_ci_low
    ,ROUND((bad_rate + 1.96 * 1.96 / (2.0 * obs_cnt)
            + 1.96 * SQRT(bad_rate * (1 - bad_rate) / obs_cnt
                          + 1.96 * 1.96 / (4.0 * obs_cnt * obs_cnt)))
           / (1 + 1.96 * 1.96 / obs_cnt), 4)                    AS bad_rate_ci_high
    ,ROUND(total_amt, 2)                                        AS total_amt
    ,ROUND(bad_amt, 2)                                          AS bad_amt
    ,ROUND(bad_rate_amt, 4)                                     AS bad_rate_amt
FROM stat
ORDER BY window_days
;


-- ============================================================
-- 块 2：个体级信息增量（固定 cohort 的两两 2x2 一致性）
-- 每个 pair 用长窗口的日历 cohort（due+长窗口 < obs_dt），保证两个标签都完全观察
-- bad_retention     = 短窗坏 且 长窗坏 / 短窗坏（多等几天仍坏的比例，越高说明短窗足够）
-- short_bad_cure    = 短窗坏 且 长窗好 / 短窗坏（短窗标签噪声 / 后来还清）
-- long_bad_miss     = 短窗好 且 长窗坏 / 短窗好（缩短窗口漏掉的风险）
-- phi               = 两个标签的相关系数（1 = 完全一致）
-- 最后一组是 FPD15 与“due+31 时累计 ever 5+”口径的对比，用于判断时点口径是否噪声过大
-- ============================================================
WITH pair_base AS (
    SELECT
         'FPD7_vs_FPD14' AS pair_name
        ,y_fpd7_ovd_cnt  AS short_bad
        ,y_fpd14_ovd_cnt AS long_bad
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 14) < obs_dt
    UNION ALL
    SELECT
         'FPD7_vs_FPD15'
        ,y_fpd7_ovd_cnt
        ,y_fpd15_ovd_cnt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 15) < obs_dt
    UNION ALL
    SELECT
         'FPD14_vs_FPD15'
        ,y_fpd14_ovd_cnt
        ,y_fpd15_ovd_cnt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 15) < obs_dt
    UNION ALL
    SELECT
         'FPD15_vs_FPD30'
        ,y_fpd15_ovd_cnt
        ,y_fpd30_ovd_cnt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
    UNION ALL
    SELECT
         'FPD14_vs_FPD30'
        ,y_fpd14_ovd_cnt
        ,y_fpd30_ovd_cnt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
    UNION ALL
    SELECT
         'FPD15_vs_EVER5PLUS_DUE31'
        ,y_fpd15_ovd_cnt
        ,CASE WHEN label_hist_overdue_days >= 5 THEN 1 ELSE 0 END
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 31) <= obs_dt
      AND label_hist_overdue_days IS NOT NULL
),
pair_stat AS (
    SELECT
         pair_name
        ,COUNT(*)                                                  AS obs_cnt
        ,SUM(CASE WHEN short_bad = 1 AND long_bad = 1 THEN 1 ELSE 0 END) AS both_bad
        ,SUM(CASE WHEN short_bad = 1 AND long_bad = 0 THEN 1 ELSE 0 END) AS only_short_bad
        ,SUM(CASE WHEN short_bad = 0 AND long_bad = 1 THEN 1 ELSE 0 END) AS only_long_bad
        ,SUM(CASE WHEN short_bad = 0 AND long_bad = 0 THEN 1 ELSE 0 END) AS both_good
        ,SUM(short_bad)                                            AS short_bad_cnt
        ,SUM(long_bad)                                             AS long_bad_cnt
    FROM pair_base
    GROUP BY pair_name
)
SELECT
     pair_name
    ,obs_cnt
    ,short_bad_cnt
    ,long_bad_cnt
    ,both_bad
    ,only_short_bad
    ,only_long_bad
    ,both_good
    ,ROUND(both_bad / NULLIF(short_bad_cnt, 0), 4)              AS bad_retention
    ,ROUND(only_short_bad / NULLIF(short_bad_cnt, 0), 4)       AS short_bad_cure_rate
    ,ROUND(only_long_bad / NULLIF(obs_cnt - short_bad_cnt, 0), 4) AS long_bad_miss_rate
    ,ROUND((CAST(both_bad AS DOUBLE) * both_good
            - CAST(only_short_bad AS DOUBLE) * only_long_bad)
           / NULLIF(SQRT(CAST(short_bad_cnt AS DOUBLE)
                         * (obs_cnt - short_bad_cnt)
                         * long_bad_cnt
                         * (obs_cnt - long_bad_cnt)), 0), 4)    AS phi
FROM pair_stat
ORDER BY pair_name
;


-- ============================================================
-- 块 3：固定 cohort 的逐窗口区分度（AUC / KS / Gini）
-- 同一批 due+30 < obs_dt 的日历 cohort 上分别打 FPD3/7/14/15/30 标签，横向可比
-- AUC 用 Mann-Whitney 秩和公式，同分取平均秩；KS 按分数升序累计好坏分布的最大差
-- ============================================================
WITH base AS (
    SELECT
         3 AS window_days
        ,y_fpd3_ovd_cnt AS label
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
    UNION ALL
    SELECT
         7
        ,y_fpd7_ovd_cnt
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
    UNION ALL
    SELECT
         14
        ,y_fpd14_ovd_cnt
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
    UNION ALL
    SELECT
         15
        ,y_fpd15_ovd_cnt
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
    UNION ALL
    SELECT
         30
        ,y_fpd30_ovd_cnt
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
),
ranked AS (
    SELECT
         window_days
        ,label
        ,RANK() OVER (PARTITION BY window_days ORDER BY score)     AS rk
        ,COUNT(*) OVER (PARTITION BY window_days, score)           AS tie_cnt
    FROM base
),
auc AS (
    SELECT
         window_days
        ,COUNT(*)                                                  AS obs_cnt
        ,SUM(label)                                                AS bad_cnt
        ,ROUND(AVG(label), 4)                                      AS bad_rate
        ,ROUND((SUM(CASE WHEN label = 1 THEN rk + (tie_cnt - 1) / 2.0 ELSE 0 END)
                - SUM(label) * (SUM(label) + 1) / 2.0)
               / NULLIF(SUM(label) * (COUNT(*) - SUM(label)), 0), 4) AS auc
    FROM ranked
    GROUP BY window_days
),
score_stat AS (
    SELECT
         window_days
        ,score
        ,SUM(label)                                                AS bad_at_score
        ,COUNT(*) - SUM(label)                                     AS good_at_score
    FROM base
    GROUP BY window_days, score
),
ks_stat AS (
    SELECT
         window_days
        ,SUM(bad_at_score) OVER (
             PARTITION BY window_days ORDER BY score
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)     AS cum_bad
        ,SUM(good_at_score) OVER (
             PARTITION BY window_days ORDER BY score
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)     AS cum_good
        ,SUM(bad_at_score) OVER (PARTITION BY window_days)         AS total_bad
        ,SUM(good_at_score) OVER (PARTITION BY window_days)        AS total_good
    FROM score_stat
),
ks AS (
    SELECT
         window_days
        ,ROUND(MAX(ABS(CAST(cum_bad AS DOUBLE) / NULLIF(total_bad, 0)
                      - CAST(cum_good AS DOUBLE) / NULLIF(total_good, 0))), 4) AS ks
    FROM ks_stat
    GROUP BY window_days
)
SELECT
     a.window_days
    ,a.obs_cnt
    ,a.bad_cnt
    ,a.bad_rate
    ,a.auc
    ,ROUND(2 * a.auc - 1, 4)                                    AS gini
    ,k.ks
FROM auc a
JOIN ks k
  ON a.window_days = k.window_days
ORDER BY a.window_days
;


-- ============================================================
-- 块 4：稳定性（分放款月 × 新老客的坏率；分放款月的 AUC）
-- 4.1 坏率：每个窗口用各自的日历 cohort（due+X < obs_dt）
-- ============================================================
WITH win AS (
    SELECT
         3 AS window_days
        ,disburse_month
        ,user_type
        ,y_fpd3_ovd_cnt AS label
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 3) < obs_dt
    UNION ALL
    SELECT
         7
        ,disburse_month
        ,user_type
        ,y_fpd7_ovd_cnt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 7) < obs_dt
    UNION ALL
    SELECT
         14
        ,disburse_month
        ,user_type
        ,y_fpd14_ovd_cnt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 14) < obs_dt
    UNION ALL
    SELECT
         15
        ,disburse_month
        ,user_type
        ,y_fpd15_ovd_cnt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 15) < obs_dt
    UNION ALL
    SELECT
         30
        ,disburse_month
        ,user_type
        ,y_fpd30_ovd_cnt
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
)
SELECT
     window_days
    ,disburse_month
    ,user_type
    ,COUNT(*)                                                  AS obs_cnt
    ,SUM(label)                                                AS bad_cnt
    ,ROUND(AVG(label), 4)                                      AS bad_rate
FROM win
GROUP BY window_days, disburse_month, user_type
ORDER BY window_days, disburse_month, user_type
;


-- ============================================================
-- 4.2 分放款月 AUC：每个窗口用各自的日历 cohort（样本小的月份 AUC 参考意义有限）
-- ============================================================
WITH base AS (
    SELECT
         disburse_month
        ,7 AS window_days
        ,y_fpd7_ovd_cnt AS label
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 AS score
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 7) < obs_dt
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
    UNION ALL
    SELECT
         disburse_month
        ,14
        ,y_fpd14_ovd_cnt
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 14) < obs_dt
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
    UNION ALL
    SELECT
         disburse_month
        ,15
        ,y_fpd15_ovd_cnt
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 15) < obs_dt
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
    UNION ALL
    SELECT
         disburse_month
        ,30
        ,y_fpd30_ovd_cnt
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE is_deal = 1
      AND init_due_date IS NOT NULL
      AND DATE_ADD(init_due_date, 30) < obs_dt
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
),
ranked AS (
    SELECT
         disburse_month
        ,window_days
        ,label
        ,RANK() OVER (PARTITION BY window_days, disburse_month ORDER BY score) AS rk
        ,COUNT(*) OVER (PARTITION BY window_days, disburse_month, score)       AS tie_cnt
    FROM base
)
SELECT
     disburse_month
    ,window_days
    ,COUNT(*)                                                  AS obs_cnt
    ,SUM(label)                                                AS bad_cnt
    ,ROUND(AVG(label), 4)                                      AS bad_rate
    ,ROUND((SUM(CASE WHEN label = 1 THEN rk + (tie_cnt - 1) / 2.0 ELSE 0 END)
            - SUM(label) * (SUM(label) + 1) / 2.0)
           / NULLIF(SUM(label) * (COUNT(*) - SUM(label)), 0), 4) AS auc
FROM ranked
GROUP BY disburse_month, window_days
ORDER BY disburse_month, window_days
;


-- ============================================================
-- 块 5：治愈率与最终风险对齐（FPD15 成熟且已到 due+31 的样本）
-- first_repaid_rate       ：FPD15 判坏但到 due+31 首期已实际还款的比例（时点口径噪声）
-- avg_first_repay_delay   ：首期实际还款距到期日的平均延迟天数
-- settled_rate            ：到 due+31 已无应还金额（owing_amount = 0）的比例
-- ever5plus_rate          ：到 due+31 为止曾出现 >=5 天逾期的比例（与 FPD15 时点口径对比）
-- ever30plus_rate         ：到 due+31 为止曾出现 >30 天逾期的比例（最终风险代理）
-- 注：label_debt_status 的 1/2 语义与 debt_status_desc 疑似不一致，治愈判断改用快照首期还款时间
-- ============================================================
WITH c AS (
    SELECT
         t.y_fpd15_ovd_cnt                                     AS fpd15_bad
        ,CASE WHEN s.first_repay_time IS NOT NULL THEN 1 ELSE 0 END AS first_repaid_by_due31
        ,CASE WHEN s.first_repay_time IS NOT NULL
              THEN DATEDIFF(TO_DATE(s.first_repay_time), t.init_due_date) END AS first_repay_delay_days
        ,CASE WHEN t.label_owing_amount <= 0 THEN 1 ELSE 0 END AS settled_by_owing
        ,CASE WHEN t.label_hist_overdue_days >= 5 THEN 1 ELSE 0 END  AS ever5plus
        ,CASE WHEN t.label_hist_overdue_days > 30 THEN 1 ELSE 0 END  AS ever30plus
        ,CASE WHEN t.label_current_overdue_days > 30 THEN 1 ELSE 0 END AS current30plus
        ,t.real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label t
    LEFT JOIN model.tmp_eliam_wagego_stg_debt_snp s
      ON t.listing_id = s.listing_id
     AND s.stat_date = t.label_obs_dt
    WHERE t.is_deal = 1
      AND t.init_due_date IS NOT NULL
      AND DATE_ADD(t.init_due_date, 31) <= t.obs_dt
      AND s.listing_id IS NOT NULL
)
SELECT
     fpd15_bad
    ,COUNT(*)                                                  AS obs_cnt
    ,SUM(first_repaid_by_due31)                                AS first_repaid_cnt
    ,ROUND(AVG(first_repaid_by_due31), 4)                      AS first_repaid_rate
    ,ROUND(AVG(first_repay_delay_days), 1)                     AS avg_first_repay_delay_days
    ,SUM(settled_by_owing)                                     AS settled_cnt
    ,ROUND(AVG(settled_by_owing), 4)                           AS settled_rate
    ,SUM(ever5plus)                                            AS ever5plus_cnt
    ,ROUND(AVG(ever5plus), 4)                                  AS ever5plus_rate
    ,SUM(ever30plus)                                           AS ever30plus_cnt
    ,ROUND(AVG(ever30plus), 4)                                 AS ever30plus_rate
    ,SUM(current30plus)                                        AS current30plus_cnt
    ,ROUND(AVG(current30plus), 4)                              AS current30plus_rate
    ,ROUND(SUM(real_amount), 2)                                AS total_amt
FROM c
GROUP BY fpd15_bad
ORDER BY fpd15_bad
;


-- 判读建议（结合块 1~5）：
--   1) FPD15 vs FPD30：bad_retention >= 0.95 且固定 cohort AUC 差 <= 0.01 → 取 FPD15
--   2) FPD14 vs FPD15：AUC 差 <= 0.005 且 phi >= 0.99 → 取 FPD14（早一天成熟、行业常规口径）
--   3) FPD15 坏样本 first_repaid_rate 偏高（如 > 0.5）→ 时点口径噪声大，改用 ever 5+ 口径，窗口仍锚 15 天
--   4) 分月坏率/AUC 漂移明显 → 先扩样本或分季度定案，不要用单月结论
--   5) 观察窗时效：FPD-X 在 due+X+1 天即可定论；若在意模型迭代速度，短窗口优势大于坏率曲线
