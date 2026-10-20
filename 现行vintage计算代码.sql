set spark.sql.session.timeZone = Australia/Sydney;
drop table if exists edw_ewa.dws_risk_credit_intake_dtl;
create table edw_ewa.dws_risk_credit_intake_dtl as
select
    ca.user_id
    ,d.register_time
    ,case when ca.apply_time is not null then 1 else 0 end as is_complete -- 业务含义：本次授信进件是否完件（1是，0否）
    ,ca.attempt_time
    ,ca.is_third_party_pull_success
    ,ca.fst_complete_time
    ,case
        when lf.loan_no is not null then lf.product_user_type
        when ca.apply_time is not null then
             case when ca.apply_time > d.fst_withdraw_time then 'old' else 'new' end
        else
             case when ca.attempt_time > d.fst_withdraw_time then 'old' else 'new' end
     end as product_user_type -- 业务含义：产品侧新老客类型
    ,ca.limit_apply_no
    ,ca.flow_id_credit
    ,coalesce(lf.credit_apply_time, ca.apply_time) as credit_apply_time -- 业务含义：授信申请时间
    ,coalesce(lf.credit_is_pass, ca.is_pass) as credit_is_pass -- 业务含义：授信是否通过（1通过，0未通过）
    ,coalesce(lf.credit_limit, ca.credit_limit) as credit_limit -- 业务含义：授信额度
    ,lf.loan_no
    ,lf.listing_id
    ,lf.apply_seq
    ,lf.loan_seq
    ,lf.real_amount as loan_amount -- 业务含义：实际放款本金
    ,lf.is_risk_pass
    ,lf.is_risk_decided
    ,lf.is_kyc_pass
    ,lf.is_disburse_success
    ,lf.is_deal
    ,lf.fail_reason
    ,lf.loan_stage
    ,lf.status as loan_status -- 业务含义：借款状态
    ,lf.loan_apply_time
    ,lf.apply_disburse_time as loan_time -- 业务含义：实际放款时间
    ,case when lf.is_deal = 1 then od.hist_overdue_days end      as hist_overdue_days -- 业务含义：历史累计逾期天数
    ,case when lf.is_deal = 1 then od.current_overdue_days end   as current_overdue_days -- 业务含义：当前逾期天数
    ,case when lf.is_deal = 1 then od.init_due_date end          as init_due_date -- 业务含义：首次应还到期日
    ,case when lf.is_deal = 1 then od.user_actual_repay_time end as user_actual_repay_time -- 业务含义：实际还款时间
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when least(to_date(od.user_actual_repay_time)
                              ,date_add(od.init_due_date, 3)) < current_date()
                    then 1 else 0 end
     end as is_fpd3_obs -- 业务含义：FPD3观察是否成熟（1成熟，0未成熟）
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when od.user_actual_repay_time is not null
                    then case when to_date(od.user_actual_repay_time)
                                 > date_add(od.init_due_date, 3)
                              then 1 else 0 end
                    else case when current_date() > date_add(od.init_due_date, 3)
                              then 1 else 0 end
               end
     end as is_fpd3_ovd -- 业务含义：是否发生FPD3逾期
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when least(to_date(od.user_actual_repay_time)
                              ,date_add(od.init_due_date, 7)) < current_date()
                    then 1 else 0 end
     end as is_fpd7_obs -- 业务含义：FPD7观察是否成熟
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when od.user_actual_repay_time is not null
                    then case when to_date(od.user_actual_repay_time)
                                 > date_add(od.init_due_date, 7)
                              then 1 else 0 end
                    else case when current_date() > date_add(od.init_due_date, 7)
                              then 1 else 0 end
               end
     end as is_fpd7_ovd -- 业务含义：是否发生FPD7逾期
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when least(to_date(od.user_actual_repay_time)
                              ,date_add(od.init_due_date, 15)) < current_date()
                    then 1 else 0 end
     end as is_fpd15_obs -- 业务含义：FPD15观察是否成熟
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when od.user_actual_repay_time is not null
                    then case when to_date(od.user_actual_repay_time)
                                 > date_add(od.init_due_date, 15)
                              then 1 else 0 end
                    else case when current_date() > date_add(od.init_due_date, 15)
                              then 1 else 0 end
               end
     end as is_fpd15_ovd -- 业务含义：是否发生FPD15逾期
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when least(to_date(od.user_actual_repay_time)
                              ,date_add(od.init_due_date, 30)) < current_date()
                    then 1 else 0 end
     end as is_fpd30_obs -- 业务含义：FPD30观察是否成熟
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when od.user_actual_repay_time is not null
                    then case when to_date(od.user_actual_repay_time)
                                 > date_add(od.init_due_date, 30)
                              then 1 else 0 end
                    else case when current_date() > date_add(od.init_due_date, 30)
                              then 1 else 0 end
               end
     end as is_fpd30_ovd -- 业务含义：是否发生FPD30逾期
    ,case when lf.is_deal = 1
          then datediff(od.init_due_date, lf.apply_disburse_time) end
                                                   as loan_term_contract_days -- 业务含义：合同借款期限（自然日）
    ,case when lf.is_deal = 1
          then datediff(od.user_actual_repay_time, lf.apply_disburse_time) end
                                                   as loan_term_actual_days -- 业务含义：实际借款天数；未还款为空
    ,case when lf.is_deal = 1 and od.user_actual_repay_time is not null
          then case when to_date(od.user_actual_repay_time) < od.init_due_date
                    then 1 else 0 end
     end                                           as is_early_settlement -- 业务含义：是否提前结清（1提前，0未提前，NULL无法判断）
    ,case when lf.is_deal = 1 and od.current_overdue_days is not null
          then case when od.current_overdue_days > 0 then lf.real_amount
                    else 0
               end
     end                                           as current_ovd_amt -- 业务含义：当前逾期借款的放款本金，非实际逾期敞口
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when trunc(current_date(), 'MM')
                       >= add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)
                    then 1 else 0 end
     end                                           as is_1m_obs -- 业务含义：是否进入放款后第1自然月观察期
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when trunc(current_date(), 'MM')
                       >= add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)
                    then 1 else 0 end
     end                                           as is_2m_obs -- 业务含义：是否进入放款后第2自然月观察期
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case
                 when trunc(current_date(), 'MM') = add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)
                      then case when od.current_overdue_days > 30 then 1 else 0 end
                 when trunc(current_date(), 'MM') > add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)
                      then case when (od.user_actual_repay_time is null
                                      or to_date(od.user_actual_repay_time) > last_day(add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)))
                                  and datediff(last_day(add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)), od.init_due_date) > 30
                                then 1 else 0 end
                 else 0
               end
     end                                           as is_1m30_ovd -- 业务含义：第1观察月月末是否处于30天以上逾期状态
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case
                 when trunc(current_date(), 'MM') = add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)
                      then case when od.current_overdue_days > 30 then 1 else 0 end
                 when trunc(current_date(), 'MM') > add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)
                      then case when (od.user_actual_repay_time is null
                                      or to_date(od.user_actual_repay_time) > last_day(add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)))
                                  and datediff(last_day(add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)), od.init_due_date) > 30
                                then 1 else 0 end
                 else 0
               end
     end                                           as is_2m30_ovd -- 业务含义：第2观察月月末是否处于30天以上逾期状态
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when trunc(current_date(), 'MM')
                       >= add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)
                    then lf.real_amount else 0 end
     end                                           as amt_1m_obs -- 业务含义：第1观察月观察本金
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case when trunc(current_date(), 'MM')
                       >= add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)
                    then lf.real_amount else 0 end
     end                                           as amt_2m_obs -- 业务含义：第2观察月观察本金
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case
                 when trunc(current_date(), 'MM') = add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)
                      then case when od.current_overdue_days > 30 then lf.real_amount else 0 end
                 when trunc(current_date(), 'MM') > add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)
                      then case when (od.user_actual_repay_time is null
                                      or to_date(od.user_actual_repay_time) > last_day(add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)))
                                  and datediff(last_day(add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 1)), od.init_due_date) > 30
                                then lf.real_amount else 0 end
                 else 0
               end
     end                                           as amt_1m30_ovd -- 业务含义：第1观察月月末30+逾期对应放款本金
    ,case when lf.is_deal = 1 and od.listing_id is not null
          then case
                 when trunc(current_date(), 'MM') = add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)
                      then case when od.current_overdue_days > 30 then lf.real_amount else 0 end
                 when trunc(current_date(), 'MM') > add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)
                      then case when (od.user_actual_repay_time is null
                                      or to_date(od.user_actual_repay_time) > last_day(add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)))
                                  and datediff(last_day(add_months(trunc(to_date(lf.apply_disburse_time), 'MM'), 2)), od.init_due_date) > 30
                                then lf.real_amount else 0 end
                 else 0
               end
     end                                           as amt_2m30_ovd -- 业务含义：第2观察月月末30+逾期对应放款本金
    ,to_date(date_trunc('WEEK',  coalesce(lf.credit_apply_time, ca.apply_time)))  as apply_week_credit -- 业务含义：授信申请所在周（周一为周起始）
    ,to_date(date_trunc('MONTH', coalesce(lf.credit_apply_time, ca.apply_time)))  as apply_month_credit -- 业务含义：授信申请所在月（自然月月初）
    ,to_date(date_trunc('WEEK',  lf.loan_apply_time))                             as apply_week_loan -- 业务含义：借款申请所在周（周一为周起始）
    ,to_date(date_trunc('MONTH', lf.loan_apply_time))                             as apply_month_loan -- 业务含义：借款申请所在月（自然月月初）
    ,cd.risk_level                                 as risk_level_credit -- 业务含义：授信决策风险等级
    ,cd.model_score                                as model_score_credit -- 业务含义：授信决策模型分
    ,cd.strategy_type                              as strategy_type_credit -- 业务含义：授信决策策略类型
    ,cd.default_frequency                          as default_frequency_credit -- 业务含义：授信决策时识别的发薪频率
    ,cd.default_income                             as default_income_credit -- 业务含义：授信决策时识别的单期收入
    ,cd.monthly_income                             as monthly_income_credit -- 业务含义：授信决策时折算的月收入
    ,cd.last_payment_date                          as last_payment_date_credit -- 业务含义：授信决策时观测到的上次发薪日
    ,cd.ida_version                                as ida_version_credit -- 业务含义：授信侧收入识别模型/IDA版本
    ,cd.is_white_list_user                         as is_white_list_user_credit -- 业务含义：授信决策时白名单标记
    ,ld.risk_level                                 as risk_level_loan -- 业务含义：提款决策风险等级
    ,ld.model_score                                as model_score_loan -- 业务含义：提款决策模型分
    ,ld.strategy_type                              as strategy_type_loan -- 业务含义：提款决策策略类型
    ,ld.default_frequency                          as default_frequency_loan -- 业务含义：提款决策时识别的发薪频率
    ,ld.default_income                             as default_income_loan -- 业务含义：提款决策时识别的单期收入
    ,ld.monthly_income                             as monthly_income_loan -- 业务含义：提款决策时折算的月收入
    ,ld.last_payment_date                          as last_payment_date_loan -- 业务含义：提款决策时观测到的上次发薪日
    ,ld.ida_version                                as ida_version_loan -- 业务含义：提款侧收入识别模型/IDA版本
    ,ld.is_white_list_user                         as is_white_list_user_loan -- 业务含义：提款决策时白名单标记
    ,ld.curr_temp_quota                            as curr_temp_quota_loan -- 业务含义：提款决策时临时额度原值（可能含哨兵值）
    ,ld.curr_fixed_quota                           as curr_fixed_quota_loan -- 业务含义：提款决策时固定额度原值（可能含哨兵值）
    ,ld.curr_total_quota                           as curr_total_quota_loan -- 业务含义：提款决策时有效总额度（仅累加正额度）
    ,ld.curr_balance                               as curr_balance_loan -- 业务含义：提款决策时已有在贷余额，不含本笔
    ,case when lf.is_deal = 1 and ld.curr_balance is not null
          then ld.curr_balance + lf.real_amount end        as post_loan_balance -- 业务含义：预计本笔放款后的在贷余额
    ,case when lf.is_deal = 1
            and ld.curr_balance    is not null
            and ld.curr_total_quota > 0
          then (ld.curr_balance + lf.real_amount) / ld.curr_total_quota
     end                                                       as quota_util_rate -- 业务含义：逐笔额度使用率=放款后预计在贷/有效总额度
    ,case when af.platform = 'ios'     then 'iOS'
          when af.platform = 'android' then 'Android'
          else 'Null'
     end                                           as platform -- 业务含义：AppsFlyer归因平台
    ,case when af.media_source is null
            or af.media_source = ''
            or af.media_source in ('organic', 'restricted') then 'Organic'
          when af.media_source = 'googleadwords_int' then 'Google'
          when af.media_source = 'official website'  then 'Official Website'
          when af.media_source = 'Cross_sale'        then 'Fundo App Form'
          else af.media_source
     end                                           as media_source -- 业务含义：AppsFlyer媒体来源映射
    ,case when af.campaign = '2144588633' then 'Apple_Search_Max_Com_02 sep'
          when af.media_source = 'Cross_sale' then 'Fundo_Crosssell'
          when af.media_source = 'Email'
               and to_date(d.register_time) = date '2026-09-14' then 'Fundo_Crosssell'
          when af.campaign is null
            or af.campaign = ''
            or af.campaign in ('None') then 'Null'
          else af.campaign
     end                                           as campaign -- 业务含义：AppsFlyer活动/广告系列映射
    ,current_timestamp() as snapshot_time -- 业务含义：明细数据快照时间
