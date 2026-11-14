-- LOCAL ONLY (gitignored, never pushed): more investors who may sign in. Apply from this PC with `supabase db push`.
insert into investors (email, name) values
  ('singh@singhmakeovers.com', 'Singh Makeovers'),
  ('dhunna72@gmail.com', 'Dhunna'),
  ('dhunna@msn.com', 'Dhunna')
on conflict (lower(email)) do nothing;
