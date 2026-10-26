-- ============================================================
-- 1. 新客样本表
-- 时间范围：2026-09-01 ~ 2026-09-30
-- ============================================================

DROP TABLE IF EXISTS model.tmp_eliam_new_apply_v1_1_260901_260930_samples;
CREATE TABLE model.tmp_eliam_new_apply_v1_1_260901_260930_samples AS
WITH base_sample AS (
    SELECT
        a.*
    FROM model.tmp_eliam_user_application_all a
    INNER JOIN ods.aus_fundo_loans_loan_applications b
        ON a.application_id = b.id
    WHERE a.user_type = 'New'
      AND CAST(a.sample_datetime AS DATE) >= DATE '2026-09-01'
      AND CAST(a.sample_datetime AS DATE) <= DATE '2026-09-30'
)

SELECT
    a.user_id,
    a.application_id,
    date_format(
        CAST(a.sample_datetime AS TIMESTAMP),
        'yyyy-MM-dd HH:mm:ss'
    ) AS sample_datetime,
    date_format(
        CAST(a.sample_datetime AS TIMESTAMP),
        'yyyy-MM'
    ) AS sample_month,
    concat(
        year(CAST(a.sample_datetime AS TIMESTAMP)),
        '-Q',
        quarter(CAST(a.sample_datetime AS TIMESTAMP))
    ) AS sample_quarter,
    a.user_type,
    b.duedate_1m_5,
    b.duedate_2m_5,
    b.duedate_1m_30,
    b.duedate_3m_30,
    b.duedate_4m_30
FROM base_sample a
LEFT JOIN model.tmp_eliam_listing_vintage b
    ON a.application_id = b.application_id
;


-- ============================================================
-- 2. 银行流水交易明细
-- ============================================================

DROP TABLE IF EXISTS model.tmp_eliam_new_apply_v1_1_260901_260930_variable_illion_transaction_middle;
CREATE TABLE model.tmp_eliam_new_apply_v1_1_260901_260930_variable_illion_transaction_middle AS

WITH bank_account_detail AS (
    SELECT
        id AS bank_account_id,
        account_type,
        bank,
        credit_limit
    FROM ods.fundo_illion_data_bank_account_details_view
),

sp AS (
    SELECT
        sp.user_id,
        sp.sample_datetime,
        sp.application_id,
        t1.id AS job_id,
        t1.job_started_at,
        ROW_NUMBER() OVER (
            PARTITION BY sp.user_id, sp.sample_datetime
            ORDER BY t1.job_started_at
        ) AS job_rk
    FROM (
        SELECT
            user_id,
            sample_datetime,
            application_id
        FROM model.tmp_eliam_new_apply_v1_1_260901_260930_samples
    ) sp
    INNER JOIN ods.fundo_illion_data_illion_data_processing t1
        ON sp.application_id = t1.application_id
       AND t1.status = 'completed'
),

t2 AS (
    SELECT *
    FROM ods.fundo_illion_data_raw_transactions_backup_2025_07_26

    UNION ALL

    SELECT *
    FROM ods.fundo_illion_data_raw_transactions
)

SELECT
    sp.user_id,
    sp.sample_datetime,
    sp.application_id,
    sp.job_id,
    t2.id AS transaction_id,
    t2.bank_account_id,
    bad.account_type,
    bad.bank,
    bad.credit_limit,
    t2.date AS transaction_date,
    ABS(CAST(t2.amount AS DOUBLE)) AS amount,
    t2.trx_type,
    t2.dr_cr,
    t2.category,
    t2.third_party,
    t2.illion_trx_uuid,
    t2.balance,
    t2.text
FROM sp
INNER JOIN t2
    ON sp.job_id = t2.job_id
LEFT JOIN bank_account_detail bad
    ON t2.bank_account_id = bad.bank_account_id
WHERE sp.job_rk = 1
;


-- ============================================================
-- 3. 银行流水余额时序
-- ============================================================

