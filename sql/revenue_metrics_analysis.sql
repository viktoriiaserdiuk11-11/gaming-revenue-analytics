-- переглядаю перші рядки таблиці платежів
select *
from project.games_payments
limit 50;

-- переглядаю перші рядки таблиці платних користувачів
select *
from project.games_paid_users
limit 50;

-- перевіряю кількість рядків, пропуски, період даних і діапазон revenue
select
    count(*) as total_rows,
    count(user_id) as user_id_is_not_null,
    count(game_name) as game_name_is_not_null,
    count(payment_date) as payment_date_is_not_null,
    count(revenue_amount_usd) as revenue_is_not_null,
    min(payment_date) as min_payment_date,
    max(payment_date) as max_payment_date,
    min(revenue_amount_usd) as min_revenue,
    max(revenue_amount_usd) as max_revenue,
    round(sum(revenue_amount_usd), 2) as total_revenue
from project.games_payments;

-- перевіряю кількість користувачів, пропуски, кількість ігор, мов і діапазон віку
select
    count(*) as total_rows,
    count(user_id) as user_id_is_not_null,
    count(game_name) as game_name_is_not_null,
    count(language) as language_is_not_null,
    count(age) as age_is_not_null,
    count(has_older_device_model) as device_model_is_not_null,
    count(distinct user_id) as unique_users,
    count(distinct game_name) as games_count,
    count(distinct language) as languages_count,
    min(age) as min_age,
    max(age) as max_age
from project.games_paid_users;

--перевірка JOIN між платежами і користувачами
select
    count(*) as rows_after_join,
    count(gp.user_id) as payments_users_not_null,
    count(gpu.user_id) as matched_users
from project.games_payments gp
left join project.games_paid_users gpu
    on gp.user_id = gpu.user_id
   and gp.game_name = gpu.game_name;

--перевірка дублікатів 
--було знайдено дублікат,але не видаляю цей рядок
--без transaction_id або точного часу платежу неможливо довести повтор
select
    user_id,
    game_name,
    payment_date,
    revenue_amount_usd,
    count(*) as rows_count
from project.games_payments
group by
    user_id,
    game_name,
    payment_date,
    revenue_amount_usd
having count(*) > 1
order by rows_count desc;

--контрольна помісячна таблиця метрик

with monthly_revenue as (
select
        gp.user_id,
        gp.game_name,
        gpu.language,
        gpu.age,
        gpu.has_older_device_model,
        date(date_trunc('month', gp.payment_date)) as payment_month,
        sum(gp.revenue_amount_usd) as total_revenue
from project.games_payments gp
left join project.games_paid_users gpu
	on gp.user_id = gpu.user_id
	and gp.game_name = gpu.game_name
group by
        gp.user_id,
        gp.game_name,
        gpu.language,
        gpu.age,
        gpu.has_older_device_model,
        date(date_trunc('month', gp.payment_date))
),

user_months as (
-- додаю попередній і наступний календарний місяць
-- визначаю попередній та наступний місяць, коли користувач платив
select *,
        date(payment_month - interval '1 month') as previous_calendar_month,
        date(payment_month + interval '1 month') as next_calendar_month,
        lag(payment_month) 
over (partition by user_id, game_name order by payment_month) as previous_paid_month,
        lead(payment_month) 
over (partition by user_id, game_name order by payment_month) as next_paid_month,
        lag(total_revenue) 
over (partition by user_id, game_name order by payment_month) as previous_month_revenue
from monthly_revenue
),
user_metrics as (
-- new MRR дохід користувача у перший місяць його оплати
-- new Paid Users користувачі, які вперше з'явились у платежах
select *,
case
when previous_paid_month is null then total_revenue
		else 0
		end as new_mrr,
case
when previous_paid_month is null then 1
		else 0
		end as new_paid_users
from user_months
),
churn_metrics as (
-- користувач вважається churned, якщо в наступному календарному місяці оплати немає
-- churn переноситься на наступний місяць, тому churn_month = next_calendar_month
-- якщо користувач платив у березні, але не платив у квітні,його churn показується у квітні
select *,
case
when next_paid_month is null
		or next_paid_month <> next_calendar_month
then next_calendar_month
		end as churn_month,
case
when next_paid_month is null
		or next_paid_month <> next_calendar_month
then total_revenue
		else 0
		end as churned_revenue,
case
when next_paid_month is null
		or next_paid_month <> next_calendar_month
then 1
		else 0
		end as churned_users
from user_metrics
),

