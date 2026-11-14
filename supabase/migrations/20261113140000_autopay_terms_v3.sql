-- Autopay terms v3 (Stripe's ACH wording checklist, 10/18/2026). Autopay is still OFF; nobody is enrolled.
--   * the tenant authorizes a credit to correct an erroneous debit;
--   * how to stop a withdrawal by email or phone (staff then PAUSE it; they cannot start or change it);
--   * the tenant is told they get an emailed copy, and the "you set up autopay" email now carries the full signed text;
--   * where each payment can be seen (portal Payments).
-- New terms version autopay-2026-10-v3: a page still showing v2 is asked to reload.

create or replace function autopay_terms(p_name text, p_amount numeric, p_day int, p_label text, p_is_lease boolean, p_first date)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_fee text := coalesce(nullif((select value from portal_settings where key = 'returned_payment_fee'), ''), '0');
begin
  return 'AUTOPAY AUTHORIZATION' || E'\n\n'
    || 'I, ' || p_name || ', authorize 2nd Chance Housing Inc. to electronically debit the bank account I connect, and, if necessary, to electronically credit that account to correct an erroneous debit, to pay my '
       || case when p_is_lease then 'rent for ' else 'land contract payment for ' end || p_label || '.' || E'\n\n'
    || '• Amount: ' || to_char(p_amount, 'FM$999,990.00') || ' each month, or less if I owe less. It will never be more than this unless I approve a new amount myself.' || E'\n'
    || '• Date: on the ' || p_day || case p_day when 1 then 'st' when 2 then 'nd' when 3 then 'rd' else 'th' end || ' of each month. My first withdrawal is ' || to_char(p_first, 'FMMonth FMDD, YYYY') || '.' || E'\n'
    || '• Reminders: I will get an email 10 days, 7 days, 3 days and 1 day before each withdrawal, with its date and the most it can be, and an email on the day with the exact amount. If the 1-day reminder cannot be sent to me, no money is withdrawn that month.' || E'\n'
    || '• Varying amount: I have the right to be told the amount and date of every withdrawal at least 10 days before it. I agree that each withdrawal is what I owe that day and may be any amount up to the amount above, and I choose to be told the exact amount ahead of time only if it would be more than that amount (which autopay never does).' || E'\n'
    || '• Stopping it: I can cancel any time in my portal (Payments, Autopay, Cancel). To stop a withdrawal, I cancel before 11:59 PM the day before it. I can also email info@2ndchinc.org or call or text (262) 236-5443 at least 3 business days before a withdrawal, and staff will pause it. I can revoke this authorization at any time.' || E'\n'
    || '• If my account does not have enough money: the withdrawal may be returned. Then my ' || case when p_is_lease then 'rent' else 'payment' end || ' is still due'
       || case when p_is_lease and v_fee::numeric > 0 then ', a returned payment fee of ' || to_char(v_fee::numeric, 'FM$999,990.00') || ' may be charged (as my lease provides)' else '' end
       || ', late fees and notices follow the normal schedule, my bank may also charge me, and autopay pauses until I turn it on again myself. There is no automatic second try.' || E'\n'
    || '• Only I can turn autopay on or change it. 2nd Chance staff cannot start or change it. Staff can pause it for safety, and I am emailed right away.' || E'\n'
    || '• If my ' || case when p_is_lease then 'rent' else 'payment' end || ' changes, autopay keeps withdrawing no more than the amount above until I approve a new amount.' || E'\n'
    || '• My copy: when autopay is set up I will be emailed a copy of this authorization, and I should keep it. Every payment also shows in my portal under Payments.' || E'\n\n'
    || 'I set this up myself, from my own sign-in.';
end;
$$;
revoke all on function autopay_terms(text, numeric, int, text, boolean, date) from public, anon, authenticated;

-- The version string lives in the two setup functions; the "set up" email is in autopay_activate. Rewrite their current definitions
-- in place (and fail loudly if an expected piece is not there).
do $$
declare d text; n text;
begin
  foreach n in array array['autopay_prepare(integer)', 'autopay_start(text,integer,text,jsonb,text,date)'] loop
    d := pg_get_functiondef(n::regprocedure);
    if position('autopay-2026-10-v2' in d) = 0 then raise exception 'version string not found in %', n; end if;
    execute replace(d, 'autopay-2026-10-v2', 'autopay-2026-10-v3');
  end loop;

  d := pg_get_functiondef('autopay_activate(uuid,text,text,text,text,text,text)'::regprocedure);
  if position('''<p>If you did not do this, cancel it now' in d) = 0 then raise exception 'activation email text not found'; end if;
  execute replace(d, '''<p>If you did not do this, cancel it now',
    '''<p><b>Your copy of what you agreed to:</b></p><pre style="white-space:pre-wrap;font:inherit">'' || repair_esc(a.terms_text) || ''</pre>'' || ''<p>If you did not do this, cancel it now');
end $$;
