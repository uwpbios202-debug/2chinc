-- Runs the daily rent cycle at 12:01 AM Central (not a migration: it holds the project's
-- secret, so run it once in the Supabase SQL editor after filling in the two values).
--
-- pg_cron uses UTC and Central time moves with daylight saving, so the job is scheduled
-- at BOTH 05:01 and 06:01 UTC. One of them is 12:01 AM Central; the other lands an hour
-- earlier or later and does nothing, because the function decides "today" in Central time
-- and runs each job only once per day (rent_cycle_runs).
--
--   <PROJECT_REF>   the project's reference, e.g. hvnsgwfcjpakvhhkfsuy
--   <CYCLE_SECRET>  the RENT_CYCLE_SECRET set on the rent-cycle function

select cron.unschedule(jobid) from cron.job where jobname in ('rent-cycle-cdt', 'rent-cycle-cst');

select cron.schedule('rent-cycle-cdt', '1 5 * * *', $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/rent-cycle',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', '<CYCLE_SECRET>'),
    body := '{}'::jsonb);
$$);

select cron.schedule('rent-cycle-cst', '1 6 * * *', $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/rent-cycle',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', '<CYCLE_SECRET>'),
    body := '{}'::jsonb);
$$);
