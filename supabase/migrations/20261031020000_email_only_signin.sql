-- Sign-in is now the emailed 6-digit code only (Stephen 10/5/2026). The texted
-- code step (Twilio Verify, condo-owner-sms) is dropped.
--
-- Every portal function gates on condo_session_ok(). It used to mean "this
-- session also passed the text code in the last 12 hours"; it now means "this
-- request has a signed-in Supabase session". Supabase only issues one after the
-- emailed code is entered. Who may see what is still decided by the role checks
-- in each function (owner / staff / agent / resident match on the email).
create or replace function condo_session_ok()
returns boolean
language sql stable security definer set search_path = public
as $$
  select auth.uid() is not null;
$$;
