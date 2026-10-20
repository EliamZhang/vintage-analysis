DROP TABLE IF EXISTS model.tmp_eliam_user_type;
CREATE TABLE model.tmp_eliam_user_type AS
WITH first_app AS (
    SELECT
        user_id,
        MIN(id) AS first_application_id,
        MIN(created_at) AS first_application_date
    FROM ods.aus_fundo_loans_loan_applications
    WHERE status IN ('Active_Account', 'Closed', 'Blocked')
    GROUP BY user_id
)
SELECT
    la.user_id AS user_id,
    la.id AS application_id,
    CASE 
        WHEN fa.first_application_id IS NOT NULL THEN 'Old'
        ELSE 'New'
    END AS user_type
FROM ods.aus_fundo_loans_loan_applications la
LEFT JOIN first_app fa
    ON la.user_id = fa.user_id
   AND fa.first_application_id < la.id
WHERE la.status IN ('Active_Account', 'Closed', 'Blocked');



-- STEP 1：vintage_dim_date（Spark3 版本）
----step1 vintage观察日期表
DROP TABLE IF EXISTS model.tmp_eliam_vintage_dim_date;

CREATE TABLE model.tmp_eliam_vintage_dim_date AS
SELECT 
    d_code AS dt

    -- ===== 1 Day =====
    , date_add(d_code,  1) AS duedate_1m_1_dt
    , date_add(d_code, 31) AS duedate_2m_1_dt
    , date_add(d_code, 61) AS duedate_3m_1_dt
    , date_add(d_code, 91) AS duedate_4m_1_dt
    , date_add(d_code,121) AS duedate_5m_1_dt
    , date_add(d_code,151) AS duedate_6m_1_dt
    , date_add(d_code,181) AS duedate_7m_1_dt
    , date_add(d_code,211) AS duedate_8m_1_dt
    , date_add(d_code,241) AS duedate_9m_1_dt
    , date_add(d_code,271) AS duedate_10m_1_dt
    , date_add(d_code,301) AS duedate_11m_1_dt
    , date_add(d_code,331) AS duedate_12m_1_dt

    -- ===== 5 Day =====
    , date_add(d_code,  5) AS duedate_1m_5_dt
    , date_add(d_code, 35) AS duedate_2m_5_dt
    , date_add(d_code, 65) AS duedate_3m_5_dt
    , date_add(d_code, 95) AS duedate_4m_5_dt
    , date_add(d_code,125) AS duedate_5m_5_dt
    , date_add(d_code,155) AS duedate_6m_5_dt
    , date_add(d_code,185) AS duedate_7m_5_dt
    , date_add(d_code,215) AS duedate_8m_5_dt
    , date_add(d_code,245) AS duedate_9m_5_dt
    , date_add(d_code,275) AS duedate_10m_5_dt
    , date_add(d_code,305) AS duedate_11m_5_dt
    , date_add(d_code,335) AS duedate_12m_5_dt

    -- ===== 10 Day =====
    , date_add(d_code, 10) AS duedate_1m_10_dt
    , date_add(d_code, 40) AS duedate_2m_10_dt
    , date_add(d_code, 70) AS duedate_3m_10_dt
    , date_add(d_code,100) AS duedate_4m_10_dt
    , date_add(d_code,130) AS duedate_5m_10_dt
    , date_add(d_code,160) AS duedate_6m_10_dt
    , date_add(d_code,190) AS duedate_7m_10_dt
    , date_add(d_code,220) AS duedate_8m_10_dt
    , date_add(d_code,250) AS duedate_9m_10_dt
    , date_add(d_code,280) AS duedate_10m_10_dt
    , date_add(d_code,310) AS duedate_11m_10_dt
    , date_add(d_code,340) AS duedate_12m_10_dt

    -- ===== 15 Day =====
    , date_add(d_code, 15) AS duedate_1m_15_dt
    , date_add(d_code, 45) AS duedate_2m_15_dt
    , date_add(d_code, 75) AS duedate_3m_15_dt
    , date_add(d_code,105) AS duedate_4m_15_dt
    , date_add(d_code,135) AS duedate_5m_15_dt
    , date_add(d_code,165) AS duedate_6m_15_dt
    , date_add(d_code,195) AS duedate_7m_15_dt
    , date_add(d_code,225) AS duedate_8m_15_dt
    , date_add(d_code,255) AS duedate_9m_15_dt
    , date_add(d_code,285) AS duedate_10m_15_dt
    , date_add(d_code,315) AS duedate_11m_15_dt
    , date_add(d_code,345) AS duedate_12m_15_dt

    -- ===== 30 Day =====
    , date_add(d_code, 30) AS duedate_1m_30_dt
    , date_add(d_code, 60) AS duedate_2m_30_dt
    , date_add(d_code, 90) AS duedate_3m_30_dt
    , date_add(d_code,120) AS duedate_4m_30_dt
    , date_add(d_code,150) AS duedate_5m_30_dt
    , date_add(d_code,180) AS duedate_6m_30_dt
    , date_add(d_code,210) AS duedate_7m_30_dt
    , date_add(d_code,240) AS duedate_8m_30_dt
    , date_add(d_code,270) AS duedate_9m_30_dt
    , date_add(d_code,300) AS duedate_10m_30_dt
    , date_add(d_code,330) AS duedate_11m_30_dt
    , date_add(d_code,360) AS duedate_12m_30_dt

    -- ===== 60 Day =====
    , date_add(d_code, 60) AS duedate_1m_60_dt
    , date_add(d_code, 90) AS duedate_2m_60_dt
    , date_add(d_code,120) AS duedate_3m_60_dt
    , date_add(d_code,150) AS duedate_4m_60_dt
    , date_add(d_code,180) AS duedate_5m_60_dt
    , date_add(d_code,210) AS duedate_6m_60_dt
    , date_add(d_code,240) AS duedate_7m_60_dt
    , date_add(d_code,270) AS duedate_8m_60_dt
    , date_add(d_code,300) AS duedate_9m_60_dt
    , date_add(d_code,330) AS duedate_10m_60_dt
    , date_add(d_code,360) AS duedate_11m_60_dt
    , date_add(d_code,390) AS duedate_12m_60_dt

