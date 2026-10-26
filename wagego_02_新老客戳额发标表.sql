SET spark.sql.session.timeZone = Australia/Sydney;

-- 样本时间窗：2026-08-01 至 2026-10-23（今天），表名中的 _20260801_20261023 对应此窗口
-- 新客戳额样本按戳额时间筛选，发标及发标成交样本按申请时间筛选
-- 事件时间列统一命名为 sample_datetime
-- 每个样本表末尾附带 19 个核心 y 标签，直接取自主表同名字段
-- 新老客标签 user_type 也直接取自主表

-- 新客戳额首笔申请样本：每个用户的第一条借款申请（无论成败）及其申请前最近一次戳额
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_20260801_20261023_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_20260801_20261023_samples AS
SELECT
     loan_no
    ,user_id
    ,listing_id
    ,apply_status
    ,apply_status_desc
    ,is_disburse_success
    ,apply_time
    ,disburse_time
    ,last_limit_time                                      AS sample_datetime
    ,last_limit_flow_id                                   AS flow_id
    ,disburse_month
    ,disburse_quarter
    ,user_type
    ,first_disburse_time
    ,y_fpd7_obs
    ,y_fpd7_ovd
    ,y_fpd15_obs
    ,y_fpd15_ovd
    ,y_mob1_obs
    ,y_mob1_5plus
    ,y_mob1_30plus
    ,y_mob1_ever_5plus
    ,y_mob1_ever_30plus
    ,y_mob2_obs
    ,y_mob2_5plus
    ,y_mob2_30plus
    ,y_mob2_ever_5plus
    ,y_mob2_ever_30plus
    ,y_mob3_obs
    ,y_mob3_5plus
    ,y_mob3_30plus
    ,y_mob3_ever_5plus
    ,y_mob3_ever_30plus
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE apply_seq = 1
  AND last_limit_time >= TO_DATE('2026-08-01')
  AND last_limit_time <  TO_DATE('2026-10-24')
;


-- 新客戳额首笔成交样本：每个用户第一次放款成功的记录及其之前最近一次戳额
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_deal_20260801_20261023_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_deal_20260801_20261023_samples AS
SELECT
     loan_no                                              AS deal_loan_no
    ,user_id
    ,listing_id
    ,disburse_time
    ,real_amount
    ,last_limit_time                                      AS sample_datetime
    ,last_limit_flow_id                                   AS flow_id
    ,DATEDIFF(TO_DATE(disburse_time), TO_DATE(last_limit_time)) AS days_credit_to_disburse
    ,disburse_month
    ,disburse_quarter
    ,user_type
    ,first_disburse_time
    ,y_fpd7_obs
    ,y_fpd7_ovd
    ,y_fpd15_obs
    ,y_fpd15_ovd
    ,y_mob1_obs
    ,y_mob1_5plus
    ,y_mob1_30plus
    ,y_mob1_ever_5plus
    ,y_mob1_ever_30plus
    ,y_mob2_obs
    ,y_mob2_5plus
    ,y_mob2_30plus
    ,y_mob2_ever_5plus
    ,y_mob2_ever_30plus
    ,y_mob3_obs
    ,y_mob3_5plus
    ,y_mob3_30plus
    ,y_mob3_ever_5plus
    ,y_mob3_ever_30plus
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE application_rank = 1
  AND last_limit_time >= TO_DATE('2026-08-01')
  AND last_limit_time <  TO_DATE('2026-10-24')
;


-- 新客发标样本：首笔放款及之前的全部借款申请（含从未放款用户）
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_bid_20260801_20261023_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_bid_20260801_20261023_samples AS
SELECT
     loan_no                                              AS flow_id
    ,user_id
    ,listing_id
    ,apply_status
    ,apply_status_desc
    ,is_disburse_success
    ,apply_time                                           AS sample_datetime
    ,apply_date
    ,apply_month
    ,disburse_time
    ,apply_amount
    ,real_amount
    ,term_quantity
    ,term_unit
    ,total_period
    ,bid_time
    ,bid_status
    ,is_deal
    ,full_bid_time
    ,fail_bid_time
    ,withdraw_time
    ,list_due_date
    ,disburse_month
    ,disburse_quarter
    ,user_type
    ,first_disburse_time
    ,y_fpd7_obs
    ,y_fpd7_ovd
    ,y_fpd15_obs
    ,y_fpd15_ovd
    ,y_mob1_obs
    ,y_mob1_5plus
    ,y_mob1_30plus
    ,y_mob1_ever_5plus
    ,y_mob1_ever_30plus
    ,y_mob2_obs
    ,y_mob2_5plus
    ,y_mob2_30plus
    ,y_mob2_ever_5plus
    ,y_mob2_ever_30plus
    ,y_mob3_obs
    ,y_mob3_5plus
    ,y_mob3_30plus
    ,y_mob3_ever_5plus
    ,y_mob3_ever_30plus
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE user_type = 'New'
  AND apply_date >= TO_DATE('2026-08-01')
  AND apply_date <  TO_DATE('2026-10-24')
;