from (
    select
        ba.user_id
        ,ba.attempt_time
        ,ba.limit_apply_no
        ,dc.flow_no                                                as flow_id_credit -- 业务含义：授信侧风控决策流水号
        ,case when dc.limit_apply_no is not null then 1 else 0 end as is_third_party_pull_success -- 业务含义：是否成功取得三方授信数据/风控流水（1是，0否）
        ,case when dc.is_complete_apply = 1 then dc.inserttime end as apply_time -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        ,case when dc.is_complete_apply = 1
              then case when c.total_amount_after > 0 then 1 else 0 end
         end as is_pass -- 业务含义：业务状态/是否标记字段，通常1=是、0=否；NULL含义依上游流程而定
        ,case when dc.is_complete_apply = 1 then c.total_amount_after end as credit_limit -- 业务含义：授信额度
        ,min(case when dc.is_complete_apply = 1 then dc.inserttime end)
             over (partition by ba.user_id) as fst_complete_time -- 业务含义：用户首次完件时间
    from (
        select
            a.borrower_id as user_id -- 业务含义：用户唯一标识
            ,a.limit_apply_no
            ,a.flow_no
            ,a.inserttime as attempt_time -- 业务含义：本次戳额/授信尝试时间
        from ods_ewa.aus_listing_tb_loan_limit_apply a
        where a.biz_type in (400, 406)
          and a.inserttime >= '2026-08-14'
          and a.inserttime <  current_date()
    ) ba
    left join edw_ewa.dwd_risk_credit_application_dly dc
      on ba.user_id = dc.user_id
      and ba.limit_apply_no = dc.limit_apply_no
    left join ods_ewa.aus_listing_tb_loan_user_limit_log c
      on dc.flow_no = c.relate_id
      and c.event_type = 1
) ca
left join (
    select
        user_id
        ,loan_no
        ,listing_id
        ,status
        ,fail_reason
        ,loan_stage
        ,loan_apply_time
        ,apply_disburse_time
        ,real_amount
        ,is_deal
        ,is_risk_pass
        ,is_risk_decided
        ,is_kyc_pass
        ,is_disburse_success
        ,credit_apply_time
        ,credit_is_pass
        ,credit_limit
        ,product_user_type
        ,apply_seq
        ,case when status = 'DISBURSE_SUCCESS' then disburse_rn end as loan_seq -- 业务含义：成功放款顺序号
    from (
        select
            la.user_id
            ,la.loan_no
            ,la.listing_id
            ,la.status
            ,la.fail_reason
            ,la.loan_stage
            ,la.inserttime as loan_apply_time -- 业务含义：借款申请提交时间
            ,la.apply_disburse_time
            ,l.real_amount
            ,l.is_deal
            ,case when la.fail_reason = 'RISK_REJECT' then 0
                  when la.loan_stage = 'RISK_LOAN_AUDIT' then 0
                  when rd.flow_id is null then null -- 【修改】无风控决策记录=未进入风控，不再兜底记为通过
                  else 1
             end as is_risk_pass -- 业务含义：借款风险审核是否通过（1通过，0未通过/审核中，NULL未进入）
            ,case when la.fail_reason = 'RISK_REJECT' then 1
                  when la.loan_stage = 'RISK_LOAN_AUDIT' then 0
                  when rd.flow_id is null then null -- 【修改】未进入风控，不计入风控通过率分母
                  else 1
             end as is_risk_decided -- 业务含义：【新增】借款风控是否已出结果（1已出结果，0风控审核中，NULL未进入）
            ,case when la.fail_reason = 'RISK_REJECT'
                    or la.loan_stage = 'RISK_LOAN_AUDIT'
                    or rd.flow_id is null then null -- 【修改】未进入风控即未进入 KYC
                  when la.fail_reason in ('NAME_UNMATCHED','FRANKIE_VERIFY_FAILED') then 0
                  when la.loan_stage = 'KYC_AUDIT' then 0
                  else 1
             end as is_kyc_pass -- 业务含义：KYC身份核验是否通过（1通过，0未通过/审核中，NULL未进入）
            ,case when la.fail_reason = 'RISK_REJECT'
                    or la.loan_stage = 'RISK_LOAN_AUDIT'
                    or la.fail_reason in ('NAME_UNMATCHED','FRANKIE_VERIFY_FAILED')
                    or la.loan_stage = 'KYC_AUDIT'
                    or rd.flow_id is null then null -- 【修改】未进入风控即未进入放款
                  when la.status = 'DISBURSE_SUCCESS' then 1
                  else 0
             end as is_disburse_success -- 业务含义：放款是否成功（1成功，0失败/处理中，NULL未进入）
            ,ca2.apply_time as credit_apply_time -- 业务含义：授信申请时间
            ,ca2.is_pass as credit_is_pass -- 业务含义：授信是否通过（1通过，0未通过）
            ,ca2.credit_limit
            ,case when la.apply_disburse_time is not null then
                       case when la.apply_disburse_time > d2.fst_withdraw_time then 'old' else 'new' end
                  else
                       case when la.inserttime > d2.fst_withdraw_time then 'old' else 'new' end
             end as product_user_type -- 业务含义：产品侧新老客类型
            ,row_number() over (partition by la.loan_no
                                order by ca2.apply_time desc, ca2.credit_limit desc) as rn -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,row_number() over (partition by la.user_id order by la.inserttime asc) as apply_seq -- 业务含义：借款申请顺序号
            ,row_number() over (partition by la.user_id
                                           ,case when la.status = 'DISBURSE_SUCCESS' then 1 else 0 end
                                order by la.apply_disburse_time asc) as disburse_rn -- 业务含义：借款/提款流程相关指标，具体口径见字段名
        from ods_ewa.aus_ewa_loan_biz_t_loan_application la
        left join edw_ewa.dwb_asset_cmn_listing l
          on la.listing_id = l.listing_id
        -- 【新增】提款风控决策记录：有记录=已进入风控；用于区分"未进入风控"与"风控通过"
        left join (
            select distinct flow_id
            from edw_ewa.dwd_risk_audit_loan_decision_dly
        ) rd
          on la.loan_no = rd.flow_id
        left join edw_ewa.dwb_user_fst_conv_dtl d2
          on la.user_id = d2.user_id
        left join (
            select
                a.borrower_id as user_id -- 业务含义：用户唯一标识
                ,dc.inserttime as apply_time -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
                ,1 as is_pass -- 业务含义：业务状态/是否标记字段，通常1=是、0=否；NULL含义依上游流程而定
                ,c.total_amount_after as credit_limit -- 业务含义：授信额度
            from ods_ewa.aus_listing_tb_loan_limit_apply a
            join edw_ewa.dwd_risk_credit_application_dly dc
              on a.borrower_id = dc.user_id
              and a.limit_apply_no = dc.limit_apply_no
            left join ods_ewa.aus_listing_tb_loan_user_limit_log c
              on dc.flow_no = c.relate_id
              and c.event_type = 1
            where a.biz_type in (400, 406)
              and dc.is_complete_apply = 1
              and c.total_amount_after > 0
        ) ca2
          on la.user_id = ca2.user_id
          and ca2.apply_time <= la.inserttime
        where la.inserttime >= '2026-08-14'
          and la.inserttime <  current_date()
    ) t
    where rn = 1
) lf
  on ca.user_id = lf.user_id
  and ca.apply_time = lf.credit_apply_time