DROP TABLE IF EXISTS model.tmp_eliam_new_apply_v1_1_260901_260930_balance_time_series_middle;
CREATE TABLE model.tmp_eliam_new_apply_v1_1_260901_260930_balance_time_series_middle AS

WITH sample AS (
    SELECT
        CAST(user_id AS STRING) AS user_id,
        CAST(application_id AS STRING) AS application_id,
        CAST(sample_datetime AS TIMESTAMP) AS sample_datetime
    FROM model.tmp_eliam_new_apply_v1_1_260901_260930_samples
),

process AS (
    SELECT
        CAST(id AS STRING) AS job_id,
        CAST(application_id AS STRING) AS application_id,
        CAST(job_started_at AS TIMESTAMP) AS job_started_at
    FROM ods.fundo_illion_data_illion_data_processing
    WHERE status = 'completed'
),

joined AS (
    SELECT
        s.user_id,
        s.application_id,
        s.sample_datetime,
        p.job_id,
        p.job_started_at,
        UNIX_TIMESTAMP(p.job_started_at)
            - UNIX_TIMESTAMP(s.sample_datetime) AS dt_diff_sec,
        CASE
            WHEN p.job_started_at IS NULL THEN 1
            ELSE 0
        END AS nan_flag
    FROM sample s
    LEFT JOIN process p
        ON s.application_id = p.application_id
),

picked AS (
    SELECT
        user_id,
        application_id,
        sample_datetime,
        job_id,
        job_started_at
    FROM (
        SELECT
            j.*,
            ROW_NUMBER() OVER (
                PARTITION BY user_id, sample_datetime
                ORDER BY
                    nan_flag ASC,
                    CASE WHEN dt_diff_sec >= 0 THEN 0 ELSE 1 END ASC,
                    ABS(dt_diff_sec) ASC,
                    job_started_at ASC
            ) AS rk
        FROM joined j
    ) t
    WHERE rk = 1
),

balances AS (
    SELECT
        CAST(id AS STRING) AS balance_id,
        CAST(job_id AS STRING) AS job_id,
        CAST(bank_account_id AS STRING) AS bank_account_id,
        CAST(balance_date AS TIMESTAMP) AS balance_date,
        CAST(balance AS DOUBLE) AS balance
    FROM ods.fundo_illion_data_day_end_balances
    WHERE CAST(job_id AS STRING) IN (
        SELECT DISTINCT job_id
        FROM picked
        WHERE job_id IS NOT NULL
    )
),

s_l_a_d AS (
    SELECT
        p.user_id,
        p.application_id,
        p.sample_datetime,
        p.job_id,
        p.job_started_at,
        b.balance_id,
        b.balance_date,
        b.balance,
        b.bank_account_id
    FROM picked p
    LEFT JOIN balances b
        ON p.job_id = b.job_id
),

avg_by_card AS (
    SELECT
        user_id,
        job_id,
        bank_account_id,
        AVG(balance) AS avg_balance,
        MAX(balance_date) AS max_balance_date
    FROM s_l_a_d
    GROUP BY
        user_id,
        job_id,
        bank_account_id
),

top_card_per_job AS (
    SELECT
        user_id,
        job_id,
        bank_account_id
    FROM (
        SELECT
            a.*,
            ROW_NUMBER() OVER (
                PARTITION BY user_id, job_id
                ORDER BY
                    avg_balance DESC,
                    max_balance_date DESC,
                    bank_account_id ASC
            ) AS rk
        FROM avg_by_card a
    ) t
    WHERE rk = 1
),

s_l_a_d_top AS (
    SELECT
        s.user_id,
        s.application_id,
        s.sample_datetime,
        s.job_id,
        s.job_started_at,
        s.balance_id,
        s.balance_date,
        s.balance,
        s.bank_account_id
    FROM s_l_a_d s
    LEFT JOIN top_card_per_job t
        ON s.user_id = t.user_id
       AND s.job_id = t.job_id
       AND s.bank_account_id = t.bank_account_id
)

SELECT *
FROM s_l_a_d_top
;