FROM edw.dim_date;



-- step2 标的首个 due_date
DROP TABLE IF EXISTS model.tmp_eliam_listing_due_date;

CREATE TABLE model.tmp_eliam_listing_due_date AS
SELECT 
      sp.id AS application_id
    , sp.user_id
    , sp.dispersal_date
    , sp.created_at
    , sp.loan_term
    , sp.total_amount
    , sp.repayment_amount
    , sp.repayment_frequency
    , sp.total_loan_amount
    , sp.status
    , sp.first_payment_date
    , t2.schedule_id
    , t2.scheduled_date AS due_date
    , t2.schedule_cleared_date AS repayment_date
    , ROW_NUMBER() OVER (
          PARTITION BY sp.id 
          ORDER BY t2.schedule_id
      ) AS debt_seq_no
FROM ods.aus_fundo_loans_loan_applications sp
JOIN ods.vintage_analysis_original_schedule_recoveries_v2 t2 
     ON sp.id = t2.application_id
WHERE sp.status IN ('Active_Account', 'Closed', 'Blocked');


-- step: listing debt dpd days
DROP TABLE IF EXISTS model.tmp_eliam_listing_debt_dpd_days;

CREATE TABLE model.tmp_eliam_listing_debt_dpd_days AS
SELECT
      sp.application_id
    , sp.schedule_id
    , sp.debt_seq_no
    , to_date(sp.due_date)          AS due_date
    , to_date(t1.init_due_date)     AS init_due_date
    , to_date(sp.repayment_date)    AS repayment_date

    -- ======== +5 天目标日 =========
    , to_date(t2.duedate_1m_5_dt)   AS duedate_1m_5_dt
    , to_date(t2.duedate_2m_5_dt)   AS duedate_2m_5_dt
    , to_date(t2.duedate_3m_5_dt)   AS duedate_3m_5_dt
    , to_date(t2.duedate_4m_5_dt)   AS duedate_4m_5_dt
    , to_date(t2.duedate_5m_5_dt)   AS duedate_5m_5_dt
    , to_date(t2.duedate_6m_5_dt)   AS duedate_6m_5_dt
    , to_date(t2.duedate_7m_5_dt)   AS duedate_7m_5_dt
    , to_date(t2.duedate_8m_5_dt)   AS duedate_8m_5_dt
    , to_date(t2.duedate_9m_5_dt)   AS duedate_9m_5_dt
    , to_date(t2.duedate_10m_5_dt)  AS duedate_10m_5_dt
    , to_date(t2.duedate_11m_5_dt)  AS duedate_11m_5_dt
    , to_date(t2.duedate_12m_5_dt)  AS duedate_12m_5_dt

    -- ======== +30 天目标日 =========
    , to_date(t2.duedate_1m_30_dt)  AS duedate_1m_30_dt
    , to_date(t2.duedate_2m_30_dt)  AS duedate_2m_30_dt
    , to_date(t2.duedate_3m_30_dt)  AS duedate_3m_30_dt
    , to_date(t2.duedate_4m_30_dt)  AS duedate_4m_30_dt
    , to_date(t2.duedate_5m_30_dt)  AS duedate_5m_30_dt
    , to_date(t2.duedate_6m_30_dt)  AS duedate_6m_30_dt
    , to_date(t2.duedate_7m_30_dt)  AS duedate_7m_30_dt
    , to_date(t2.duedate_8m_30_dt)  AS duedate_8m_30_dt
    , to_date(t2.duedate_9m_30_dt)  AS duedate_9m_30_dt
    , to_date(t2.duedate_10m_30_dt) AS duedate_10m_30_dt
    , to_date(t2.duedate_11m_30_dt) AS duedate_11m_30_dt
    , to_date(t2.duedate_12m_30_dt) AS duedate_12m_30_dt

    -- ======== +60 天目标日 =========
    , to_date(t2.duedate_1m_60_dt)  AS duedate_1m_60_dt
    , to_date(t2.duedate_2m_60_dt)  AS duedate_2m_60_dt
    , to_date(t2.duedate_3m_60_dt)  AS duedate_3m_60_dt
    , to_date(t2.duedate_4m_60_dt)  AS duedate_4m_60_dt
    , to_date(t2.duedate_5m_60_dt)  AS duedate_5m_60_dt
    , to_date(t2.duedate_6m_60_dt)  AS duedate_6m_60_dt
    , to_date(t2.duedate_7m_60_dt)  AS duedate_7m_60_dt
    , to_date(t2.duedate_8m_60_dt)  AS duedate_8m_60_dt
    , to_date(t2.duedate_9m_60_dt)  AS duedate_9m_60_dt
    , to_date(t2.duedate_10m_60_dt) AS duedate_10m_60_dt
    , to_date(t2.duedate_11m_60_dt) AS duedate_11m_60_dt
    , to_date(t2.duedate_12m_60_dt) AS duedate_12m_60_dt

    -- =============== DPD +5 天 ==================
    , CASE WHEN t2.duedate_1m_5_dt  >  to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_1m_5_dt , coalesce(to_date(sp.repayment_date), t2.duedate_1m_5_dt)), to_date(sp.due_date)) END AS dpd_days_1m_5
    , CASE WHEN t2.duedate_2m_5_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_2m_5_dt , coalesce(to_date(sp.repayment_date), t2.duedate_2m_5_dt)), to_date(sp.due_date)) END AS dpd_days_2m_5
    , CASE WHEN t2.duedate_3m_5_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_3m_5_dt , coalesce(to_date(sp.repayment_date), t2.duedate_3m_5_dt)), to_date(sp.due_date)) END AS dpd_days_3m_5
    , CASE WHEN t2.duedate_4m_5_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_4m_5_dt , coalesce(to_date(sp.repayment_date), t2.duedate_4m_5_dt)), to_date(sp.due_date)) END AS dpd_days_4m_5
    , CASE WHEN t2.duedate_5m_5_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_5m_5_dt , coalesce(to_date(sp.repayment_date), t2.duedate_5m_5_dt)), to_date(sp.due_date)) END AS dpd_days_5m_5
    , CASE WHEN t2.duedate_6m_5_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_6m_5_dt , coalesce(to_date(sp.repayment_date), t2.duedate_6m_5_dt)), to_date(sp.due_date)) END AS dpd_days_6m_5
    , CASE WHEN t2.duedate_7m_5_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_7m_5_dt , coalesce(to_date(sp.repayment_date), t2.duedate_7m_5_dt)), to_date(sp.due_date)) END AS dpd_days_7m_5
    , CASE WHEN t2.duedate_8m_5_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_8m_5_dt , coalesce(to_date(sp.repayment_date), t2.duedate_8m_5_dt)), to_date(sp.due_date)) END AS dpd_days_8m_5
    , CASE WHEN t2.duedate_9m_5_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_9m_5_dt , coalesce(to_date(sp.repayment_date), t2.duedate_9m_5_dt)), to_date(sp.due_date)) END AS dpd_days_9m_5
    , CASE WHEN t2.duedate_10m_5_dt >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_10m_5_dt, coalesce(to_date(sp.repayment_date), t2.duedate_10m_5_dt)), to_date(sp.due_date)) END AS dpd_days_10m_5
    , CASE WHEN t2.duedate_11m_5_dt >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_11m_5_dt, coalesce(to_date(sp.repayment_date), t2.duedate_11m_5_dt)), to_date(sp.due_date)) END AS dpd_days_11m_5
    , CASE WHEN t2.duedate_12m_5_dt >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_12m_5_dt, coalesce(to_date(sp.repayment_date), t2.duedate_12m_5_dt)), to_date(sp.due_date)) END AS dpd_days_12m_5


    -- =============== DPD +30 天 ==================
    , CASE WHEN t2.duedate_1m_30_dt  >  to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_1m_30_dt , coalesce(to_date(sp.repayment_date), t2.duedate_1m_30_dt)), to_date(sp.due_date)) END AS dpd_days_1m_30
    , CASE WHEN t2.duedate_2m_30_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_2m_30_dt , coalesce(to_date(sp.repayment_date), t2.duedate_2m_30_dt)), to_date(sp.due_date)) END AS dpd_days_2m_30
    , CASE WHEN t2.duedate_3m_30_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_3m_30_dt , coalesce(to_date(sp.repayment_date), t2.duedate_3m_30_dt)), to_date(sp.due_date)) END AS dpd_days_3m_30
    , CASE WHEN t2.duedate_4m_30_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_4m_30_dt , coalesce(to_date(sp.repayment_date), t2.duedate_4m_30_dt)), to_date(sp.due_date)) END AS dpd_days_4m_30
    , CASE WHEN t2.duedate_5m_30_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_5m_30_dt , coalesce(to_date(sp.repayment_date), t2.duedate_5m_30_dt)), to_date(sp.due_date)) END AS dpd_days_5m_30
    , CASE WHEN t2.duedate_6m_30_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_6m_30_dt , coalesce(to_date(sp.repayment_date), t2.duedate_6m_30_dt)), to_date(sp.due_date)) END AS dpd_days_6m_30
    , CASE WHEN t2.duedate_7m_30_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_7m_30_dt , coalesce(to_date(sp.repayment_date), t2.duedate_7m_30_dt)), to_date(sp.due_date)) END AS dpd_days_7m_30
    , CASE WHEN t2.duedate_8m_30_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_8m_30_dt , coalesce(to_date(sp.repayment_date), t2.duedate_8m_30_dt)), to_date(sp.due_date)) END AS dpd_days_8m_30
    , CASE WHEN t2.duedate_9m_30_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_9m_30_dt , coalesce(to_date(sp.repayment_date), t2.duedate_9m_30_dt)), to_date(sp.due_date)) END AS dpd_days_9m_30
    , CASE WHEN t2.duedate_10m_30_dt >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_10m_30_dt, coalesce(to_date(sp.repayment_date), t2.duedate_10m_30_dt)), to_date(sp.due_date)) END AS dpd_days_10m_30
    , CASE WHEN t2.duedate_11m_30_dt >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_11m_30_dt, coalesce(to_date(sp.repayment_date), t2.duedate_11m_30_dt)), to_date(sp.due_date)) END AS dpd_days_11m_30
    , CASE WHEN t2.duedate_12m_30_dt >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_12m_30_dt, coalesce(to_date(sp.repayment_date), t2.duedate_12m_30_dt)), to_date(sp.due_date)) END AS dpd_days_12m_30


    -- =============== DPD +60 天 ==================
    , CASE WHEN t2.duedate_1m_60_dt  >  to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_1m_60_dt , coalesce(to_date(sp.repayment_date), t2.duedate_1m_60_dt)), to_date(sp.due_date)) END AS dpd_days_1m_60
    , CASE WHEN t2.duedate_2m_60_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_2m_60_dt , coalesce(to_date(sp.repayment_date), t2.duedate_2m_60_dt)), to_date(sp.due_date)) END AS dpd_days_2m_60
    , CASE WHEN t2.duedate_3m_60_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_3m_60_dt , coalesce(to_date(sp.repayment_date), t2.duedate_3m_60_dt)), to_date(sp.due_date)) END AS dpd_days_3m_60
    , CASE WHEN t2.duedate_4m_60_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_4m_60_dt , coalesce(to_date(sp.repayment_date), t2.duedate_4m_60_dt)), to_date(sp.due_date)) END AS dpd_days_4m_60
    , CASE WHEN t2.duedate_5m_60_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_5m_60_dt , coalesce(to_date(sp.repayment_date), t2.duedate_5m_60_dt)), to_date(sp.due_date)) END AS dpd_days_5m_60
    , CASE WHEN t2.duedate_6m_60_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_6m_60_dt , coalesce(to_date(sp.repayment_date), t2.duedate_6m_60_dt)), to_date(sp.due_date)) END AS dpd_days_6m_60
    , CASE WHEN t2.duedate_7m_60_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_7m_60_dt , coalesce(to_date(sp.repayment_date), t2.duedate_7m_60_dt)), to_date(sp.due_date)) END AS dpd_days_7m_60
    , CASE WHEN t2.duedate_8m_60_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_8m_60_dt , coalesce(to_date(sp.repayment_date), t2.duedate_8m_60_dt)), to_date(sp.due_date)) END AS dpd_days_8m_60
    , CASE WHEN t2.duedate_9m_60_dt  >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_9m_60_dt , coalesce(to_date(sp.repayment_date), t2.duedate_9m_60_dt)), to_date(sp.due_date)) END AS dpd_days_9m_60
    , CASE WHEN t2.duedate_10m_60_dt >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_10m_60_dt, coalesce(to_date(sp.repayment_date), t2.duedate_10m_60_dt)), to_date(sp.due_date)) END AS dpd_days_10m_60
    , CASE WHEN t2.duedate_11m_60_dt >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_11m_60_dt, coalesce(to_date(sp.repayment_date), t2.duedate_11m_60_dt)), to_date(sp.due_date)) END AS dpd_days_11m_60
    , CASE WHEN t2.duedate_12m_60_dt >= to_date(sp.repayment_date) THEN 0
           ELSE datediff(least(t2.duedate_12m_60_dt, coalesce(to_date(sp.repayment_date), t2.duedate_12m_60_dt)), to_date(sp.due_date)) END AS dpd_days_12m_60

