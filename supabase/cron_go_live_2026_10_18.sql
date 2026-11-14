-- ONE-TIME: turns the master automation switch ON at 12:00 AM Central on Sunday October 18, 2026.
-- Scheduled live on 10/9/2026; moved from Oct 12 to Oct 18 on 10/11/2026 (Stephen). Not a migration: pg_cron is a live-project setting.
-- Read docs/automation-go-live.md before changing or cancelling this.
--
-- pg_cron uses UTC. Chicago is on daylight time (UTC-5) until Nov 1, 2026, so 05:00 UTC on Oct 18 is 12:00 AM
-- Central. That is one minute BEFORE the daily rent cycle (rent-cycle-cdt, 05:01 UTC = 12:01 AM Central), so the
-- 12:01 AM run on Oct 18 is the first live run. The job only acts inside a one-day window and then removes itself.
--
-- To cancel before it fires:   select cron.unschedule('automation-go-live-2026-10-18');
-- To turn automation off again: update portal_settings set value = 'off' where key = 'automation_mode';

select cron.unschedule(jobid) from cron.job where jobname = 'automation-go-live-2026-10-18';

select cron.schedule('automation-go-live-2026-10-18', '0 5 18 10 *', $$
  update portal_settings set value = 'live'
   where key = 'automation_mode' and now() >= timestamptz '2026-10-18 05:00:00+00' and now() < timestamptz '2026-10-19 05:00:00+00';
  select cron.unschedule(jobid) from cron.job where jobname = 'automation-go-live-2026-10-18';
$$);
