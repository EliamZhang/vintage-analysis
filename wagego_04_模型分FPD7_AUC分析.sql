SET spark.sql.session.timeZone = Australia/Sydney;

-- 模型分 AUC 分析：现在模型分对 FPD7 违约标签的区分度
-- 数据源：model.tmp_eliam_wagego_dwd_loan_apply_label（主表）
-- 分数：aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626
-- 样本：y_fpd7_obs_cnt = 1（FPD7 已成熟）；标签：y_fpd7_ovd_cnt（1 = 逾期）
-- AUC：Mann-Whitney 秩和公式，同分取平均秩；分数越高越坏，若方向相反 AUC 会小于 0.5

WITH base AS (
    SELECT
         loan_no
        ,disburse_month
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626        AS score
        ,y_fpd7_ovd_cnt                                        AS label
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE y_fpd7_obs_cnt = 1
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
),
ranked AS (
    SELECT
         score
        ,label
        ,disburse_month
        ,RANK() OVER (ORDER BY score)                              AS rk_all
        ,COUNT(*) OVER (PARTITION BY score)                        AS tie_all
        ,RANK() OVER (PARTITION BY disburse_month ORDER BY score)  AS rk_month
        ,COUNT(*) OVER (PARTITION BY disburse_month, score)        AS tie_month
    FROM base
),
auc_all AS (
    SELECT
         'ALL'                                                AS dimension
        ,CAST(NULL AS STRING)                                 AS disburse_month
        ,COUNT(*)                                             AS obs_cnt
        ,SUM(label)                                           AS bad_cnt
        ,COUNT(*) - SUM(label)                                AS good_cnt
        ,ROUND(AVG(label), 4)                                 AS bad_rate
        ,ROUND(
            (SUM(CASE WHEN label = 1 THEN rk_all + (tie_all - 1) / 2.0 ELSE 0 END)
             - SUM(label) * (SUM(label) + 1) / 2.0)
            / NULLIF(SUM(label) * (COUNT(*) - SUM(label)), 0)
         , 4)                                                 AS auc
    FROM ranked
),
auc_month AS (
    SELECT
         'disburse_month'                                     AS dimension
        ,disburse_month
        ,COUNT(*)                                             AS obs_cnt
        ,SUM(label)                                           AS bad_cnt
        ,COUNT(*) - SUM(label)                                AS good_cnt
        ,ROUND(AVG(label), 4)                                 AS bad_rate
        ,ROUND(
            (SUM(CASE WHEN label = 1 THEN rk_month + (tie_month - 1) / 2.0 ELSE 0 END)
             - SUM(label) * (SUM(label) + 1) / 2.0)
            / NULLIF(SUM(label) * (COUNT(*) - SUM(label)), 0)
         , 4)                                                 AS auc
    FROM ranked
    GROUP BY disburse_month
)
SELECT * FROM auc_all
UNION ALL
SELECT * FROM auc_month
ORDER BY dimension, disburse_month
;


-- 模型分五等分 FPD7 风险与 lift（笔数 + 金额口径，拆分新老客，附 ALL 汇总）
-- 样本：y_fpd7_obs_cnt = 1；笔数标签 y_fpd7_ovd_cnt；金额标签 = 逾期样本的 real_amount（未逾期记 0）
-- 分桶在 user_type 内各自计算（各组桶边界不同）；桶 1 = 分数最低，桶 5 = 分数最高；同分可能被切到相邻桶
-- lift = 桶坏率 / 该组整体坏率；bad_share = 桶内坏样本占该组全部坏样本比例
WITH base AS (
    SELECT
         user_type
        ,aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626        AS score
        ,y_fpd7_ovd_cnt                                        AS label_cnt
        ,CASE WHEN y_fpd7_ovd_cnt = 1 THEN real_amount ELSE 0 END AS label_amt
        ,real_amount
    FROM model.tmp_eliam_wagego_dwd_loan_apply_label
    WHERE y_fpd7_obs_cnt = 1
      AND aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626 IS NOT NULL
),
base_all AS (
    SELECT
         user_type
        ,score
        ,label_cnt
        ,label_amt
        ,real_amount
    FROM base
    UNION ALL
    SELECT
         'ALL'                                                AS user_type
        ,score
        ,label_cnt
        ,label_amt
        ,real_amount
    FROM base
),
binned AS (
    SELECT
         user_type
        ,score
        ,label_cnt
        ,label_amt
        ,real_amount
        ,NTILE(5) OVER (PARTITION BY user_type ORDER BY score) AS score_bucket
    FROM base_all
),
bucket_stat AS (
    SELECT
         user_type
        ,score_bucket
        ,COUNT(*)                                             AS obs_cnt
        ,SUM(label_cnt)                                       AS bad_cnt
        ,COUNT(*) - SUM(label_cnt)                            AS good_cnt
        ,SUM(real_amount)                                     AS total_amt
        ,SUM(label_amt)                                       AS bad_amt
        ,MIN(score)                                           AS score_min
        ,MAX(score)                                           AS score_max
        ,ROUND(AVG(score), 2)                                 AS score_avg
        ,AVG(label_cnt)                                       AS bad_rate_cnt
        ,SUM(label_amt) / NULLIF(SUM(real_amount), 0)         AS bad_rate_amt
    FROM binned
    GROUP BY user_type, score_bucket
),
total AS (
    SELECT
         user_type
        ,COUNT(*)                                             AS total_obs
        ,SUM(label_cnt)                                       AS total_bad
        ,SUM(real_amount)                                     AS total_amt
        ,SUM(label_amt)                                       AS total_bad_amt
        ,AVG(label_cnt)                                       AS total_bad_rate_cnt
        ,SUM(label_amt) / NULLIF(SUM(real_amount), 0)         AS total_bad_rate_amt
    FROM binned
    GROUP BY user_type
)
SELECT
     s.user_type
    ,s.score_bucket
    ,s.score_min
    ,s.score_max
    ,s.score_avg
    ,s.obs_cnt
    ,s.bad_cnt
    ,s.good_cnt
    ,ROUND(s.total_amt, 2)                                    AS total_amt
    ,ROUND(s.bad_amt, 2)                                      AS bad_amt
    ,ROUND(s.bad_rate_cnt, 4)                                 AS bad_rate_cnt
    ,ROUND(s.bad_rate_cnt / NULLIF(t.total_bad_rate_cnt, 0), 2) AS lift_cnt
    ,ROUND(s.bad_cnt / NULLIF(t.total_bad, 0), 4)             AS bad_share_cnt
    ,ROUND(s.bad_rate_amt, 4)                                 AS bad_rate_amt
    ,ROUND(s.bad_rate_amt / NULLIF(t.total_bad_rate_amt, 0), 2) AS lift_amt
    ,ROUND(s.bad_amt / NULLIF(t.total_bad_amt, 0), 4)         AS bad_share_amt
    ,t.total_obs
    ,t.total_bad
    ,ROUND(t.total_bad_rate_cnt, 4)                           AS total_bad_rate_cnt
    ,ROUND(t.total_amt, 2)                                    AS group_total_amt
    ,ROUND(t.total_bad_amt, 2)                                AS group_bad_amt
    ,ROUND(t.total_bad_rate_amt, 4)                           AS total_bad_rate_amt
FROM bucket_stat s
JOIN total t
  ON s.user_type = t.user_type
ORDER BY s.user_type, s.score_bucket
;