-- 新客发标成交样本：新客发标中放款成功的申请（按申请时间筛选）
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_bid_success_20260801_20261023_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_bid_success_20260801_20261023_samples AS
SELECT
     loan_no                                              AS flow_id
    ,user_id
    ,listing_id
    ,apply_status
    ,apply_status_desc
    ,is_disburse_success
    ,apply_time                                           AS sample_datetime
    ,apply_date
    ,apply_month
    ,disburse_time
    ,apply_amount
    ,real_amount
    ,term_quantity
    ,term_unit
    ,total_period
    ,bid_time
    ,bid_status
    ,is_deal
    ,full_bid_time
    ,fail_bid_time
    ,withdraw_time
    ,list_due_date
    ,disburse_month
    ,disburse_quarter
    ,user_type
    ,first_disburse_time
    ,y_fpd7_obs
    ,y_fpd7_ovd
    ,y_fpd15_obs
    ,y_fpd15_ovd
    ,y_mob1_obs
    ,y_mob1_5plus
    ,y_mob1_30plus
    ,y_mob1_ever_5plus
    ,y_mob1_ever_30plus
    ,y_mob2_obs
    ,y_mob2_5plus
    ,y_mob2_30plus
    ,y_mob2_ever_5plus
    ,y_mob2_ever_30plus
    ,y_mob3_obs
    ,y_mob3_5plus
    ,y_mob3_30plus
    ,y_mob3_ever_5plus
    ,y_mob3_ever_30plus
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE user_type = 'New'
  AND is_disburse_success = 1
  AND apply_date >= TO_DATE('2026-08-01')
  AND apply_date <  TO_DATE('2026-10-24')
;


-- 老客发标样本：首笔放款之后的全部借款申请
DROP TABLE IF EXISTS model.tmp_eliam_wagego_old_user_bid_20260801_20261023_samples;
CREATE TABLE model.tmp_eliam_wagego_old_user_bid_20260801_20261023_samples AS
SELECT
     loan_no                                              AS flow_id
    ,user_id
    ,listing_id
    ,apply_status
    ,apply_status_desc
    ,is_disburse_success
    ,apply_time                                           AS sample_datetime
    ,apply_date
    ,apply_month
    ,disburse_time
    ,apply_amount
    ,real_amount
    ,term_quantity
    ,term_unit
    ,total_period
    ,bid_time
    ,bid_status
    ,is_deal
    ,full_bid_time
    ,fail_bid_time
    ,withdraw_time
    ,list_due_date
    ,disburse_month
    ,disburse_quarter
    ,user_type
    ,first_disburse_time
    ,y_fpd7_obs
    ,y_fpd7_ovd
    ,y_fpd15_obs
    ,y_fpd15_ovd
    ,y_mob1_obs
    ,y_mob1_5plus
    ,y_mob1_30plus
    ,y_mob1_ever_5plus
    ,y_mob1_ever_30plus
    ,y_mob2_obs
    ,y_mob2_5plus
    ,y_mob2_30plus
    ,y_mob2_ever_5plus
    ,y_mob2_ever_30plus
    ,y_mob3_obs
    ,y_mob3_5plus
    ,y_mob3_30plus
    ,y_mob3_ever_5plus
    ,y_mob3_ever_30plus
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE user_type = 'Old'
  AND apply_date >= TO_DATE('2026-08-01')
  AND apply_date <  TO_DATE('2026-10-24')
;


-- 老客发标成交样本：老客发标中放款成功的申请（按申请时间筛选）
DROP TABLE IF EXISTS model.tmp_eliam_wagego_old_user_bid_success_20260801_20261023_samples;
CREATE TABLE model.tmp_eliam_wagego_old_user_bid_success_20260801_20261023_samples AS
SELECT
     loan_no                                              AS flow_id
    ,user_id
    ,listing_id
    ,apply_status
    ,apply_status_desc
    ,is_disburse_success
    ,apply_time                                           AS sample_datetime
    ,apply_date
    ,apply_month
    ,disburse_time
    ,apply_amount
    ,real_amount
    ,term_quantity
    ,term_unit
    ,total_period
    ,bid_time
    ,bid_status
    ,is_deal
    ,full_bid_time
    ,fail_bid_time
    ,withdraw_time
    ,list_due_date
    ,disburse_month
    ,disburse_quarter
    ,user_type
    ,first_disburse_time
    ,y_fpd7_obs
    ,y_fpd7_ovd
    ,y_fpd15_obs
    ,y_fpd15_ovd
    ,y_mob1_obs
    ,y_mob1_5plus
    ,y_mob1_30plus
    ,y_mob1_ever_5plus
    ,y_mob1_ever_30plus
    ,y_mob2_obs
    ,y_mob2_5plus
    ,y_mob2_30plus
    ,y_mob2_ever_5plus
    ,y_mob2_ever_30plus
    ,y_mob3_obs
    ,y_mob3_5plus
    ,y_mob3_30plus
    ,y_mob3_ever_5plus
    ,y_mob3_ever_30plus
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE user_type = 'Old'
  AND is_disburse_success = 1
  AND apply_date >= TO_DATE('2026-08-01')
  AND apply_date <  TO_DATE('2026-10-24')
;
