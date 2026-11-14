-- Checks and money orders are an exception (Stephen, 10/18/2026): tenants and owners are steered to pay online. The mail-in
-- instructions are shown ONLY for a month in which the person has asked to pay by check; the request is automatic (no approval),
-- the office is emailed, and it covers that one calendar month (Central time).
--   * check_requests: one row per person per month. No policies: reached only through the two functions below.
--   * check_request_mine(kind): {active, month, instructions}. The instructions text is returned only while a request is active.
--   * check_request_make(kind): tenant or owner (never a "view as" session), idempotent for the month, emails the office and the person.
-- The owner past-due email and the owner portal no longer print the check text: dues_pay_instructions now says only to pay online.

create table if not exists check_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('tenant', 'owner')),
  tenant_id uuid references tenants(id) on delete cascade,
  owner_id uuid references condo_owners(id) on delete cascade,
  month date not null,
  created_at timestamptz not null default now(),
  check ((kind = 'tenant' and tenant_id is not null and owner_id is null) or (kind = 'owner' and owner_id is not null and tenant_id is null))
);
create unique index if not exists check_requests_tenant_month on check_requests (tenant_id, month) where tenant_id is not null;
create unique index if not exists check_requests_owner_month on check_requests (owner_id, month) where owner_id is not null;
alter table check_requests enable row level security;
revoke all on check_requests from anon, authenticated;

insert into portal_settings (key, value) values
  ('dues_pay_by_mail', 'Mail a check or money order payable to ROCA1 to 6626 North Bourbon Street, Milwaukee, WI 53224, and write your unit number on it.')
on conflict (key) do nothing;
update portal_settings set value = 'Pay online in your owner portal.' where key = 'dues_pay_instructions';

create or replace function check_request_month() returns date language sql stable as $$
  select date_trunc('month', now() at time zone 'America/Chicago')::date;
$$;
revoke all on function check_request_month() from public, anon, authenticated;

create or replace function check_request_who(p_kind text, out v_tenant uuid, out v_owner uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_kind = 'tenant' then
    if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
    v_tenant := autopay_me();
    if v_tenant is null then raise exception 'Paying by check is for an active lease.'; end if;
  elsif p_kind = 'owner' then
    if not condo_session_ok() then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
    v_owner := condo_owner_for_email(auth.email());
    if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  else
    raise exception 'Unknown kind';
  end if;
end;
$$;
revoke all on function check_request_who(text) from public, anon, authenticated;

create or replace function check_request_mine(p_kind text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare w record; v_active boolean;
begin
  select * into w from check_request_who(p_kind);
  select exists (select 1 from check_requests c where c.month = check_request_month()
                   and ((p_kind = 'tenant' and c.tenant_id = w.v_tenant) or (p_kind = 'owner' and c.owner_id = w.v_owner))) into v_active;
  return jsonb_build_object('active', v_active, 'month', to_char(check_request_month(), 'FMMonth YYYY'),
    'instructions', case when not v_active then null when p_kind = 'owner' then condo_setting('dues_pay_by_mail', '') else condo_setting('pay_by_mail', '') end);
end;
$$;
revoke all on function check_request_mine(text) from public, anon;
grant execute on function check_request_mine(text) to authenticated;

create or replace function check_request_make(p_kind text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare w record; v_name text; v_email text; v_month text := to_char(check_request_month(), 'FMMonth YYYY'); v_n int;
begin
  select * into w from check_request_who(p_kind);
  if autopay_view_as_session() then raise exception 'Only the person themselves can ask to pay by check.'; end if;
  if p_kind = 'tenant' then
    select name, email into v_name, v_email from tenants where id = w.v_tenant;
    insert into check_requests (kind, tenant_id, month) values ('tenant', w.v_tenant, check_request_month()) on conflict do nothing;
  else
    select name into v_name from condo_owners where id = w.v_owner;
    v_email := auth.email();
    insert into check_requests (kind, owner_id, month) values ('owner', w.v_owner, check_request_month()) on conflict do nothing;
  end if;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform autopay_email('info@2ndchinc.org', '[Check request] ' || coalesce(v_name, 'Someone') || ' will pay by check for ' || v_month,
      '<p>' || repair_esc(coalesce(v_name, '')) || ' (' || case when p_kind = 'owner' then 'owner' else 'tenant' end || ', ' || repair_esc(coalesce(v_email, '')) || ') asked to pay by check or money order for <b>' || v_month
      || '</b>. They can now see the mail-in instructions in their portal. Watch for the check, and record it when it arrives.</p>', 'check_request');
    if coalesce(v_email, '') like '%@%' then
      perform autopay_email(v_email, 'You can pay by check for ' || v_month,
        '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>You asked to pay by check or money order for <b>' || v_month
        || '</b>. The mail-in instructions are now in your portal, under Payments. This covers ' || v_month || ' only; paying online is faster and shows on your account right away.</p><p>2nd Chance Housing</p>', 'check_request');
    end if;
  end if;
  return check_request_mine(p_kind);
end;
$$;
revoke all on function check_request_make(text) from public, anon;
grant execute on function check_request_make(text) to authenticated;

-- The owner account page also states the late-fee policy. Since 10/8/2026 the charge on the 12th is 4.5% a year simple interest on
-- unpaid dues, not a percentage of the balance: send the annual rate along so the page can say so.
do $$
declare d text;
begin
  d := pg_get_functiondef('condo_my_account()'::regprocedure);
  if position('''pct'', condo_setting(''dues_late_pct'', ''1.15'')' in d) = 0 then raise exception 'late_policy text not found'; end if;
  execute replace(d, '''pct'', condo_setting(''dues_late_pct'', ''1.15'')', '''annual'', condo_setting(''dues_interest_annual_pct'', ''4.5''), ''pct'', condo_setting(''dues_late_pct'', ''1.15'')');
end $$;
