SET spark.sql.session.timeZone = Australia/Sydney;

-- 样本：model.tmp_eliam_wagego_new_user_credit_20260801_20261023_samples（每个用户第一次戳额申请）
-- 数据源：ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log.model_input
-- 关联键：样本 flow_id = 日志 scene_id
-- 模型：model_code = aus_wagego_new_risk_3rd_v1_0（其 model_input 带银行流水明细）
-- 去重：同一 flow_id 可能多次调用模型，统一取 inserttime 最新的一次
-- 说明：model_input 里的 raw_transactions、day_end_balances 分别展开成流水、余额两张中间表；
--       银行卡信息直接拼在流水表上；数组为空则该样本不产出记录


-- 银行流水明细：一行一笔交易，拼上对应银行卡的信息，金额保留原始正负号
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_20260801_20261023_variable_illion_transaction_middle;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_20260801_20261023_variable_illion_transaction_middle AS
WITH sample AS (
    SELECT
         flow_id
        ,user_id
        ,sample_datetime
    FROM model.tmp_eliam_wagego_new_user_credit_20260801_20261023_samples
),
latest_log AS (
    SELECT
         scene_id
        ,model_input
        ,log_time
    FROM (
        SELECT
             scene_id
            ,model_input
            ,CAST(inserttime AS TIMESTAMP)                    AS log_time
            ,ROW_NUMBER() OVER (
                PARTITION BY scene_id
                ORDER BY CAST(inserttime AS TIMESTAMP) DESC
            )                                                 AS rn
        FROM ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log
        WHERE model_code = 'aus_wagego_new_risk_3rd_v1_0'
          AND scene_id IN (SELECT flow_id FROM sample)
    ) t
    WHERE rn = 1
),
txn AS (
    SELECT
         l.scene_id
        ,l.log_time
        ,trx.transaction_date
        ,trx.bank_account_number
        ,trx.institution
        ,trx.amount
        ,trx.dr_cr
        ,trx.balance
        ,trx.trx_type
        ,trx.category
        ,trx.secondary_category
        ,trx.third_party
        ,trx.text
    FROM latest_log l
    LATERAL VIEW EXPLODE(
        FROM_JSON(
            GET_JSON_OBJECT(l.model_input, '$.raw_transactions')
            ,'ARRAY<STRUCT<secondary_category:STRING,transaction_date:STRING,institution:STRING,amount:DOUBLE,bank_account_number:STRING,balance:DOUBLE,dr_cr:STRING,trx_type:STRING,text:STRING,category:STRING,third_party:STRING>>'
        )
    ) t AS trx
),
account AS (
    SELECT DISTINCT
         l.scene_id
        ,acc.account_number
        ,acc.institution
        ,acc.bsb
        ,acc.account_type
        ,acc.account_holder
        ,acc.account_holder_type
        ,acc.account_name
    FROM latest_log l
    LATERAL VIEW EXPLODE(
        FROM_JSON(
            GET_JSON_OBJECT(l.model_input, '$.bank_accounts')
            ,'ARRAY<STRUCT<bsb:STRING,account_number:STRING,institution:STRING,account_type:STRING,account_holder:STRING,account_holder_type:STRING,account_name:STRING>>'
        )
    ) t AS acc
)
SELECT
     s.flow_id
    ,s.user_id
    ,s.sample_datetime
    ,txn.log_time
    ,TO_DATE(txn.transaction_date)                        AS transaction_date
    ,txn.bank_account_number
    ,txn.institution
    ,txn.amount
    ,txn.dr_cr
    ,txn.balance
    ,txn.trx_type
    ,txn.category
    ,txn.secondary_category
    ,txn.third_party
    ,txn.text
    ,acc.bsb
    ,acc.account_type
    ,acc.account_holder
    ,acc.account_holder_type
    ,acc.account_name
FROM sample s
INNER JOIN txn
    ON s.flow_id = txn.scene_id
LEFT JOIN account acc
    ON txn.scene_id = acc.scene_id
   AND txn.bank_account_number = acc.account_number
   AND txn.institution = acc.institution
;


-- 银行卡余额：一行一张卡一天的日终余额
DROP TABLE IF EXISTS model.tmp_eliam_wagego_new_user_credit_20260801_20261023_balance_time_series_middle;
CREATE TABLE model.tmp_eliam_wagego_new_user_credit_20260801_20261023_balance_time_series_middle AS
WITH sample AS (
    SELECT
         flow_id
        ,user_id
        ,sample_datetime
    FROM model.tmp_eliam_wagego_new_user_credit_20260801_20261023_samples
),
latest_log AS (
    SELECT
         scene_id
        ,model_input
        ,log_time
    FROM (
        SELECT
             scene_id
            ,model_input
            ,CAST(inserttime AS TIMESTAMP)                    AS log_time
            ,ROW_NUMBER() OVER (
                PARTITION BY scene_id
                ORDER BY CAST(inserttime AS TIMESTAMP) DESC
            )                                                 AS rn
        FROM ods_ewa.aus_cbd_gidp_core_ewa_gidp_model_run_log
        WHERE model_code = 'aus_wagego_new_risk_3rd_v1_0'
          AND scene_id IN (SELECT flow_id FROM sample)
    ) t
    WHERE rn = 1
)
SELECT
     s.flow_id
    ,s.user_id
    ,s.sample_datetime
    ,l.log_time
    ,TO_DATE(bal.balance_date)                            AS balance_date
    ,bal.bank_account_number
    ,bal.institution
    ,bal.balance
FROM sample s
INNER JOIN latest_log l
    ON s.flow_id = l.scene_id
LATERAL VIEW EXPLODE(
    FROM_JSON(
        GET_JSON_OBJECT(l.model_input, '$.day_end_balances')
        ,'ARRAY<STRUCT<balance_date:STRING,institution:STRING,bank_account_number:STRING,balance:DOUBLE>>'
    )
) t AS bal
;