left join edw_ewa.dwb_user_fst_conv_dtl d
  on ca.user_id = d.user_id
left join (
    select
        listing_id
        ,hist_overdue_days
        ,current_overdue_days
        ,init_due_date
        ,user_actual_repay_time
    from edw_ewa.dwb_asset_debt_dtl_snp
    where dt = current_date()
) od
  on lf.listing_id = od.listing_id
left join (
    select
         user_id
        ,max(nullif(media_source, '')) as media_source -- 业务含义：AppsFlyer媒体来源映射
        ,max(nullif(campaign, ''))     as campaign -- 业务含义：AppsFlyer活动/广告系列映射
        ,max(nullif(platform, ''))     as platform -- 业务含义：AppsFlyer归因平台
    from ods_ewa.aus_ewa_market_tb_af_signup_attribute_record
    where isactive = 1
    group by user_id
) af
  on ca.user_id = af.user_id
left join (
    select
        flow_id
        ,risk_level
        ,strategy_type
        ,is_white_list_user
        ,model_score
        ,default_frequency
        ,default_income
        ,ida_version
        ,last_payment_date
        ,case default_frequency
              when 'W' then default_income * 52 / 12
              when 'F' then default_income * 26 / 12
              when 'M' then default_income
         end as monthly_income -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
    from (
        select
            flow_id
            ,risk_level
            ,strategy_type
            ,is_white_list_user
            ,nullif(cast(get_json_object(model_score_info
                 ,'$.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626') as double)
                 ,-1.0)                                                  as model_score -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,upper(get_json_object(ida, '$.default_frequency'))          as default_frequency -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,cast(get_json_object(ida, '$.default_income') as double)    as default_income -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
            ,get_json_object(ida, '$.wi_version_id')                     as ida_version -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,cast(get_json_object(ida, '$.last_payment_date') as date)    as last_payment_date -- 业务含义：业务日期/时间字段或按自然月分组的日期标签
            ,row_number() over (
                 partition by flow_id
                 order by inserttime desc, updatetime desc
                         ,cast(flow_count as int) desc
             ) as rn -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        from edw_ewa.dwd_risk_audit_credit_decision_dly
    ) t
    where rn = 1
) cd
  on ca.flow_id_credit = cd.flow_id