revenue_change_metrics as (
-- expansion MRR користувач платив у попередньому місяці і в поточному заплатив більше.
-- contraction MRR користувач платив у попередньому місяці і в поточному заплатив менше.
select *,
case
when previous_paid_month = previous_calendar_month
		and total_revenue > previous_month_revenue
then total_revenue - previous_month_revenue
		else 0
		end as expansion_mrr,
case
when previous_paid_month = previous_calendar_month
		and total_revenue < previous_month_revenue
then total_revenue - previous_month_revenue
		else 0
		end as contraction_mrr
from churn_metrics
),

back_from_churn_metrics as (
    -- back_from_churn користувач повернувся після пропуску одного або кількох місяців
    -- якщо попередній платіжний місяць існує, але він не є попереднім календарним місяцем, значить між оплатами була пауза.
select *,
case
when previous_paid_month is not null
		and previous_paid_month <> previous_calendar_month
then total_revenue
		else 0
		end as back_from_churn_mrr,
case
when previous_paid_month is not null
		and previous_paid_month <> previous_calendar_month
then 1
		else 0
		end as back_from_churn_users
from revenue_change_metrics
),

monthly_metrics as (
--  основні метрики по місяцях
select
        payment_month,
        round(sum(total_revenue), 2) as mrr,
        count(distinct user_id) as paid_users,
        round(sum(total_revenue) / count(distinct user_id), 2) as arppu,
        round(sum(new_mrr), 2) as new_mrr,
        sum(new_paid_users) as new_paid_users,
        round(sum(back_from_churn_mrr), 2) as back_from_churn_mrr,
        sum(back_from_churn_users) as back_from_churn_users,
        round(sum(expansion_mrr), 2) as expansion_mrr,
        round(sum(contraction_mrr), 2) as contraction_mrr
from back_from_churn_metrics
group by payment_month
),

churn_by_month as (
-- churn_метрики по churn_month.
-- churn_month після останнього місяця даних не включаю.
select
        date(churn_month) as payment_month,
        sum(churned_users) as churned_users,
        round(sum(churned_revenue), 2) as churned_revenue
from back_from_churn_metrics
where churn_month is not null
		and date(churn_month) <= (
select max(payment_month)
from monthly_revenue
)
group by date(churn_month)
)
select
    mm.payment_month,
    mm.mrr,
    mm.paid_users,
    mm.arppu,
    mm.new_mrr,
    mm.new_paid_users,
    coalesce(cbm.churned_users, 0) as churned_users,
    coalesce(cbm.churned_revenue, 0) as churned_revenue,
    round(coalesce(cbm.churned_users, 0)::numeric / nullif(lag(mm.paid_users) over (order by mm.payment_month), 0),4) as churn_rate,
    round(coalesce(cbm.churned_revenue, 0) / nullif(lag(mm.mrr) over (order by mm.payment_month), 0), 4) as revenue_churn_rate,
    round(1 / nullif(coalesce(cbm.churned_users, 0)::numeric/ nullif(lag(mm.paid_users) over (order by mm.payment_month), 0),0),2) as lt,
    round(mm.arppu * (1 / nullif(coalesce(cbm.churned_users, 0)::numeric/ nullif(lag(mm.paid_users) over (order by mm.payment_month), 0),0)),2) as ltv,
    mm.back_from_churn_mrr,
    mm.back_from_churn_users,
    mm.expansion_mrr,
    mm.contraction_mrr
from monthly_metrics mm
left join churn_by_month cbm
    on mm.payment_month = cbm.payment_month
order by mm.payment_month;

--фінальна  таблиця для Tableau

