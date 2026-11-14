-- Master switch for the daily automation (rent cycle, owner reminders). Starts OFF so nothing is emailed or billed
-- the moment the scheduler is turned on. Turn it on when you are ready (and after the comparison):
--   update portal_settings set value = 'live' where key = 'automation_mode';
insert into portal_settings (key, value) values ('automation_mode', 'off') on conflict (key) do nothing;
