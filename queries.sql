/*
===============================================================================
WageGo Vintage 原始表取数 SQL
当前阶段：只查原始表，用于确认表结构、粒度和样例数据

已确认原生表（9 张，可直接用）：
  ODS:
    ods_ewa.aus_ewa_loan_biz_t_loan_application
    ods_ewa.aus_listing_tb_loan_limit_apply
    ods_ewa.aus_listing_tb_loan_user_limit_log
  EDW:
    edw_ewa.dwb_asset_cmn_listing
    edw_ewa.dwb_asset_debt_dtl_snp
    edw_ewa.dwd_risk_credit_application_dly
    edw_ewa.dwd_risk_audit_credit_decision_dly
    edw_ewa.dwd_risk_audit_loan_decision_dly
    edw_ewa.dwb_user_fst_conv_dtl

禁止作为数据源（研发确认加工表，3 张）：
    edw_ewa.dws_risk_credit_intake_dtl
    edw_ewa.ads_risk_loan_monitor_cube
    edw_ewa.ads_risk_credit_monitor_cube

说明：
- 每段以分号结尾，sync.py 会逐段执行，结果保存到 results/ 下的 CSV，并打包 results.zip。
- 本文件只查询原始表，不依赖 model.tmp_eliam_*。
- 段 7、8、14 的样例只取 WageGo 的 listing_id / user_id，避免混入其他产品。
- DESC / SHOW PARTITIONS 的结果也按普通结果集保存。
===============================================================================
*/


/*
1. 资产表结构
用途：确认 real_amount、is_deal 以及 listing_id 的字段类型
*/
DESC edw_ewa.dwb_asset_cmn_listing;


/*
2. 债务快照结构
用途：确认 init_due_date、user_actual_repay_time、hist_overdue_days、current_overdue_days、dt
*/
DESC edw_ewa.dwb_asset_debt_dtl_snp;


/*
3. 授信申请表结构
用途：确认 user_id、limit_apply_no、flow_no、is_complete_apply、inserttime
*/
DESC edw_ewa.dwd_risk_credit_application_dly;


/*
4. 授信决策表结构
用途：确认 flow_id、risk_level、model_score 等风控字段
*/
DESC edw_ewa.dwd_risk_audit_credit_decision_dly;


/*
5. 提款决策表结构
用途：确认 flow_id、risk_level、model_score 等风控字段
*/
DESC edw_ewa.dwd_risk_audit_loan_decision_dly;


/*
6. 新老客表结构
用途：确认 user_id、fst_withdraw_time、注册时间等字段
*/
DESC edw_ewa.dwb_user_fst_conv_dtl;


/*
7. 资产表样例（仅 WageGo 申请）
用途：看 real_amount、is_deal 的实际取值
*/
SELECT l.*
FROM edw_ewa.dwb_asset_cmn_listing l
JOIN (
    SELECT DISTINCT listing_id
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application
    WHERE CAST(isactive AS INT) = 1
      AND listing_id IS NOT NULL
      AND LOWER(TRIM(CAST(listing_id AS STRING))) NOT IN ('', 'null', 'none')
) a
  ON l.listing_id = a.listing_id
LIMIT 10;


/*
8. 债务快照样例（最新分区，仅 WageGo 申请）
用途：看应还日、实还时间、逾期天数的实际取值
*/
SELECT d.*
FROM edw_ewa.dwb_asset_debt_dtl_snp d
JOIN (
    SELECT DISTINCT listing_id
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application
    WHERE CAST(isactive AS INT) = 1
      AND listing_id IS NOT NULL
      AND LOWER(TRIM(CAST(listing_id AS STRING))) NOT IN ('', 'null', 'none')
) a
  ON d.listing_id = a.listing_id
WHERE d.dt = (SELECT MAX(dt) FROM edw_ewa.dwb_asset_debt_dtl_snp)
LIMIT 10;


/*
9. 资产表粒度：是否一个 listing_id 一行
判断：row_cnt = listing_cnt 时可以直接 join，不会放大行数
*/
SELECT COUNT(*)                                            AS row_cnt,
       COUNT(DISTINCT listing_id)                           AS listing_cnt,
       SUM(CASE WHEN listing_id IS NULL THEN 1 ELSE 0 END)  AS null_listing_cnt
FROM edw_ewa.dwb_asset_cmn_listing;


/*
10. 债务快照最新分区粒度：是否一个 listing_id 一行
判断：row_cnt = listing_cnt 时可以直接 join
*/
SELECT dt,
       COUNT(*)                                            AS row_cnt,
       COUNT(DISTINCT listing_id)                           AS listing_cnt,
       SUM(CASE WHEN listing_id IS NULL THEN 1 ELSE 0 END)  AS null_listing_cnt
FROM edw_ewa.dwb_asset_debt_dtl_snp
WHERE dt = (SELECT MAX(dt) FROM edw_ewa.dwb_asset_debt_dtl_snp)
GROUP BY dt;


/*
11. 债务快照分区列表
用途：确认可用日期范围，以及最新分区是否为当天
*/
SHOW PARTITIONS edw_ewa.dwb_asset_debt_dtl_snp;


/*
12. 资产表重复 listing_id 样例
判断：有结果说明一个 listing_id 多行，需要先定去重规则
*/
SELECT listing_id,
       COUNT(*) AS cnt
FROM edw_ewa.dwb_asset_cmn_listing
GROUP BY listing_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 20;


/*
13. 债务快照重复 listing_id 样例（最新分区）
判断：有结果说明一个 listing_id 多期债务，需要先定取哪一期
*/
SELECT listing_id,
       COUNT(*) AS cnt
FROM edw_ewa.dwb_asset_debt_dtl_snp
WHERE dt = (SELECT MAX(dt) FROM edw_ewa.dwb_asset_debt_dtl_snp)
GROUP BY listing_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 20;


/*
14. 新老客表样例（仅 WageGo 申请用户）
用途：看 fst_withdraw_time 等字段的实际取值
*/
SELECT d.*
FROM edw_ewa.dwb_user_fst_conv_dtl d
JOIN (
    SELECT DISTINCT user_id
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application
    WHERE CAST(isactive AS INT) = 1
) a
  ON d.user_id = a.user_id
LIMIT 10;
