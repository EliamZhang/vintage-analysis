-- WageGo 新老客发标模型分分析：模型效果评估所需的底表
-- 独立于 wagego_05（新客戳额模型分分析）：本文件只服务新老客发标模型评估
-- 数据源：
--   1) 发标全量样本（wagego_02 的 all_user_bid，含未成交申请）叠加新发标模型分；
--      Y 标签 y_fpd7_ovd / y_fpd15_ovd 只对放款成功的申请成熟
-- 说明：查询顺序与 sync_bid_model_analysis.py 的 QUERY_SPECS 一一对应；
--       输出文件名由 QUERY_SPECS 指定，供 build_bid_model_analysis.py 直接读取。


-- ============================================================
-- 块 1：发标全量样本 + 新发标模型分（build_bid_model_analysis.py --sample-csv）
-- 模型分列：aus_wagego_bid_20261123_v1_0_txn_lgb_score
-- 样本列：user_id / sample_datetime / flow_id / user_type / sample_month / sample_quarter
-- ============================================================
SELECT * FROM model.tmp_eliam_wagego_all_user_bid_v1_0_txn_lgb_20260801_20261116;
