SET spark.sql.session.timeZone = Australia/Sydney;

-- 全历史样本：前 6 张与 wagego_02_新老客戳额发标表.sql 的 6 张样本表一一对应，
-- 仅去掉 2026-08-01 ~ 2026-10-23 的样本时间窗，供看板转化漏斗等滚动监控使用。
-- 后 2 张为不区分新老客的合并样本（新老客发标 / 新老客发标成交），口径同发标样本。
-- 表名后缀 _full_samples 表示全历史、不设起止时间窗。


-- 1. 新客戳额全历史样本：每个用户全历史第一次戳额申请（额度申请表优先，风控事件兜底）
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_full_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_full_samples AS
WITH credit AS (
    SELECT
         a.borrower_id                                        AS user_id
        ,CAST(a.inserttime AS TIMESTAMP)                      AS credit_time
        ,a.flow_no                                            AS flow_id
        ,1                                                    AS source_priority
    FROM ods_ewa.aus_listing_tb_loan_limit_apply a
    WHERE CAST(a.isactive AS INT) = 1
      AND CAST(a.biz_type AS INT) = 400
    UNION ALL
    SELECT
         e.user_id
        ,CAST(e.inserttime AS TIMESTAMP)
        ,e.flow_id
        ,2
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
ranked AS (
    SELECT
         user_id
        ,credit_time
        ,flow_id
        ,ROW_NUMBER() OVER (
             PARTITION BY user_id
             ORDER BY credit_time ASC NULLS LAST, source_priority, flow_id
         )                                                    AS rn
    FROM credit
)
SELECT
     user_id
    ,credit_time                                          AS sample_datetime
    ,flow_id
FROM ranked
WHERE rn = 1
;


-- 2. 新客戳额首笔成交全历史样本：每个用户第一次放款成功的记录及其之前最近一次戳额
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_deal_full_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_deal_full_samples AS
SELECT
     loan_no                                              AS deal_loan_no
    ,user_id
    ,listing_id
    ,disburse_time
    ,real_amount
    ,last_limit_time                                      AS sample_datetime
    ,last_limit_flow_id                                   AS flow_id
    ,DATEDIFF(TO_DATE(disburse_time), TO_DATE(last_limit_time)) AS days_credit_to_disburse
    ,disburse_month AS sample_month
    ,disburse_quarter AS sample_quarter
    ,disburse_week AS sample_week
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
;


-- 3. 新客发标全历史样本：首笔放款及之前的全部借款申请（含从未放款用户）
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_bid_full_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_bid_full_samples AS
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
    ,disburse_month AS sample_month
    ,disburse_quarter AS sample_quarter
    ,disburse_week AS sample_week
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
;


-- 4. 新客发标成交全历史样本：新客发标中放款成功的申请
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_bid_success_full_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_bid_success_full_samples AS
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
    ,disburse_month AS sample_month
    ,disburse_quarter AS sample_quarter
    ,disburse_week AS sample_week
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
;


-- 5. 老客发标全历史样本：首笔放款之后的全部借款申请
DROP TABLE IF EXISTS model.tmp_eliam_wagego_old_user_bid_full_samples;
CREATE TABLE model.tmp_eliam_wagego_old_user_bid_full_samples AS
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
    ,disburse_month AS sample_month
    ,disburse_quarter AS sample_quarter
    ,disburse_week AS sample_week
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
;


-- 6. 老客发标成交全历史样本：老客发标中放款成功的申请
DROP TABLE IF EXISTS model.tmp_eliam_wagego_old_user_bid_success_full_samples;
CREATE TABLE model.tmp_eliam_wagego_old_user_bid_success_full_samples AS
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
    ,disburse_month AS sample_month
    ,disburse_quarter AS sample_quarter
    ,disburse_week AS sample_week
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
;


-- 7. 新老客发标全历史样本：不区分新老客的全部借款申请（不一定成交）
DROP TABLE IF EXISTS model.tmp_eliam_wagego_all_user_bid_full_samples;
CREATE TABLE model.tmp_eliam_wagego_all_user_bid_full_samples AS
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
    ,disburse_month AS sample_month
    ,disburse_quarter AS sample_quarter
    ,disburse_week AS sample_week
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
;


-- 8. 新老客发标成交全历史样本：不区分新老客、放款成功的借款申请
DROP TABLE IF EXISTS model.tmp_eliam_wagego_all_user_bid_success_full_samples;
CREATE TABLE model.tmp_eliam_wagego_all_user_bid_success_full_samples AS
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
    ,disburse_month AS sample_month
    ,disburse_quarter AS sample_quarter
    ,disburse_week AS sample_week
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
WHERE is_disburse_success = 1
;
