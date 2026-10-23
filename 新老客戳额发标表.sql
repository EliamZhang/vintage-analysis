SET spark.sql.session.timeZone = Australia/Sydney;

DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_samples AS
WITH first_disburse AS (
    SELECT
         a.user_id
        ,MIN(CAST(a.apply_disburse_time AS TIMESTAMP))        AS first_disburse_time
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
      AND a.status = 'DISBURSE_SUCCESS'
    GROUP BY a.user_id
),
credit AS (
    SELECT
         e.flow_id                                            AS flow_no
        ,e.user_id
        ,CAST(COALESCE(l.inserttime, e.inserttime) AS TIMESTAMP) AS credit_time
        ,l.limit_apply_no
        ,CASE WHEN l.flow_no IS NOT NULL THEN 'limit_apply' ELSE 'risk_event' END AS credit_source
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    LEFT JOIN ods_ewa.aus_listing_tb_loan_limit_apply l
      ON l.flow_no = e.flow_id
     AND CAST(l.isactive AS INT) = 1
     AND CAST(l.biz_type AS INT) = 400
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
credit_seq AS (
    SELECT
         s.*
        ,ROW_NUMBER() OVER (PARTITION BY s.user_id ORDER BY s.credit_time, s.flow_no) AS credit_seq
    FROM credit s
)
SELECT
     s.user_id
    ,s.limit_apply_no
    ,s.flow_no
    ,s.credit_time
    ,s.credit_source
    ,s.credit_seq
    ,f.first_disburse_time
FROM credit_seq s
LEFT JOIN first_disburse f
  ON s.user_id = f.user_id
WHERE f.first_disburse_time IS NULL
   OR s.credit_time <= f.first_disburse_time
;


DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_deal_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_deal_samples AS
WITH first_disburse AS (
    SELECT
         a.user_id
        ,MIN(CAST(a.apply_disburse_time AS TIMESTAMP))        AS first_disburse_time
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
      AND a.status = 'DISBURSE_SUCCESS'
    GROUP BY a.user_id
),
credit AS (
    SELECT
         e.flow_id                                            AS flow_no
        ,e.user_id
        ,CAST(COALESCE(l.inserttime, e.inserttime) AS TIMESTAMP) AS credit_time
        ,l.limit_apply_no
        ,CASE WHEN l.flow_no IS NOT NULL THEN 'limit_apply' ELSE 'risk_event' END AS credit_source
    FROM ods_ewa.aus_ewa_risk_risk_event_task e
    LEFT JOIN ods_ewa.aus_listing_tb_loan_limit_apply l
      ON l.flow_no = e.flow_id
     AND CAST(l.isactive AS INT) = 1
     AND CAST(l.biz_type AS INT) = 400
    WHERE CAST(e.is_active AS INT) = 1
      AND CAST(e.biz_id AS STRING) = '10000'
),
disbursed AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,CAST(a.inserttime AS TIMESTAMP)                      AS apply_time
        ,CAST(a.apply_disburse_time AS TIMESTAMP)             AS disburse_time
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
      AND a.status = 'DISBURSE_SUCCESS'
),
matched AS (
    SELECT
         d.loan_no
        ,d.user_id
        ,d.listing_id
        ,d.disburse_time
        ,s.flow_no
        ,s.limit_apply_no
        ,s.credit_time
        ,s.credit_source
        ,f.first_disburse_time
        ,ROW_NUMBER() OVER (
             PARTITION BY d.loan_no
             ORDER BY CASE WHEN s.credit_source = 'limit_apply' THEN 1 ELSE 2 END
                     ,s.credit_time DESC
                     ,s.flow_no DESC
         )                                                    AS loan_rn
    FROM disbursed d
    JOIN credit s
      ON d.user_id = s.user_id
     AND s.credit_time <= d.apply_time
    JOIN first_disburse f
      ON d.user_id = f.user_id
     AND s.credit_time <= f.first_disburse_time
),
credit_deal AS (
    SELECT
         m.*
        ,ROW_NUMBER() OVER (PARTITION BY m.flow_no ORDER BY m.disburse_time, m.loan_no) AS credit_rn
    FROM matched m
    WHERE m.loan_rn = 1
)
SELECT
     d.user_id
    ,d.limit_apply_no
    ,d.flow_no
    ,d.credit_time
    ,d.credit_source
    ,d.loan_no                                             AS deal_loan_no
    ,d.listing_id
    ,d.disburse_time
    ,CAST(l.real_amount AS DOUBLE)                         AS real_amount
    ,DATEDIFF(TO_DATE(d.disburse_time), TO_DATE(d.credit_time)) AS days_credit_to_disburse
