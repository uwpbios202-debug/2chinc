-- Friendly first warning to a tenant (Stephen, 10/12/2026), easy to repeat: one call names the unit, the lease rule (a code from
-- lease_breach_types), what was seen and the date to fix it by. It quotes the lease's own words, queues one email per person on the
-- active lease in the normal outbox batch (the daily run sends it) and saves a record in tenant_warnings.
-- It is NOT a breach notice: no cure period starts and nothing legal is begun. A formal notice still goes through the Notices page.
--
--   select tenant_friendly_warning('4', 'personal_property',
--     'During a walkthrough of the basement we found two bicycles and trash bags left on the floor near the storage bays', date '2026-10-16');
--
-- Staff can call it when signed in with two-step (staff session); the database owner can call it directly.

create table if not exists tenant_warnings (
  id bigint generated always as identity primary key,
  lease_id uuid not null references leases(id),
  unit_number text not null,
  breach_code text not null references lease_breach_types(code),
  what text not null,
  fix_by date not null,
  emailed_to int not null default 0,
  created_by text,
  created_at timestamptz not null default now()
);
alter table tenant_warnings enable row level security;

create or replace function tenant_friendly_warning(p_unit text, p_breach text, p_what text, p_fix_by date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_lease uuid; b lease_breach_types; v_phone text; v_n int; v_by text := coalesce(auth.email(), 'database');
begin
  if auth.uid() is not null and not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into b from lease_breach_types where code = p_breach and active;
  if b.code is null then raise exception 'Unknown lease rule: %', p_breach; end if;
  if length(trim(coalesce(p_what, ''))) < 10 then raise exception 'Say what was seen.'; end if;
  if p_fix_by is null or p_fix_by < current_date then raise exception 'Choose a date in the future to fix it by.'; end if;
  select l.id into v_lease from leases l join rental_units ru on ru.id = l.unit_id where ru.unit_number = p_unit and l.status = 'active' order by l.start_date desc limit 1;
  if v_lease is null then raise exception 'No active lease for unit %', p_unit; end if;
  v_phone := coalesce(nullif((select value from portal_settings where key = 'org_phone'), ''), '(262) 236-5443');
  v_n := lease_email_tenants(v_lease, b.title || ': please fix by ' || to_char(p_fix_by, 'FMDay, FMMonth FMDD'),
    '<p>' || repair_esc(trim(p_what)) || '.</p>'
    || '<p>The lease says (' || repair_esc(b.provision_ref) || '): &ldquo;' || repair_esc(b.lease_quote) || '&rdquo;</p>'
    || '<p>Please take care of this by <b>' || to_char(p_fix_by, 'FMDay, FMMonth FMDD, YYYY') || '</b>. This is a friendly first reminder, not a formal notice. '
    || 'If it is still not fixed after that date, we may follow the lease, and repeated issues can become a formal breach notice.</p>'
    || '<p>If you have questions, or you think this is not yours, call the office at ' || repair_esc(v_phone) || '.</p>', 'warning');
  insert into tenant_warnings (lease_id, unit_number, breach_code, what, fix_by, emailed_to, created_by) values (v_lease, p_unit, p_breach, trim(p_what), p_fix_by, v_n, v_by);
  return jsonb_build_object('unit', p_unit, 'emailed', v_n, 'fix_by', p_fix_by);
end;
$$;
revoke all on function tenant_friendly_warning(text, text, text, date) from public, anon;
grant execute on function tenant_friendly_warning(text, text, text, date) to authenticated;
