-- Official office number (confirmed by Stephen, 10/4/2026; PayPal and signed
-- documents use it). (414) 909-3279 stays the maintenance / emergency line.
insert into portal_settings (key, value) values ('org_phone', '(262) 236-5443'), ('org_email', 'info@2ndchinc.org'), ('emergency_phone', '(414) 909-3279')
on conflict (key) do update set value = excluded.value;
