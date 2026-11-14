-- Daily jobs for the LIVE project. Contains secrets: lives in data/ (gitignored). Never commit it.
-- Run once in the Supabase SQL editor AFTER enabling the pg_cron and pg_net extensions.
-- pg_cron uses UTC and Central time moves with daylight saving, so the rent cycle is scheduled at BOTH 05:01 and 06:01 UTC;
-- the function decides "today" in Central time and runs each job once a day, so only one of them does anything.
select cron.unschedule(jobid) from cron.job where jobname in ('rent-cycle-cdt', 'rent-cycle-cst', 'condo-owner-reminders', 'apply-purge');

select cron.schedule('rent-cycle-cdt', '1 5 * * *', $$
  select net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/rent-cycle',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', 'a2969164411ce2c5ca47eb0eeb163a5ed97d50663e76a1ff'), body := '{}'::jsonb);
$$);
select cron.schedule('rent-cycle-cst', '1 6 * * *', $$
  select net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/rent-cycle',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', 'a2969164411ce2c5ca47eb0eeb163a5ed97d50663e76a1ff'), body := '{}'::jsonb);
$$);
-- Owner 6-month confirmation reminders, 9 am Central (14:00 UTC in summer, 15:00 in winter; either is fine)
select cron.schedule('condo-owner-reminders', '0 14 * * *', $$
  select net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/condo-owner-reminders',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', '9109fd9964ae4e701af81b524a4516c690df927b40eff1c4'), body := '{}'::jsonb);
$$);
-- Delete unfinished applications and old saved drafts on schedule
select cron.schedule('apply-purge', '30 7 * * *', $$
  select net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/rental-apply',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-purge-secret', '6d516784d6f4fffa522c61b3b081a11d5b912e4d19e90d9c'), body := '{"action":"purge"}'::jsonb);
$$);
select jobname, schedule, active from cron.job order by jobname;

-- Bank feed: pull new deposits every morning (6 am Central in summer). The function ignores this until Plaid is connected.
select cron.unschedule(jobid) from cron.job where jobname = 'bank-sync';
select cron.schedule('bank-sync', '0 11 * * *', $$
  select net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/bank-feed',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', 'a2969164411ce2c5ca47eb0eeb163a5ed97d50663e76a1ff'), body := '{"action":"sync"}'::jsonb);
$$);
