-- WageGo 模型分分析：模型效果评估所需的底表
-- 数据源：
--   1) Y 标签主表：放款申请、成交与 FPD 标签
--   2) 戳额成交样本的新模型分：aus_new_wagego_credit_20261028_v1_0_txn_lgb_score
--   3) 戳额生产打分全量样本的新模型分：wagego_new_user_credit_20260801_20261023_score
-- 说明：查询顺序与 sync_model_analysis.py 的 QUERY_SPECS 一一对应；
--       输出文件名由 QUERY_SPECS 指定，供 build_model_compare.py 直接读取。
--       戳额生产打分全量不含标签，只用于分数分布，不参与 AUC / KS。


-- ============================================================
-- 块 1：Y 标签主表（build_model_compare.py --label-csv）
-- ============================================================
SELECT * FROM model.tmp_eliam_wagego_dwd_loan_apply_label;


-- ============================================================
-- 块 2：戳额成交样本的新模型分（build_model_compare.py --score-csv）
-- ============================================================
SELECT * FROM model.tmp_eliam_aus_new_wagego_credit_20261028_v1_0_txn_lgb_score;


-- ============================================================
-- 块 3：戳额生产打分全量样本的新模型分（build_model_compare.py --limit-score-csv）
-- ============================================================
SELECT * FROM model.tmp_eliam_aus_wagego_new_user_credit_20260801_20261023_score;

