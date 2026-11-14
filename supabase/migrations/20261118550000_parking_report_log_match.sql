-- The delivery log (email_log) files the launch emails under kind 'other', so the nightly parking report finds them by subject and time.
-- No new table, so no new grants.
do $$ declare v text := pg_get_functiondef('parking_launch_report()'::regprocedure); n text; begin
  n := replace(v, 'where lower(l.to_email) = pe.email and l.kind = ''parking_launch''',
                  'where lower(l.to_email) = pe.email and l.subject like ''Parking%November 18%'' and l.sent_at >= v_launch - interval ''10 minutes''');
  if n = v then raise exception 'parking_launch_report changed; update this migration'; end if;
  execute n;
end $$;

-- Count people, not rows (an owner with three stalls is one person).
do $$ declare v text := pg_get_functiondef('parking_launch_report()'::regprocedure); n text; begin
  n := replace(v, 'select pe.unit, case when pe.kind', 'select pe.unit, pe.email, case when pe.kind');
  n := replace(n, 'count(*) filter (where r.emailed) || '' emailed · '' || count(*) filter (where r.signed_in is not null) || '' signed in since the email · ''
      || count(*) filter (where r.rules) || '' signed the rules · ''',
    'count(distinct r.email) filter (where r.emailed) || '' people emailed · '' || count(distinct r.email) filter (where r.signed_in is not null) || '' signed in since the email · ''
      || count(distinct r.email) filter (where r.rules) || '' signed the rules · ''');
  if n = v or position('people emailed' in n) = 0 or position('pe.email, case' in n) = 0 then raise exception 'parking_launch_report changed (counts); update this migration'; end if;
  execute n;
end $$;