FROM credit_deal d
LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
  ON d.listing_id = l.listing_id
WHERE d.credit_rn = 1
;


DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_bid_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_bid_samples AS
WITH first_disburse AS (
    SELECT
         a.user_id
        ,MIN(CAST(a.apply_disburse_time AS TIMESTAMP))        AS first_disburse_time
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
      AND a.status = 'DISBURSE_SUCCESS'
    GROUP BY a.user_id
),
apply AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,a.status
        ,CAST(a.inserttime AS TIMESTAMP)                      AS apply_time
        ,CAST(a.apply_disburse_time AS TIMESTAMP)             AS apply_disburse_time
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
),
typed AS (
    SELECT
         a.*
        ,f.first_disburse_time
        ,CASE WHEN f.first_disburse_time IS NULL THEN 'New'
              WHEN COALESCE(a.apply_disburse_time, a.apply_time) <= f.first_disburse_time THEN 'New'
              ELSE 'Old'
         END                                                  AS user_type
    FROM apply a
    LEFT JOIN first_disburse f
      ON a.user_id = f.user_id
)
SELECT
     a.loan_no
    ,a.user_id
    ,a.listing_id
    ,a.status                                                 AS apply_status
    ,CASE a.status
         WHEN 'DISBURSE_SUCCESS' THEN '放款成功'  WHEN 'DISBURSE'       THEN '放款中'
         WHEN 'DISBURSE_FAILED'  THEN '放款失败'  WHEN 'AUDIT'          THEN '审核中'
         WHEN 'AUDIT_APPROVED'   THEN '审核通过'  WHEN 'AUDIT_REJECTED' THEN '审核拒绝'
         WHEN 'EXPIRED'          THEN '已过期'    WHEN 'INFO_CHANGED'   THEN '信息变更'
         ELSE a.status
     END                                                      AS apply_status_desc
    ,CASE WHEN a.status = 'DISBURSE_SUCCESS' THEN 1 ELSE 0 END AS is_disburse_success
    ,a.apply_time
    ,TO_DATE(a.apply_time)                                    AS apply_date
    ,DATE_FORMAT(a.apply_time, 'yyyy-MM')                     AS apply_month
    ,CASE WHEN a.status = 'DISBURSE_SUCCESS' THEN a.apply_disburse_time END AS disburse_time
    ,CAST(l.apply_amount AS DOUBLE)                           AS apply_amount
    ,CAST(l.real_amount AS DOUBLE)                            AS real_amount
    ,CAST(l.term_quantity AS INT)                             AS term_quantity
    ,l.term_unit
    ,l.total_period
    ,CAST(l.bid_time AS TIMESTAMP)                            AS bid_time
    ,CAST(l.bid_status AS INT)                                AS bid_status
    ,CAST(l.is_deal AS INT)                                   AS is_deal
    ,CAST(l.full_bid_time AS TIMESTAMP)                       AS full_bid_time
    ,CAST(l.fail_bid_time AS TIMESTAMP)                       AS fail_bid_time
    ,CAST(l.withdraw_time AS TIMESTAMP)                       AS withdraw_time
    ,CAST(l.list_due_date AS DATE)                            AS list_due_date
    ,a.user_type
    ,a.first_disburse_time
FROM typed a
LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
  ON a.listing_id = l.listing_id
WHERE a.user_type = 'New'
;


DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_bid_success_samples;
CREATE TABLE model.tmp_eliam_wagego_new_user_bid_success_samples AS
SELECT *
FROM model.tmp_eliam_wagego_new_user_bid_samples
WHERE is_disburse_success = 1
;


