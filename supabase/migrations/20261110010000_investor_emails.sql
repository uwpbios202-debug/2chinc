-- LOCAL ONLY (gitignored, never pushed): the investors who may sign in. Apply from this PC with `supabase db push`.
-- Add each new investor email as another row, or insert it in the SQL editor.
insert into investors (email, name) values
  ('tlndresearch@yahoo.com', 'TLND Research')
on conflict (lower(email)) do nothing;
