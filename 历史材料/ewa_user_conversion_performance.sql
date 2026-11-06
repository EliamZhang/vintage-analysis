DROP TABLE IF EXISTS ba.ewa_user_conversion_performance;
CREATE TABLE IF NOT EXISTS ba.ewa_user_conversion_performance AS
SELECT
    biz_date
    ,biz_day
    ,biz_week
    ,biz_month
    ,biz_quarter
    ,media_source
    ,campaign
    ,platform
    ,fst_kyc_result
    ,fst_payto_status
    
    ,count(user_id) as register_user_cnt

    -- total
    ,count(case when fst_apply_limit_time is not null then user_id end) as fst_apply_limit_user_cnt
    ,count(case when fst_has_limit_time is not null then user_id end) as fst_has_limit_user_cnt
    ,count(case when fst_apply_loan_time is not null then user_id end) as fst_apply_loan_user_cnt
    ,count(case when fst_withdraw_time is not null then user_id end) as fst_withdraw_user_cnt
    ,sum(coalesce(fst_withdraw_amount,cast(0 as decimal(18,2)))) as fst_withdraw_amount

    -- 戳额人数
    ,count(case when apply_limit_diff_day = 0 then user_id end) as fst_apply_limit_cnt_t0
    ,count(case when apply_limit_diff_day between 0 and 1 then user_id end) as fst_apply_limit_cnt_t1
    ,count(case when apply_limit_diff_day between 0 and 7 then user_id end) as fst_apply_limit_cnt_t7

    -- 有额人数
    ,count(case when has_limit_diff_day = 0 then user_id end) as fst_has_limit_cnt_t0
    ,count(case when has_limit_diff_day between 0 and 1 then user_id end) as fst_has_limit_cnt_t1
    ,count(case when has_limit_diff_day between 0 and 7 then user_id end) as fst_has_limit_cnt_t7

    -- 申请借款人数
    ,count(case when apply_loan_diff_day = 0 then user_id end) as fst_apply_loan_cnt_t0
    ,count(case when apply_loan_diff_day between 0 and 1 then user_id end) as fst_apply_loan_cnt_t1
    ,count(case when apply_loan_diff_day between 0 and 7 then user_id end) as fst_apply_loan_cnt_t7

    -- 成交人数
    ,count(case when withdraw_diff_day = 0 then user_id end) as fst_withdraw_cnt_t0
    ,count(case when withdraw_diff_day between 0 and 1 then user_id end) as fst_withdraw_cnt_t1
    ,count(case when withdraw_diff_day between 0 and 7 then user_id end) as fst_withdraw_cnt_t7

    -- 成交金额
    ,sum(case when withdraw_diff_day = 0
            then coalesce(fst_withdraw_amount,cast(0 as decimal(18,2)))
              else cast(0 as decimal(18,2))
         end) as fst_withdraw_amount_t0
    ,sum(case when withdraw_diff_day between 0 and 1
              then coalesce(fst_withdraw_amount,cast(0 as decimal(18,2)))
              else cast(0 as decimal(18,2))
         end) as fst_withdraw_amount_t1
    ,sum(case when withdraw_diff_day between 0 and 7
              then coalesce(fst_withdraw_amount,cast(0 as decimal(18,2)))
              else cast(0 as decimal(18,2))
         end) as fst_withdraw_amount_t7

    ,cast(current_timestamp() as string) as dw_cre_time

    -- 首次有额额度
    ,sum(coalesce(fst_has_limit,cast(0 as decimal(18,2)))) as fst_has_limit
    ,sum(case when has_limit_diff_day = 0
              then coalesce(fst_has_limit,cast(0 as decimal(18,2)))
              else cast(0 as decimal(18,2))
         end) as fst_has_limit_t0
    ,sum(case when has_limit_diff_day between 0 and 1
              then coalesce(fst_has_limit,cast(0 as decimal(18,2)))
              else cast(0 as decimal(18,2))
         end) as fst_has_limit_t1
    ,sum(case when has_limit_diff_day between 0 and 7
              then coalesce(fst_has_limit,cast(0 as decimal(18,2)))
              else cast(0 as decimal(18,2))
         end) as fst_has_limit_t7

    -- 借款通过人数
    ,count(case when loan_pass_diff_day = 0 then user_id end) as fst_loan_pass_cnt_t0
    ,count(case when loan_pass_diff_day between 0 and 1 then user_id end) as fst_loan_pass_cnt_t1
    ,count(case when loan_pass_diff_day between 0 and 7 then user_id end) as fst_loan_pass_cnt_t7
    ,count(case when fst_loan_pass_time is not null then user_id end) as fst_loan_pass_cnt

    -- KYC指标
    ,count(case when fst_kyc_time is not null then user_id end) as fst_kyc_user_cnt
    ,count(case when fst_kyc_result = 'PASS' then user_id end) as fst_kyc_pass_user_cnt

    -- PayTo指标
    ,count(case when fst_payto_time is not null then user_id end) as fst_payto_user_cnt
    ,count(case when fst_payto_status = 'SUCCESS' then user_id end) as fst_payto_success_user_cnt
    ,count(case when fst_payto_status LIKE '%SKIPPED%' then user_id end) as fst_payto_skip_user_cnt
    -- KYC t0/t1/t7
    ,count(case when kyc_diff_day = 0 then user_id end) as fst_kyc_user_cnt_t0
    ,count(case when kyc_diff_day between 0 and 1 then user_id end) as fst_kyc_user_cnt_t1
    ,count(case when kyc_diff_day between 0 and 7 then user_id end) as fst_kyc_user_cnt_t7
    ,count(case when kyc_diff_day = 0 and fst_kyc_result = 'PASS' then user_id end) as fst_kyc_pass_user_cnt_t0
    ,count(case when kyc_diff_day between 0 and 1 and fst_kyc_result = 'PASS' then user_id end) as fst_kyc_pass_user_cnt_t1
    ,count(case when kyc_diff_day between 0 and 7 and fst_kyc_result = 'PASS' then user_id end) as fst_kyc_pass_user_cnt_t7
    -- PayTo t0/t1/t7
    ,count(case when payto_diff_day = 0 then user_id end) as fst_payto_user_cnt_t0
    ,count(case when payto_diff_day between 0 and 1 then user_id end) as fst_payto_user_cnt_t1
    ,count(case when payto_diff_day between 0 and 7 then user_id end) as fst_payto_user_cnt_t7
    ,count(case when payto_diff_day = 0 and fst_payto_status = 'SUCCESS' then user_id end) as fst_payto_success_user_cnt_t0
    ,count(case when payto_diff_day between 0 and 1 and fst_payto_status = 'SUCCESS' then user_id end) as fst_payto_success_user_cnt_t1
    ,count(case when payto_diff_day between 0 and 7 and fst_payto_status = 'SUCCESS' then user_id end) as fst_payto_success_user_cnt_t7
    ,count(case when payto_diff_day = 0 and fst_payto_status LIKE '%SKIPPED%' then user_id end) as fst_payto_skip_user_cnt_t0
    ,count(case when payto_diff_day between 0 and 1 and fst_payto_status LIKE '%SKIPPED%' then user_id end) as fst_payto_skip_user_cnt_t1
    ,count(case when payto_diff_day between 0 and 7 and fst_payto_status LIKE '%SKIPPED%' then user_id end) as fst_payto_skip_user_cnt_t7