left join (
    select
        flow_id
        ,risk_level
        ,strategy_type
        ,is_white_list_user
        ,model_score
        ,default_frequency
        ,default_income
        ,ida_version
        ,last_payment_date
        ,case default_frequency
              when 'W' then default_income * 52 / 12
              when 'F' then default_income * 26 / 12
              when 'M' then default_income
         end as monthly_income -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
        ,curr_temp_quota
        ,curr_fixed_quota
        ,curr_balance
        ,case when coalesce(curr_temp_quota, 0) > 0
                or coalesce(curr_fixed_quota, 0) > 0
              then (case when curr_temp_quota  > 0 then curr_temp_quota  else 0 end)
                 + (case when curr_fixed_quota > 0 then curr_fixed_quota else 0 end)
         end                                                             as curr_total_quota -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    from (
        select
            flow_id
            ,risk_level
            ,strategy_type
            ,is_white_list_user
            ,nullif(cast(get_json_object(model_score_info
                 ,'$.aus_wagego_new_risk_bid_3rdmodel_v1_0_20260626') as double)
                 ,-1.0)                                                  as model_score -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,upper(get_json_object(ida, '$.default_frequency'))          as default_frequency -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,cast(get_json_object(ida, '$.default_income') as double)    as default_income -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
            ,get_json_object(ida, '$.wi_version_id')                     as ida_version -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,cast(get_json_object(ida, '$.last_payment_date') as date)    as last_payment_date -- 业务含义：业务日期/时间字段或按自然月分组的日期标签
            ,cast(get_json_object(quota_risk_features, '$.curr_temp_quota')  as double)
                                                                         as curr_temp_quota -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,cast(get_json_object(quota_risk_features, '$.curr_fixed_quota') as double)
                                                                         as curr_fixed_quota -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,cast(get_json_object(withdrawal_risk_features, '$.currBalance') as double)
                                                                         as curr_balance -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
            ,row_number() over (
                 partition by flow_id
                 order by inserttime desc, updatetime desc
                         ,cast(flow_count as int) desc
             ) as rn -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        from edw_ewa.dwd_risk_audit_loan_decision_dly
    ) t
    where rn = 1
) ld
  on lf.loan_no = ld.flow_id
