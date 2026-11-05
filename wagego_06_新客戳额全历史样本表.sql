SET spark.sql.session.timeZone = Australia/Sydney;

-- 新客戳额全历史样本：每个用户全历史第一次戳额申请，不设起止时间窗
-- 与 wagego_02_新老客戳额发标表.sql 中的 tmp_eliam_wagego_new_user_credit_*_samples 口径一致，
-- 仅去掉 2026-08-01 ~ 2026-10-23 的样本时间窗，供看板转化漏斗等滚动监控使用。
-- 额度申请表优先（biz_type = 400），风控事件表兜底（biz_id = 10000）。
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