DROP TABLE IF EXISTS model.tmp_eliam_wagego_old_user_bid_samples;
CREATE TABLE model.tmp_eliam_wagego_old_user_bid_samples AS
WITH first_disburse AS (
    SELECT
         a.user_id
        ,MIN(CAST(a.apply_disburse_time AS TIMESTAMP))        AS first_disburse_time
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
      AND a.status = 'DISBURSE_SUCCESS'
    GROUP BY a.user_id
),
apply AS (
    SELECT
         a.loan_no
        ,a.user_id
        ,a.listing_id
        ,a.status
        ,CAST(a.inserttime AS TIMESTAMP)                      AS apply_time
        ,CAST(a.apply_disburse_time AS TIMESTAMP)             AS apply_disburse_time
    FROM ods_ewa.aus_ewa_loan_biz_t_loan_application a
    WHERE CAST(a.isactive AS INT) = 1
),
typed AS (
    SELECT
         a.*
        ,f.first_disburse_time
        ,CASE WHEN f.first_disburse_time IS NULL THEN 'New'
              WHEN COALESCE(a.apply_disburse_time, a.apply_time) <= f.first_disburse_time THEN 'New'
              ELSE 'Old'
         END                                                  AS user_type
    FROM apply a
    LEFT JOIN first_disburse f
      ON a.user_id = f.user_id
)
SELECT
     a.loan_no
    ,a.user_id
    ,a.listing_id
    ,a.status                                                 AS apply_status
    ,CASE a.status
         WHEN 'DISBURSE_SUCCESS' THEN '放款成功'  WHEN 'DISBURSE'       THEN '放款中'
         WHEN 'DISBURSE_FAILED'  THEN '放款失败'  WHEN 'AUDIT'          THEN '审核中'
         WHEN 'AUDIT_APPROVED'   THEN '审核通过'  WHEN 'AUDIT_REJECTED' THEN '审核拒绝'
         WHEN 'EXPIRED'          THEN '已过期'    WHEN 'INFO_CHANGED'   THEN '信息变更'
         ELSE a.status
     END                                                      AS apply_status_desc
    ,CASE WHEN a.status = 'DISBURSE_SUCCESS' THEN 1 ELSE 0 END AS is_disburse_success
    ,a.apply_time
    ,TO_DATE(a.apply_time)                                    AS apply_date
    ,DATE_FORMAT(a.apply_time, 'yyyy-MM')                     AS apply_month
    ,CASE WHEN a.status = 'DISBURSE_SUCCESS' THEN a.apply_disburse_time END AS disburse_time
    ,CAST(l.apply_amount AS DOUBLE)                           AS apply_amount
    ,CAST(l.real_amount AS DOUBLE)                            AS real_amount
    ,CAST(l.term_quantity AS INT)                             AS term_quantity
    ,l.term_unit
    ,l.total_period
    ,CAST(l.bid_time AS TIMESTAMP)                            AS bid_time
    ,CAST(l.bid_status AS INT)                                AS bid_status
    ,CAST(l.is_deal AS INT)                                   AS is_deal
    ,CAST(l.full_bid_time AS TIMESTAMP)                       AS full_bid_time
    ,CAST(l.fail_bid_time AS TIMESTAMP)                       AS fail_bid_time
    ,CAST(l.withdraw_time AS TIMESTAMP)                       AS withdraw_time
    ,CAST(l.list_due_date AS DATE)                            AS list_due_date
    ,a.user_type
    ,a.first_disburse_time
FROM typed a
LEFT JOIN edw_ewa.dwb_asset_cmn_listing l
  ON a.listing_id = l.listing_id
WHERE a.user_type = 'Old'
;


DROP TABLE IF EXISTS model.tmp_eliam_wagego_old_user_bid_success_samples;
CREATE TABLE model.tmp_eliam_wagego_old_user_bid_success_samples AS
SELECT *
FROM model.tmp_eliam_wagego_old_user_bid_samples
WHERE is_disburse_success = 1
;