where ca.apply_time is not null
;
drop table if exists edw_ewa.ads_risk_loan_monitor_cube;
create table edw_ewa.ads_risk_loan_monitor_cube as
with base as (
    select * from edw_ewa.dws_risk_credit_intake_dtl
)
,loan_deal as (
    select
         loan_no
        ,max(loan_apply_time)                                as loan_apply_time -- 业务含义：借款申请提交时间
        ,max(product_user_type)                              as product_user_type -- 业务含义：产品侧新老客类型
        ,max(is_risk_pass)                                   as is_risk_pass -- 业务含义：借款风险审核是否通过（1通过，0未通过/审核中，NULL未进入）
        ,max(is_risk_decided)                                as is_risk_decided -- 业务含义：【新增】借款是否已有风控结果（1已出结果，0风控审核中，NULL未进入风控）
        ,max(is_kyc_pass)                                    as is_kyc_pass -- 业务含义：KYC身份核验是否通过（1通过，0未通过/审核中，NULL未进入）
        ,max(is_disburse_success)                            as is_disburse_success -- 业务含义：放款是否成功（1成功，0失败/处理中，NULL未进入）
        ,max(loan_amount)                                    as loan_amount -- 业务含义：实际放款本金
        ,max(current_overdue_days)                           as current_overdue_days -- 业务含义：当前逾期天数
        ,max(loan_term_contract_days)                        as loan_term_contract_days -- 业务含义：合同借款期限（自然日）
        ,max(loan_term_actual_days)                          as loan_term_actual_days -- 业务含义：实际借款天数；未还款为空
        ,max(quota_util_rate)                                as quota_util_rate -- 业务含义：逐笔额度使用率=放款后预计在贷/有效总额度
        ,max(is_early_settlement)                            as is_early_settlement -- 业务含义：是否提前结清（1提前，0未提前，NULL无法判断）
        ,max(loan_seq)                                       as loan_seq -- 业务含义：成功放款顺序号
        ,max(risk_level_loan)                                as risk_level_loan -- 业务含义：提款决策风险等级
        ,max(strategy_type_loan)                             as strategy_type_loan -- 业务含义：提款决策策略类型
        ,max(strategy_type_credit)                           as strategy_type_credit -- 业务含义：授信决策策略类型
        ,max(monthly_income_loan)                            as monthly_income_loan -- 业务含义：提款决策时折算的月收入
        ,max(default_frequency_loan)                         as default_frequency_loan -- 业务含义：提款决策时识别的发薪频率
        ,max(curr_total_quota_loan)                          as curr_total_quota_loan -- 业务含义：提款决策时有效总额度（仅累加正额度）
        ,max(model_score_loan)                               as model_score_loan -- 业务含义：提款决策模型分
        ,max(is_white_list_user_loan)                        as is_white_list_user_loan -- 业务含义：提款决策时白名单标记
        ,max(platform)                                       as platform -- 业务含义：AppsFlyer归因平台
        ,max(media_source)                                   as media_source -- 业务含义：AppsFlyer媒体来源映射
        ,max(campaign)                                       as campaign -- 业务含义：AppsFlyer活动/广告系列映射
        ,max(is_fpd3_obs)                                    as is_fpd3_obs -- 业务含义：FPD3观察是否成熟（1成熟，0未成熟）
        ,max(is_fpd3_ovd)                                    as is_fpd3_ovd -- 业务含义：是否发生FPD3逾期
        ,max(is_fpd7_obs)                                    as is_fpd7_obs -- 业务含义：FPD7观察是否成熟
        ,max(is_fpd7_ovd)                                    as is_fpd7_ovd -- 业务含义：是否发生FPD7逾期
        ,max(is_fpd15_obs)                                   as is_fpd15_obs -- 业务含义：FPD15观察是否成熟
        ,max(is_fpd15_ovd)                                   as is_fpd15_ovd -- 业务含义：是否发生FPD15逾期
        ,max(is_fpd30_obs)                                   as is_fpd30_obs -- 业务含义：FPD30观察是否成熟
        ,max(is_fpd30_ovd)                                   as is_fpd30_ovd -- 业务含义：是否发生FPD30逾期
        ,max(is_1m_obs)                                      as is_1m_obs -- 业务含义：是否进入放款后第1自然月观察期
        ,max(is_1m30_ovd)                                    as is_1m30_ovd -- 业务含义：第1观察月月末是否处于30天以上逾期状态
        ,max(is_2m_obs)                                      as is_2m_obs -- 业务含义：是否进入放款后第2自然月观察期
        ,max(is_2m30_ovd)                                    as is_2m30_ovd -- 业务含义：第2观察月月末是否处于30天以上逾期状态
        ,max(amt_1m_obs)                                     as amt_1m_obs -- 业务含义：第1观察月观察本金
        ,max(amt_1m30_ovd)                                   as amt_1m30_ovd -- 业务含义：第1观察月月末30+逾期对应放款本金
        ,max(amt_2m_obs)                                     as amt_2m_obs -- 业务含义：第2观察月观察本金
        ,max(amt_2m30_ovd)                                   as amt_2m30_ovd -- 业务含义：第2观察月月末30+逾期对应放款本金
        ,max(snapshot_time)                                  as snapshot_time -- 业务含义：明细数据快照时间
    from base
    where loan_no         is not null
      and loan_apply_time is not null
    group by loan_no
)
,loan_dim as (
    select
         loan_no
        ,is_risk_pass
        ,is_risk_decided
        ,is_kyc_pass
        ,is_disburse_success
        ,loan_amount
        ,current_overdue_days
        ,loan_term_contract_days
        ,loan_term_actual_days
        ,quota_util_rate
        ,is_early_settlement
        ,loan_seq
        ,monthly_income_loan
        ,model_score_loan
        ,risk_level_loan                                     as risk_level_raw -- 业务含义：风控决策风险等级
        ,is_fpd3_obs,  is_fpd3_ovd,  is_fpd7_obs,  is_fpd7_ovd
        ,is_fpd15_obs, is_fpd15_ovd, is_fpd30_obs, is_fpd30_ovd
        ,is_1m_obs,  is_1m30_ovd,  is_2m_obs,  is_2m30_ovd
        ,amt_1m_obs, amt_1m30_ovd, amt_2m_obs, amt_2m30_ovd
        ,snapshot_time
        ,case when is_disburse_success = 1
                and monthly_income_loan > 0
               then loan_amount / monthly_income_loan
         end                                                 as dti -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        ,to_date(date_trunc('DAY',  loan_apply_time))        as loan_apply_date -- 业务含义：业务日期/时间字段或按自然月分组的日期标签
        ,to_date(date_trunc('WEEK', loan_apply_time))        as loan_apply_week -- 业务含义：申请时间对应的自然周分组标签
        ,coalesce(risk_level_loan,      '(空)')               as risk_level -- 业务含义：风控决策风险等级
        ,coalesce(product_user_type,    '(空)')               as product_user_type -- 业务含义：产品侧新老客类型
        ,coalesce(strategy_type_loan,   '(空)')               as strategy_type_loan -- 业务含义：提款决策策略类型
        ,coalesce(strategy_type_credit, '(空)')               as strategy_type_credit -- 业务含义：授信决策策略类型
        ,platform
        ,media_source
        ,campaign
        ,coalesce(cast(is_white_list_user_loan as string), '(空)')
                                                             as is_white_list_user -- 业务含义：业务状态/是否标记字段，通常1=是、0=否；NULL含义依上游流程而定
        ,coalesce(default_frequency_loan, '(空)')            as frequency -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        ,case
              when loan_seq is null then '0_未放款'
              when loan_seq =  1    then '1_1'
              when loan_seq <= 3    then '2_2-3'
              when loan_seq <= 5    then '3_4-5'
              when loan_seq <= 8    then '4_6-8'
              else                       '5_9+'
         end                                                 as loan_seq_band -- 业务含义：借款/提款流程相关指标，具体口径见字段名
        ,case
              when curr_total_quota_loan is null then '0_未知'
              when curr_total_quota_loan <  100  then '1_<100'
              when curr_total_quota_loan <  200  then '2_100-200'
              when curr_total_quota_loan <  500  then '3_200-500'
              else                                    '4_>=500'
         end                                                 as quota_band -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        ,case
              when monthly_income_loan is null  then '0_未知'
              when monthly_income_loan <  1200  then '1_<1.2k'
              when monthly_income_loan <  4000  then '2_1.2-4k'
              when monthly_income_loan <  6000  then '3_4-6k'
              when monthly_income_loan <  8000  then '4_6-8k'
              when monthly_income_loan < 10000  then '5_8-10k'
              else                                   '6_>=10k'
         end                                                 as income_band -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
    from loan_deal
)
select
     loan_apply_date
    ,loan_apply_week
    ,risk_level
    ,income_band
    ,frequency
    ,quota_band
    ,product_user_type
    ,loan_seq_band
    ,strategy_type_loan
    ,strategy_type_credit
    ,is_white_list_user
    ,platform
    ,media_source
    ,campaign
    ,count(*)                                                as loan_apply_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_risk_pass)                                       as risk_pass_num -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_risk_decided)                                    as risk_decided_cnt -- 业务含义：【新增】风控已出结果的借款笔数（通过+拒绝，不含风控审核中及未进入风控），作为提款风控通过率分母
    ,sum(is_kyc_pass)                                        as kyc_pass_num -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(case when is_disburse_success = 1 then 1 else 0 end)        as loan_pass_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_disburse_success = 1
                         then loan_amount end), 2) as double)        as disburse_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,sum(case when is_disburse_success = 1 and loan_amount is not null
              then 1 else 0 end)                                     as loan_amount_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(monthly_income_loan), 2) as double)      as monthly_income_sum -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
    ,sum(case when monthly_income_loan is not null
              then 1 else 0 end)                             as monthly_income_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(model_score_loan), 6) as double)         as model_score_sum -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(case when model_score_loan is not null
              then 1 else 0 end)                             as model_score_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(dti), 6) as double)                      as dti_sum -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(case when dti is not null then 1 else 0 end)        as dti_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(case when is_disburse_success = 1
                and current_overdue_days > 0 then 1 else 0 end)      as current_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_disburse_success = 1
                          and current_overdue_days > 0
                         then loan_amount else 0 end), 2) as double)        as current_ovd_amt -- 业务含义：当前逾期借款的放款本金，非实际逾期敞口
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_contract_days is not null
                         then loan_term_contract_days end), 2) as double)
                                                             as loan_term_sum -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,sum(case when is_disburse_success = 1
               and loan_term_contract_days is not null
              then 1 else 0 end)                             as loan_term_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_contract_days is not null
                         then loan_amount * loan_term_contract_days end), 2) as double)
                                                             as loan_term_amt_wsum -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_contract_days is not null
                         then loan_amount end), 2) as double)
                                                             as loan_term_amt_wden -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_actual_days is not null
                         then loan_term_actual_days end), 2) as double)
                                                             as loan_term_actual_sum -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,sum(case when is_disburse_success = 1
               and loan_term_actual_days is not null
              then 1 else 0 end)                             as loan_term_actual_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_actual_days is not null
                         then loan_amount * loan_term_actual_days end), 2) as double)
                                                             as loan_term_actual_amt_wsum -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_actual_days is not null
                         then loan_amount end), 2) as double)
                                                             as loan_term_actual_amt_wden -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,cast(round(sum(case when is_disburse_success = 1
                         then quota_util_rate end), 6) as double)
                                                             as quota_util_sum -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(case when is_disburse_success = 1 and quota_util_rate is not null
              then 1 else 0 end)                             as quota_util_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(case when is_disburse_success = 1 and loan_seq is not null
               then loan_seq end)                            as loan_seq_sum -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,sum(case when is_disburse_success = 1 and loan_seq is not null
              then 1 else 0 end)                             as loan_seq_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(case when is_disburse_success = 1 and is_early_settlement is not null
              then 1 else 0 end)                             as settled_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(case when is_disburse_success = 1 and is_early_settlement = 1
              then 1 else 0 end)                             as early_settle_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,count(is_fpd3_obs)                                  as fpd3_denom -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_fpd3_obs)                                    as fpd3_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_fpd3_ovd)                                    as fpd3_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_fpd3_obs = 1 then loan_amount end), 2) as double) as fpd3_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(case when is_fpd3_ovd = 1 then loan_amount else 0 end), 2) as double) as fpd3_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,count(is_fpd7_obs)                                  as fpd7_denom -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_fpd7_obs)                                    as fpd7_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_fpd7_ovd)                                    as fpd7_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_fpd7_obs = 1 then loan_amount end), 2) as double) as fpd7_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(case when is_fpd7_ovd = 1 then loan_amount else 0 end), 2) as double) as fpd7_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,count(is_fpd15_obs)                                 as fpd15_denom -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_fpd15_obs)                                   as fpd15_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_fpd15_ovd)                                   as fpd15_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_fpd15_obs = 1 then loan_amount end), 2) as double) as fpd15_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(case when is_fpd15_ovd = 1 then loan_amount else 0 end), 2) as double) as fpd15_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,count(is_fpd30_obs)                                 as fpd30_denom -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_fpd30_obs)                                   as fpd30_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_fpd30_ovd)                                   as fpd30_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_fpd30_obs = 1 then loan_amount end), 2) as double) as fpd30_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(case when is_fpd30_ovd = 1 then loan_amount else 0 end), 2) as double) as fpd30_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,sum(is_1m_obs)                                      as mob1_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_1m30_ovd)                                    as mob1_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(amt_1m_obs),   2) as double)         as mob1_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(amt_1m30_ovd), 2) as double)         as mob1_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,sum(is_2m_obs)                                      as mob2_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_2m30_ovd)                                    as mob2_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(amt_2m_obs),   2) as double)         as mob2_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(amt_2m30_ovd), 2) as double)         as mob2_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,sum(case when risk_level_raw is not null
              then 1 else 0 end)                             as decision_hit_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,max(snapshot_time)                                      as snapshot_time -- 业务含义：明细数据快照时间
    ,current_timestamp()                                     as agg_snapshot_time -- 业务含义：汇总表生成时间