from (
    select
        DATE(register_time) as biz_date
        ,substr(register_time,1,10) as biz_day
        ,c.week_of_year as biz_week
        ,c.year_month as biz_month
        ,c.year_quarter as biz_quarter
        ,a.user_id
        ,CASE WHEN b.platform='ios' THEN 'iOS'
            WHEN b.platform='android' THEN 'Android'
            ELSE 'Null' END AS platform
        ,CASE WHEN b.media_source IS NULL OR b.media_source='' OR b.media_source IN ('organic','restricted') THEN 'Organic'
            WHEN b.media_source='googleadwords_int' THEN 'Google'
            WHEN b.media_source='official website' THEN 'Official Website'
            WHEN b.media_source='Cross_sale' THEN 'Fundo App Form'
            ELSE b.media_source END AS media_source
        ,CASE WHEN b.campaign='2144588633' THEN 'Apple_Search_Max_Com_02 sep'
            WHEN b.media_source='Cross_sale' THEN 'Fundo_Crosssell'
            WHEN b.media_source='Email' AND DATE(register_time)='2026-09-14' THEN 'Fundo_Crosssell'
            WHEN b.campaign IS NULL OR b.campaign='' OR b.campaign IN ('None') THEN 'Null'
            ELSE b.campaign END AS campaign
        ,fst_apply_limit_time
        ,fst_has_limit_time
        ,fst_has_limit
        ,fst_apply_loan_time
        ,fst_loan_pass_time
        ,fst_withdraw_time
        ,fst_withdraw_amount
        ,fst_kyc_time
        ,fst_kyc_result
        ,fst_payto_time
        ,fst_payto_status

        -- 注册-戳额申请
        ,case when fst_apply_limit_time is not null
              then datediff(to_date(fst_apply_limit_time),to_date(register_time))
         end as apply_limit_diff_day

        -- 注册-有额
        ,case when fst_has_limit_time is not null
              then datediff(to_date(fst_has_limit_time),to_date(register_time))
         end as has_limit_diff_day

        -- 注册-借款申请
        ,case when fst_apply_loan_time is not null
              then datediff(to_date(fst_apply_loan_time),to_date(register_time))
         end as apply_loan_diff_day

        -- 注册-借款申请通过(风险审核通过，非生成listing_id)
        ,case when fst_loan_pass_time is not null
              then datediff(to_date(fst_loan_pass_time),to_date(register_time))
         end as loan_pass_diff_day

        -- 注册-成交
        ,case when fst_withdraw_time is not null
              then datediff(to_date(fst_withdraw_time),to_date(register_time))
         end as withdraw_diff_day
         
         -- 注册-首次KYC
        ,case when fst_kyc_time is not null
              then datediff(to_date(fst_kyc_time), to_date(register_time))
         end as kyc_diff_day

        -- 注册-首次PayTo
        ,case when fst_payto_time is not null
              then datediff(to_date(fst_payto_time), to_date(register_time))
         end as payto_diff_day
    FROM edw_ewa.dwb_user_fst_conv_dtl a 
    LEFT JOIN 
        (SELECT user_id, 
            CASE WHEN media_source='' THEN NULL ELSE media_source END AS media_source, 
            CASE WHEN campaign='' THEN NULL ELSE campaign END AS campaign, 
            CASE WHEN platform='' THEN NULL ELSE platform END AS platform
        FROM ods_ewa.aus_ewa_market_tb_af_signup_attribute_record
        WHERE isactive=1) b 
    ON a.user_id=b.user_id
    LEFT JOIN edw.dim_date c
    ON substr(a.register_time,1,10)=c.d_code
) a
GROUP BY 1,2,3,4,5,6,7,8,9,10
ORDER BY 1,2,3,4,5,6,7,8,9,10
;