with monthly_revenue as (
select
        gp.user_id,
        gp.game_name,
        gpu.language,
        gpu.age,
        gpu.has_older_device_model,
        date(date_trunc('month', gp.payment_date)) as payment_month,
        sum(gp.revenue_amount_usd) as total_revenue
from project.games_payments gp
left join project.games_paid_users gpu
		on gp.user_id = gpu.user_id
		and gp.game_name = gpu.game_name
group by
        gp.user_id,
        gp.game_name,
        gpu.language,
        gpu.age,
        gpu.has_older_device_model,
        date(date_trunc('month', gp.payment_date))
),

user_months as (
select *,
        date(payment_month - interval '1 month') as previous_calendar_month,
        date(payment_month + interval '1 month') as next_calendar_month,
        lag(payment_month) over (partition by user_id, game_name
            order by payment_month) as previous_paid_month,
        lead(payment_month) over (partition by user_id, game_name
            order by payment_month) as next_paid_month,
        lag(total_revenue) over (partition by user_id, game_name
            order by payment_month) as previous_month_revenue
from monthly_revenue
),

user_metrics as (
select *,
case
when previous_paid_month is null then total_revenue
		else 0
		end as new_mrr,
case
when previous_paid_month is null then 1
		else 0
		end as new_paid_users
from user_months
),

churn_metrics as (
select *,
case
when next_paid_month is null
		or next_paid_month <> next_calendar_month
then next_calendar_month
		end as churn_month,
case
when next_paid_month is null
		or next_paid_month <> next_calendar_month
then total_revenue
		else 0
		end as churned_revenue,
case
when next_paid_month is null
		or next_paid_month <> next_calendar_month
		then 1
		else 0
		end as churned_users
from user_metrics
),

revenue_change_metrics as (
select *,
case
when previous_paid_month = previous_calendar_month
		and total_revenue > previous_month_revenue
then total_revenue - previous_month_revenue
		else 0
		end as expansion_mrr,
case
when previous_paid_month = previous_calendar_month
		and total_revenue < previous_month_revenue
		then total_revenue - previous_month_revenue
		else 0
		end as contraction_mrr
from churn_metrics
),

back_from_churn_metrics as (
select *,
case
when previous_paid_month is not null
		and previous_paid_month <> previous_calendar_month
then total_revenue
		else 0
		end as back_from_churn_mrr,
case
when previous_paid_month is not null
		and previous_paid_month <> previous_calendar_month
then 1
		else 0
		end as back_from_churn_users
from revenue_change_metrics
),

max_data_month as (
-- окремо зберігаю останній місяць даних, щоб не виводити технічний churn за 2023-01.
select max(payment_month) as max_payment_month
from monthly_revenue
)

select
    bfcm.user_id,
    bfcm.game_name,
    bfcm.language,
    bfcm.age,
    bfcm.has_older_device_model,
    bfcm.payment_month,
    round(bfcm.total_revenue, 2) as total_revenue,
    round(bfcm.new_mrr, 2) as new_mrr,
    bfcm.new_paid_users,
case
when bfcm.churn_month is not null
		and date(bfcm.churn_month) <= mdm.max_payment_month
then date(bfcm.churn_month)
		end as churn_month,
case
when bfcm.churn_month is not null
		and date(bfcm.churn_month) <= mdm.max_payment_month
then round(bfcm.churned_revenue, 2)
		else 0
		end as churned_revenue,
case
when bfcm.churn_month is not null
		and date(bfcm.churn_month) <= mdm.max_payment_month
then bfcm.churned_users
		else 0
		end as churned_users,
	round(bfcm.back_from_churn_mrr, 2) as back_from_churn_mrr,
    bfcm.back_from_churn_users,
	round(bfcm.expansion_mrr, 2) as expansion_mrr,
	round(bfcm.contraction_mrr, 2) as contraction_mrr
from back_from_churn_metrics bfcm
cross join max_data_month mdm
order by
    bfcm.payment_month,
    bfcm.game_name,
    bfcm.language,
    bfcm.age,
    bfcm.user_id;