from loan_dim
group by
     loan_apply_date
    ,loan_apply_week
    ,risk_level
    ,income_band
    ,frequency
    ,quota_band
    ,product_user_type
    ,loan_seq_band
    ,strategy_type_loan
    ,strategy_type_credit
    ,is_white_list_user
    ,platform
    ,media_source
    ,campaign
;
drop table if exists edw_ewa.ads_risk_credit_monitor_cube;
create table edw_ewa.ads_risk_credit_monitor_cube as
with base as (
    select * from edw_ewa.dws_risk_credit_intake_dtl
)
,credit_apply as (
    select
         limit_apply_no
        ,max(user_id)                                        as user_id -- 业务含义：用户唯一标识
        ,max(credit_apply_time)                              as credit_apply_time -- 业务含义：授信申请时间
        ,max(credit_is_pass)                                 as credit_is_pass -- 业务含义：授信是否通过（1通过，0未通过）
        ,max(credit_limit)                                   as credit_limit -- 业务含义：授信额度
        ,max(risk_level_credit)                              as risk_level_credit -- 业务含义：授信决策风险等级
        ,max(strategy_type_credit)                           as strategy_type_credit -- 业务含义：授信决策策略类型
        ,max(default_frequency_credit)                       as default_frequency_credit -- 业务含义：授信决策时识别的发薪频率
        ,max(monthly_income_credit)                          as monthly_income_credit -- 业务含义：授信决策时折算的月收入
        ,max(model_score_credit)                             as model_score_credit -- 业务含义：授信决策模型分
        ,max(default_income_credit)                          as default_income_credit -- 业务含义：授信决策时识别的单期收入
        ,max(is_white_list_user_credit)                      as is_white_list_user_credit -- 业务含义：授信决策时白名单标记
        ,max(snapshot_time)                                  as snapshot_time -- 业务含义：明细数据快照时间
        ,min(product_user_type)                              as product_user_type -- 业务含义：产品侧新老客类型
        ,max(platform)                                       as platform -- 业务含义：AppsFlyer归因平台
        ,max(media_source)                                   as media_source -- 业务含义：AppsFlyer媒体来源映射
        ,max(campaign)                                       as campaign -- 业务含义：AppsFlyer活动/广告系列映射
    from base
    where credit_apply_time is not null
      and limit_apply_no    is not null
    group by limit_apply_no
)
,credit_user as (
    select
         user_id
        ,min(credit_apply_time)                              as first_apply_time -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        ,max(case when credit_is_pass = 1 then 1 else 0 end) as is_credit_pass -- 业务含义：业务状态/是否标记字段，通常1=是、0=否；NULL含义依上游流程而定
        ,count(*)                                            as apply_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
        ,max(snapshot_time)                                  as snapshot_time -- 业务含义：明细数据快照时间
        ,max(struct(
             credit_apply_time
            ,limit_apply_no
            ,risk_level_credit
            ,strategy_type_credit
            ,default_frequency_credit
            ,monthly_income_credit
            ,credit_limit
            ,model_score_credit
            ,default_income_credit
            ,is_white_list_user_credit
            ,product_user_type
         ))                                                  as latest -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        ,max(platform)                                       as platform -- 业务含义：AppsFlyer归因平台
        ,max(media_source)                                   as media_source -- 业务含义：AppsFlyer媒体来源映射
        ,max(campaign)                                       as campaign -- 业务含义：AppsFlyer活动/广告系列映射
    from credit_apply
    group by user_id
)
,loan_deal as (
    select
         loan_no
        ,max(user_id)                                        as user_id -- 业务含义：用户唯一标识
        ,max(product_user_type)                              as product_user_type -- 业务含义：产品侧新老客类型
        ,max(loan_apply_time)                                as loan_apply_time -- 业务含义：借款申请提交时间
        ,max(is_risk_pass)                                   as is_risk_pass -- 业务含义：借款风险审核是否通过（1通过，0未通过/审核中，NULL未进入）
        ,max(is_kyc_pass)                                    as is_kyc_pass -- 业务含义：KYC身份核验是否通过（1通过，0未通过/审核中，NULL未进入）
        ,max(is_disburse_success)                            as is_disburse_success -- 业务含义：放款是否成功（1成功，0失败/处理中，NULL未进入）
        ,max(loan_amount)                                    as loan_amount -- 业务含义：实际放款本金
        ,max(current_overdue_days)                           as current_overdue_days -- 业务含义：当前逾期天数
        ,max(loan_term_contract_days)                        as loan_term_contract_days -- 业务含义：合同借款期限（自然日）
        ,max(loan_term_actual_days)                          as loan_term_actual_days -- 业务含义：实际借款天数；未还款为空
        ,max(quota_util_rate)                                as quota_util_rate -- 业务含义：逐笔额度使用率=放款后预计在贷/有效总额度
        ,max(is_early_settlement)                            as is_early_settlement -- 业务含义：是否提前结清（1提前，0未提前，NULL无法判断）
        ,max(is_fpd3_obs)                                    as is_fpd3_obs -- 业务含义：FPD3观察是否成熟（1成熟，0未成熟）
        ,max(is_fpd3_ovd)                                    as is_fpd3_ovd -- 业务含义：是否发生FPD3逾期
        ,max(is_fpd7_obs)                                    as is_fpd7_obs -- 业务含义：FPD7观察是否成熟
        ,max(is_fpd7_ovd)                                    as is_fpd7_ovd -- 业务含义：是否发生FPD7逾期
        ,max(is_fpd15_obs)                                   as is_fpd15_obs -- 业务含义：FPD15观察是否成熟
        ,max(is_fpd15_ovd)                                   as is_fpd15_ovd -- 业务含义：是否发生FPD15逾期
        ,max(is_fpd30_obs)                                   as is_fpd30_obs -- 业务含义：FPD30观察是否成熟
        ,max(is_fpd30_ovd)                                   as is_fpd30_ovd -- 业务含义：是否发生FPD30逾期
        ,max(is_1m_obs)                                      as is_1m_obs -- 业务含义：是否进入放款后第1自然月观察期
        ,max(is_1m30_ovd)                                    as is_1m30_ovd -- 业务含义：第1观察月月末是否处于30天以上逾期状态
        ,max(is_2m_obs)                                      as is_2m_obs -- 业务含义：是否进入放款后第2自然月观察期
        ,max(is_2m30_ovd)                                    as is_2m30_ovd -- 业务含义：第2观察月月末是否处于30天以上逾期状态
        ,max(amt_1m_obs)                                     as amt_1m_obs -- 业务含义：第1观察月观察本金
        ,max(amt_1m30_ovd)                                   as amt_1m30_ovd -- 业务含义：第1观察月月末30+逾期对应放款本金
        ,max(amt_2m_obs)                                     as amt_2m_obs -- 业务含义：第2观察月观察本金
        ,max(amt_2m30_ovd)                                   as amt_2m30_ovd -- 业务含义：第2观察月月末30+逾期对应放款本金
    from base
    where loan_no is not null
    group by loan_no
)
,loan_rep as (
    select *
    from (
        select
             *
            ,row_number() over (
                 partition by user_id
                 order by case when is_disburse_success = 1 then 0 else 1 end
                         ,loan_apply_time desc
                         ,loan_no desc
             ) as rn -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        from loan_deal
    ) t
    where rn = 1
)
,credit_dim as (
    select
         u.user_id
        ,u.is_credit_pass
        ,u.apply_cnt
        ,u.snapshot_time
        ,u.latest.credit_limit                               as credit_limit -- 业务含义：授信额度
        ,u.latest.monthly_income_credit                      as monthly_income -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
        ,u.latest.default_income_credit                      as default_income -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
        ,u.latest.model_score_credit                         as model_score -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        ,u.latest.risk_level_credit                          as risk_level_raw -- 业务含义：风控决策风险等级
        ,to_date(date_trunc('DAY',  u.first_apply_time))     as credit_apply_date -- 业务含义：业务日期/时间字段或按自然月分组的日期标签
        ,to_date(date_trunc('WEEK', u.first_apply_time))     as credit_apply_week -- 业务含义：申请时间对应的自然周分组标签
        ,case when r.loan_no is not null then 1 else 0 end   as has_loan_apply -- 业务含义：借款/提款流程相关指标，具体口径见字段名
        ,r.is_risk_pass
        ,r.is_kyc_pass
        ,r.is_disburse_success
        ,r.loan_amount
        ,r.current_overdue_days
        ,r.loan_term_contract_days
        ,r.loan_term_actual_days
        ,r.quota_util_rate
        ,r.is_early_settlement
        ,r.is_fpd3_obs
        ,r.is_fpd3_ovd
        ,r.is_fpd7_obs
        ,r.is_fpd7_ovd
        ,r.is_fpd15_obs
        ,r.is_fpd15_ovd
        ,r.is_fpd30_obs
        ,r.is_fpd30_ovd
        ,r.is_1m_obs
        ,r.is_1m30_ovd
        ,r.is_2m_obs
        ,r.is_2m30_ovd
        ,r.amt_1m_obs
        ,r.amt_1m30_ovd
        ,r.amt_2m_obs
        ,r.amt_2m30_ovd
        ,coalesce(u.latest.product_user_type,        '(空)')  as product_user_type -- 业务含义：产品侧新老客类型
        ,coalesce(u.latest.risk_level_credit,        '(空)')  as risk_level -- 业务含义：风控决策风险等级
        ,coalesce(u.latest.default_frequency_credit, '(空)')  as frequency -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
        ,coalesce(u.latest.strategy_type_credit,     '(空)')  as strategy_type -- 业务含义：风控策略类型
        ,u.platform                                          as platform -- 业务含义：AppsFlyer归因平台
        ,u.media_source                                      as media_source -- 业务含义：AppsFlyer媒体来源映射
        ,u.campaign                                          as campaign -- 业务含义：AppsFlyer活动/广告系列映射
        ,coalesce(cast(u.latest.is_white_list_user_credit as string), '(空)')
                                                             as is_white_list_user -- 业务含义：业务状态/是否标记字段，通常1=是、0=否；NULL含义依上游流程而定
        ,case
              when u.latest.monthly_income_credit is null  then '0_未知'
              when u.latest.monthly_income_credit <  1200  then '1_<1.2k'
              when u.latest.monthly_income_credit <  4000  then '2_1.2-4k'
              when u.latest.monthly_income_credit <  6000  then '3_4-6k'
              when u.latest.monthly_income_credit <  8000  then '4_6-8k'
              when u.latest.monthly_income_credit < 10000  then '5_8-10k'
              else                                              '6_>=10k'
         end                                                 as income_band -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
    from credit_user u
    left join loan_rep r
      on u.user_id = r.user_id
)
select
     credit_apply_date
    ,credit_apply_week
    ,product_user_type
    ,risk_level
    ,income_band
    ,frequency
    ,strategy_type
    ,is_white_list_user
    ,platform
    ,media_source
    ,campaign
    ,count(*)                                                as application_user_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_credit_pass)                                     as pass_user_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(apply_cnt)                                          as application_deal_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_credit_pass = 1
                         then credit_limit end), 2) as double)       as credit_limit_sum -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(case when is_credit_pass = 1 and credit_limit is not null
              then 1 else 0 end)                                     as credit_limit_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(monthly_income), 2) as double)           as monthly_income_sum -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
    ,sum(case when monthly_income is not null
              then 1 else 0 end)                             as monthly_income_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_credit_pass = 1
                         then monthly_income end), 2) as double)
                                                             as monthly_income_pass_sum -- 业务含义：收入相关指标，具体为单期收入或月收入见字段名
    ,sum(case when is_credit_pass = 1 and monthly_income is not null
              then 1 else 0 end)                             as monthly_income_pass_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_disburse_success = 1
                          and default_income > 0
                         then credit_limit / default_income end), 6) as double)
                                                             as debt_burden_sum -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(case when is_disburse_success = 1
               and default_income > 0
               and credit_limit is not null
              then 1 else 0 end)                             as debt_burden_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(model_score), 6) as double)              as model_score_sum -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(case when model_score is not null
              then 1 else 0 end)                             as model_score_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(has_loan_apply)                                     as loan_apply_user_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_risk_pass)                                       as risk_pass_num -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_kyc_pass)                                        as kyc_pass_num -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(case when is_disburse_success = 1 then 1 else 0 end)        as loan_pass_user_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_disburse_success = 1
                         then loan_amount end), 2) as double)        as disburse_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,sum(case when is_disburse_success = 1 and loan_amount is not null
              then 1 else 0 end)                                     as loan_amount_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(case when is_disburse_success = 1
                and current_overdue_days > 0 then 1 else 0 end)      as current_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_disburse_success = 1
                          and current_overdue_days > 0
                         then loan_amount else 0 end), 2) as double)        as current_ovd_amt -- 业务含义：当前逾期借款的放款本金，非实际逾期敞口
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_contract_days is not null
                         then loan_term_contract_days end), 2) as double)
                                                             as loan_term_sum -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,sum(case when is_disburse_success = 1
               and loan_term_contract_days is not null
              then 1 else 0 end)                             as loan_term_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_contract_days is not null
                         then loan_amount * loan_term_contract_days end), 2) as double)
                                                             as loan_term_amt_wsum -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_contract_days is not null
                         then loan_amount end), 2) as double)
                                                             as loan_term_amt_wden -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_actual_days is not null
                         then loan_term_actual_days end), 2) as double)
                                                             as loan_term_actual_sum -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,sum(case when is_disburse_success = 1
               and loan_term_actual_days is not null
              then 1 else 0 end)                             as loan_term_actual_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_actual_days is not null
                         then loan_amount * loan_term_actual_days end), 2) as double)
                                                             as loan_term_actual_amt_wsum -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,cast(round(sum(case when is_disburse_success = 1
                          and loan_term_actual_days is not null
                         then loan_amount end), 2) as double)
                                                             as loan_term_actual_amt_wden -- 业务含义：借款/提款流程相关指标，具体口径见字段名
    ,cast(round(sum(case when is_disburse_success = 1
                         then quota_util_rate end), 6) as double)
                                                             as quota_util_sum -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(case when is_disburse_success = 1 and quota_util_rate is not null
              then 1 else 0 end)                             as quota_util_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(case when is_disburse_success = 1 and is_early_settlement is not null
              then 1 else 0 end)                             as settled_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(case when is_disburse_success = 1 and is_early_settlement = 1
              then 1 else 0 end)                             as early_settle_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,count(is_fpd3_obs)                                  as fpd3_denom -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_fpd3_obs)                                    as fpd3_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_fpd3_ovd)                                    as fpd3_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_fpd3_obs = 1 then loan_amount end), 2) as double) as fpd3_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(case when is_fpd3_ovd = 1 then loan_amount else 0 end), 2) as double) as fpd3_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,count(is_fpd7_obs)                                  as fpd7_denom -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_fpd7_obs)                                    as fpd7_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_fpd7_ovd)                                    as fpd7_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_fpd7_obs = 1 then loan_amount end), 2) as double) as fpd7_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(case when is_fpd7_ovd = 1 then loan_amount else 0 end), 2) as double) as fpd7_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,count(is_fpd15_obs)                                 as fpd15_denom -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_fpd15_obs)                                   as fpd15_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_fpd15_ovd)                                   as fpd15_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_fpd15_obs = 1 then loan_amount end), 2) as double) as fpd15_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(case when is_fpd15_ovd = 1 then loan_amount else 0 end), 2) as double) as fpd15_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,count(is_fpd30_obs)                                 as fpd30_denom -- 业务含义：业务统计字段；按字段名及所在汇总层级解释
    ,sum(is_fpd30_obs)                                   as fpd30_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_fpd30_ovd)                                   as fpd30_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(case when is_fpd30_obs = 1 then loan_amount end), 2) as double) as fpd30_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(case when is_fpd30_ovd = 1 then loan_amount else 0 end), 2) as double) as fpd30_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,sum(is_1m_obs)                                      as mob1_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_1m30_ovd)                                    as mob1_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(amt_1m_obs),   2) as double)         as mob1_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(amt_1m30_ovd), 2) as double)         as mob1_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,sum(is_2m_obs)                                      as mob2_obs_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,sum(is_2m30_ovd)                                    as mob2_ovd_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,cast(round(sum(amt_2m_obs),   2) as double)         as mob2_obs_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,cast(round(sum(amt_2m30_ovd), 2) as double)         as mob2_ovd_amt -- 业务含义：对应业务口径的金额/本金汇总；不一定等于实际逾期敞口
    ,sum(case when risk_level_raw is not null
              then 1 else 0 end)                             as decision_hit_cnt -- 业务含义：统计数量/件数；具体分母或分子含义由字段前缀确定
    ,max(snapshot_time)                                      as snapshot_time -- 业务含义：明细数据快照时间
    ,current_timestamp()                                     as agg_snapshot_time -- 业务含义：汇总表生成时间
from credit_dim
group by
     credit_apply_date
    ,credit_apply_week
    ,product_user_type
    ,risk_level
    ,income_band
    ,frequency
    ,strategy_type
    ,is_white_list_user
    ,platform
    ,media_source
    ,campaign
;