FROM model.tmp_eliam_listing_due_date sp
LEFT JOIN (
    SELECT
        application_id,
        to_date(due_date) AS init_due_date
    FROM model.tmp_eliam_listing_due_date
    WHERE debt_seq_no = 1
) t1
ON sp.application_id = t1.application_id
LEFT JOIN model.tmp_eliam_vintage_dim_date t2
ON t1.init_due_date = t2.dt;

-- ============================
-- step4 聚合到 listing 维度
-- ============================

DROP TABLE IF EXISTS model.tmp_eliam_listing_vintage;
CREATE TABLE model.tmp_eliam_listing_vintage AS
SELECT
    sp.application_id,
    init_due_date,
    t1.user_id,
    t2.user_type,
    t1.dispersal_date,
    t1.created_at,
    t1.loan_term,
    t1.total_amount,
    t1.total_loan_amount,
    (t1.total_loan_amount - t1.total_amount)                                           AS total_fee,
    t1.init_fee,
    (t1.total_loan_amount - t1.total_amount - t1.init_fee)                              AS monthly_fee,
    init_fee_rate,
    monthly_fee_rate,
    t1.apr_rate,
    t1.repayment_frequency,
    application_rank,

    -- 5-day overdue
    MAX(CASE WHEN duedate_1m_5_dt  > current_date() THEN NULL 
             WHEN dpd_days_1m_5  >= 5 THEN 1 ELSE 0 END) AS duedate_1m_5,
    MAX(CASE WHEN duedate_2m_5_dt  > current_date() THEN NULL 
             WHEN dpd_days_2m_5  >= 5 THEN 1 ELSE 0 END) AS duedate_2m_5,
    MAX(CASE WHEN duedate_3m_5_dt  > current_date() THEN NULL 
             WHEN dpd_days_3m_5  >= 5 THEN 1 ELSE 0 END) AS duedate_3m_5,
    MAX(CASE WHEN duedate_4m_5_dt  > current_date() THEN NULL 
             WHEN dpd_days_4m_5  >= 5 THEN 1 ELSE 0 END) AS duedate_4m_5,
    MAX(CASE WHEN duedate_5m_5_dt  > current_date() THEN NULL 
             WHEN dpd_days_5m_5  >= 5 THEN 1 ELSE 0 END) AS duedate_5m_5,
    MAX(CASE WHEN duedate_6m_5_dt  > current_date() THEN NULL 
             WHEN dpd_days_6m_5  >= 5 THEN 1 ELSE 0 END) AS duedate_6m_5,
    MAX(CASE WHEN duedate_7m_5_dt  > current_date() THEN NULL 
             WHEN dpd_days_7m_5  >= 5 THEN 1 ELSE 0 END) AS duedate_7m_5,
    MAX(CASE WHEN duedate_8m_5_dt  > current_date() THEN NULL 
             WHEN dpd_days_8m_5  >= 5 THEN 1 ELSE 0 END) AS duedate_8m_5,
    MAX(CASE WHEN duedate_9m_5_dt  > current_date() THEN NULL 
             WHEN dpd_days_9m_5  >= 5 THEN 1 ELSE 0 END) AS duedate_9m_5,
    MAX(CASE WHEN duedate_10m_5_dt > current_date() THEN NULL 
             WHEN dpd_days_10m_5 >= 5 THEN 1 ELSE 0 END) AS duedate_10m_5,
    MAX(CASE WHEN duedate_11m_5_dt > current_date() THEN NULL 
             WHEN dpd_days_11m_5 >= 5 THEN 1 ELSE 0 END) AS duedate_11m_5,
    MAX(CASE WHEN duedate_12m_5_dt > current_date() THEN NULL 
             WHEN dpd_days_12m_5 >= 5 THEN 1 ELSE 0 END) AS duedate_12m_5,

    -- 30-day overdue
    MAX(CASE WHEN duedate_1m_30_dt  > current_date() THEN NULL 
             WHEN dpd_days_1m_30  >= 30 THEN 1 ELSE 0 END) AS duedate_1m_30,
    MAX(CASE WHEN duedate_2m_30_dt  > current_date() THEN NULL 
             WHEN dpd_days_2m_30  >= 30 THEN 1 ELSE 0 END) AS duedate_2m_30,
    MAX(CASE WHEN duedate_3m_30_dt  > current_date() THEN NULL 
             WHEN dpd_days_3m_30  >= 30 THEN 1 ELSE 0 END) AS duedate_3m_30,
    MAX(CASE WHEN duedate_4m_30_dt  > current_date() THEN NULL 
             WHEN dpd_days_4m_30  >= 30 THEN 1 ELSE 0 END) AS duedate_4m_30,
    MAX(CASE WHEN duedate_5m_30_dt  > current_date() THEN NULL 
             WHEN dpd_days_5m_30  >= 30 THEN 1 ELSE 0 END) AS duedate_5m_30,
    MAX(CASE WHEN duedate_6m_30_dt  > current_date() THEN NULL 
             WHEN dpd_days_6m_30  >= 30 THEN 1 ELSE 0 END) AS duedate_6m_30,
    MAX(CASE WHEN duedate_7m_30_dt  > current_date() THEN NULL 
             WHEN dpd_days_7m_30  >= 30 THEN 1 ELSE 0 END) AS duedate_7m_30,
    MAX(CASE WHEN duedate_8m_30_dt  > current_date() THEN NULL 
             WHEN dpd_days_8m_30  >= 30 THEN 1 ELSE 0 END) AS duedate_8m_30,
    MAX(CASE WHEN duedate_9m_30_dt  > current_date() THEN NULL 
             WHEN dpd_days_9m_30  >= 30 THEN 1 ELSE 0 END) AS duedate_9m_30,
    MAX(CASE WHEN duedate_10m_30_dt > current_date() THEN NULL 
             WHEN dpd_days_10m_30 >= 30 THEN 1 ELSE 0 END) AS duedate_10m_30,
    MAX(CASE WHEN duedate_11m_30_dt > current_date() THEN NULL 
             WHEN dpd_days_11m_30 >= 30 THEN 1 ELSE 0 END) AS duedate_11m_30,
    MAX(CASE WHEN duedate_12m_30_dt > current_date() THEN NULL 
             WHEN dpd_days_12m_30 >= 30 THEN 1 ELSE 0 END) AS duedate_12m_30,

    -- 60-day overdue
    MAX(CASE WHEN duedate_1m_60_dt  > current_date() THEN NULL 
             WHEN dpd_days_1m_60  >= 60 THEN 1 ELSE 0 END) AS duedate_1m_60,
    MAX(CASE WHEN duedate_2m_60_dt  > current_date() THEN NULL 
             WHEN dpd_days_2m_60  >= 60 THEN 1 ELSE 0 END) AS duedate_2m_60,
    MAX(CASE WHEN duedate_3m_60_dt  > current_date() THEN NULL 
             WHEN dpd_days_3m_60  >= 60 THEN 1 ELSE 0 END) AS duedate_3m_60,
    MAX(CASE WHEN duedate_4m_60_dt  > current_date() THEN NULL 
             WHEN dpd_days_4m_60  >= 60 THEN 1 ELSE 0 END) AS duedate_4m_60,
    MAX(CASE WHEN duedate_5m_60_dt  > current_date() THEN NULL 
             WHEN dpd_days_5m_60  >= 60 THEN 1 ELSE 0 END) AS duedate_5m_60,
    MAX(CASE WHEN duedate_6m_60_dt  > current_date() THEN NULL 
             WHEN dpd_days_6m_60  >= 60 THEN 1 ELSE 0 END) AS duedate_6m_60,
    MAX(CASE WHEN duedate_7m_60_dt  > current_date() THEN NULL 
             WHEN dpd_days_7m_60  >= 60 THEN 1 ELSE 0 END) AS duedate_7m_60,
    MAX(CASE WHEN duedate_8m_60_dt  > current_date() THEN NULL 
             WHEN dpd_days_8m_60  >= 60 THEN 1 ELSE 0 END) AS duedate_8m_60,
    MAX(CASE WHEN duedate_9m_60_dt  > current_date() THEN NULL 
             WHEN dpd_days_9m_60  >= 60 THEN 1 ELSE 0 END) AS duedate_9m_60,
    MAX(CASE WHEN duedate_10m_60_dt > current_date() THEN NULL 
             WHEN dpd_days_10m_60 >= 60 THEN 1 ELSE 0 END) AS duedate_10m_60,
    MAX(CASE WHEN duedate_11m_60_dt > current_date() THEN NULL 
             WHEN dpd_days_11m_60 >= 60 THEN 1 ELSE 0 END) AS duedate_11m_60,
    MAX(CASE WHEN duedate_12m_60_dt > current_date() THEN NULL 
             WHEN dpd_days_12m_60 >= 60 THEN 1 ELSE 0 END) AS duedate_12m_60

FROM model.tmp_eliam_listing_debt_dpd_days sp
LEFT JOIN (
    SELECT 
        *,
        init_fee / total_amount AS init_fee_rate,
        (total_loan_amount - total_amount - init_fee) / total_amount / (loan_term / 4) AS monthly_fee_rate,
        (total_loan_amount - total_amount) / total_amount / (loan_term * 7) * 365 AS apr_rate,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY dispersal_date) AS application_rank
    FROM ods.aus_fundo_loans_loan_applications
    WHERE status IN ('Active_Account', 'Closed', 'Blocked')
) t1
ON sp.application_id = t1.id
LEFT JOIN model.tmp_eliam_user_type t2
ON sp.application_id = t2.application_id

GROUP BY 
    1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17;