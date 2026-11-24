-- WageGo 新客戳额模型分分析：模型效果评估所需的底表
-- 数据源：
--   1) Y 标签主表：放款申请、成交与 FPD 标签
--   2) 戳额成交样本的新模型分：aus_new_wagego_credit_20261028_v1_0_txn_lgb_score
--   3) 戳额生产打分全量样本的新模型分：wagego_new_user_credit_20260801_20261023_score
--   4) 戳额生产打分全量样本的线上旧模型分：按戳额流水从模型运行日志取
--   5) 戳额成交样本的决策策略类型：edw_ewa.dwd_risk_audit_credit_decision_dly（FT 标记）
--   6) 发标全量样本 + 新模型分：model.tmp_eliam_wagego_all_user_bid_score_20260801_20261106（新老客发标表现）
-- 说明：查询顺序与 sync_new_user_credit_analysis.py 的 QUERY_SPECS 一一对应；
--       输出文件名由 QUERY_SPECS 指定，供 build_new_user_credit_analysis.py 直接读取。
--       戳额生产打分全量不含标签，只用于新旧分数分布与档位迁移，不计算坏率 / AUC。


-- ============================================================
-- 块 1：Y 标签主表（build_new_user_credit_analysis.py --label-csv）
-- ============================================================
SELECT * FROM model.tmp_eliam_wagego_dwd_loan_apply_label;


-- ============================================================
-- 块 2：戳额成交样本的新模型分（build_new_user_credit_analysis.py --score-csv）
-- ============================================================
SELECT * FROM model.tmp_eliam_aus_new_wagego_credit_20261028_v1_0_txn_lgb_score;


-- ============================================================
-- 块 3：戳额生产打分全量样本的新模型分（build_new_user_credit_analysis.py --limit-score-csv）
-- ============================================================
SELECT * FROM model.tmp_eliam_aus_wagego_new_user_credit_20260801_20261023_score;


-- ============================================================
-- 块 4：戳额生产打分全量样本的线上旧模型分（build_new_user_credit_analysis.py --limit-old-score-csv）
-- 日志表同一 model_code 在戳额、发标两个时点都打日志；戳额时 scene_id = 戳额流水。
-- 同一 flow 多次调用取 start_time / inserttime 最新的一条。
-- ============================================================
SELECT
     t.scene_id                                                                                   AS flow_id
    ,CAST(GET_JSON_OBJECT(t.model_output, '$.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626') AS DOUBLE) AS old_score
FROM (
    SELECT
         r.scene_id
        ,r.model_output
        ,ROW_NUMBER() OVER (
            PARTITION BY r.scene_id
            ORDER BY CAST(r.start_time AS TIMESTAMP) DESC, CAST(r.inserttime AS TIMESTAMP) DESC
        ) AS rn
    FROM ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log r
    WHERE r.model_code = 'aus_wagego_new_risk_3rd_v1_0'
      AND r.scene_id IN (
          SELECT flow_id
          FROM model.tmp_eliam_aus_wagego_new_user_credit_20260801_20261023_score
      )
) t
WHERE t.rn = 1;


-- ============================================================
-- 块 5：戳额成交样本的决策策略类型（build_new_user_credit_analysis.py --strategy-csv）
-- 关联键：成交样本 last_limit_flow_id（授信侧风控决策流水）= 本表 flow_id
-- 同一 flow 若有多条决策记录，取 inserttime / updatetime 最新的一条
-- 不过滤 biz_id：flow_id 自带场景前缀，按流水关联即可；FT 判定在报告脚本里做
-- ============================================================
SELECT
     t.flow_id
    ,t.strategy_type
FROM (
    SELECT
         CAST(d.flow_id AS STRING)                                       AS flow_id
        ,d.strategy_type
        ,ROW_NUMBER() OVER (
            PARTITION BY d.flow_id
            ORDER BY CAST(d.inserttime AS TIMESTAMP) DESC
                    ,CAST(d.updatetime AS TIMESTAMP) DESC
                    ,CAST(d.flow_count AS INT) DESC
        )                                                                AS rn
    FROM edw_ewa.dwd_risk_audit_credit_decision_dly d
    WHERE d.flow_id IN (
        SELECT last_limit_flow_id
        FROM model.tmp_eliam_wagego_dwd_loan_apply_label
        WHERE application_rank = 1
          AND last_limit_flow_id IS NOT NULL
    )
) t
WHERE t.rn = 1;


-- ============================================================
-- 块 6：发标全量样本 + 新模型分（build_new_user_credit_analysis.py --bid-csv）
-- wagego_02 的新老客发标样本（含未成交申请）叠加新模型分；Y 只对放款成功申请成熟
-- ============================================================
SELECT * FROM model.tmp_eliam_wagego_all_user_bid_score_20260801_20261106;

