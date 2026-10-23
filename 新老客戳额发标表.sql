SET spark.sql.session.timeZone = Australia/Sydney;

-- 新客首笔申请样本：每个用户的第一条借款申请（无论成败）及其申请前最近一次戳额
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_samples AS
SELECT
     loan_no
    ,user_id
    ,listing_id
    ,apply_status
    ,apply_status_desc
    ,is_disburse_success
    ,apply_time
    ,disburse_time
    ,last_limit_time                                      AS credit_time
    ,last_limit_flow_id                                   AS credit_flow_id
    ,first_disburse_time
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE apply_seq = 1
;


-- 新客首笔成交样本：每个用户第一次放款成功的记录及其之前最近一次戳额
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_deal_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_deal_samples AS
SELECT
     loan_no                                              AS deal_loan_no
    ,user_id
    ,listing_id
    ,disburse_time
    ,real_amount
    ,last_limit_time                                      AS credit_time
    ,last_limit_flow_id                                   AS credit_flow_id
    ,DATEDIFF(TO_DATE(disburse_time), TO_DATE(last_limit_time)) AS days_credit_to_disburse
    ,first_disburse_time
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE application_rank = 1
;


-- 新客发标样本：首笔放款及之前的全部借款申请（含从未放款用户）
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_bid_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_bid_samples AS
SELECT
     loan_no
    ,user_id
    ,listing_id
    ,apply_status
    ,apply_status_desc
    ,is_disburse_success
    ,apply_time
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
    ,user_type
    ,first_disburse_time
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE user_type = 'New'
;


-- 新客发标成交样本：新客发标中放款成功的申请
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_bid_success_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_bid_success_samples AS
SELECT *
FROM model.tmp_eliam_wagego_new_user_bid_samples
WHERE is_disburse_success = 1
;


-- 老客发标样本：首笔放款之后的全部借款申请
DROP TABLE IF EXISTS model.tmp_eliam_wagego_old_user_bid_samples;
CREATE TABLE model.tmp_eliam_wagego_old_user_bid_samples AS
SELECT
     loan_no
    ,user_id
    ,listing_id
    ,apply_status
    ,apply_status_desc
    ,is_disburse_success
    ,apply_time
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
    ,user_type
    ,first_disburse_time
FROM model.tmp_eliam_wagego_dwd_loan_apply_label
WHERE user_type = 'Old'
;


-- 老客发标成交样本：老客发标中放款成功的申请
DROP TABLE IF EXISTS model.tmp_eliam_wagego_old_user_bid_success_samples;
CREATE TABLE model.tmp_eliam_wagego_old_user_bid_success_samples AS
SELECT *
FROM model.tmp_eliam_wagego_old_user_bid_samples
WHERE is_disburse_success = 1
;
