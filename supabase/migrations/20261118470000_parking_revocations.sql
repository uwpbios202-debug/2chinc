-- Parking revoked for an unpaid balance: an office switch (Stephen, 11/8/2026). Parking rule 20: "If your account has an unpaid balance, your
-- parking is revoked and your vehicle is towed." The office decides each case on https://2ndchinc.org/parking/ ("Revoke parking" /
-- "Restore parking"), with the reason; nothing is automatic. While revoked: the stall shows NO PARKING on every map and "Your stall" card,
-- on Always Towing's page, and the unit cannot raise stall alerts. Optionally the unit's people (and its owner) are emailed at each change.
-- The old setting parking_blocked_units still works (kept for compatibility); the revocations table is the normal way now.
-- New table parking_revocations: explicit grants (Supabase change of 10/30/2026).

create table if not exists parking_revocations (
  id uuid primary key default gen_random_uuid(),
  unit_number text not null,
  reason text not null,
  revoked_at timestamptz not null default now(),
  revoked_by text,
  restored_at timestamptz,
  restored_by text,
  restore_note text
);
create unique index if not exists parking_revocations_open on parking_revocations (unit_number) where restored_at is null;
alter table parking_revocations enable row level security;
revoke all on parking_revocations from public, anon, authenticated;
grant all on parking_revocations to service_role;

-- Every revoked unit (no sign-in check: for internal callers such as Always Towing's page).
create or replace function parking_blocked_list()
returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct u), '{}') from (
    select trim(x) as u from unnest(string_to_array(condo_setting('parking_blocked_units', ''), ',')) x where trim(x) <> ''
    union all
    select unit_number from parking_revocations where restored_at is null) z;
$$;
revoke all on function parking_blocked_list() from public, anon, authenticated;

create or replace function parking_blocked_units()
returns text[]
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then '{}'::text[] else parking_blocked_list() end;
$$;
revoke all on function parking_blocked_units() from public, anon;
grant execute on function parking_blocked_units() to authenticated;

-- Always Towing's page reads the same list.
do $$ declare v text := pg_get_functiondef('tow_lot_view()'::regprocedure); n text; begin
  n := replace(v, 'coalesce((select array_agg(trim(x)) from unnest(string_to_array(condo_setting(''parking_blocked_units'', ''''), '','')) x where trim(x) <> ''''), ''{}'')',
                  'parking_blocked_list()');
  if n = v then raise exception 'tow_lot_view changed; update this migration'; end if;
  execute n;
end $$;

-- People to tell: who lives there (tenants, owner-occupant, Unit 6's person) and the unit's owner.
create or replace function parking_revoke_notify(p_unit text, p_subject text, p_body text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select distinct on (x.email) x.email, x.name from (
      select lower(p.email) email, p.name from parking_unit_people(p_unit) p where p.email like '%@%'
      union all
      select lower(o.email), o.name from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current join condo_owners o on o.id = s.owner_id
       where cu.unit_number = p_unit and o.email like '%@%') x order by x.email loop
    insert into email_outbox (to_email, subject, html, kind) values (r.email, p_subject,
      '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>Hi ' || repair_esc(split_part(coalesce(r.name, ''), ' ', 1)) || ',</p>' || p_body
      || '<p style="color:#5b6573;font-size:13px">2nd Chance Housing, ' || repair_esc(condo_setting('org_phone', '')) || ', info@2ndchinc.org</p></div>', 'parking_revoke');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function parking_revoke_notify(text, text, text) from public, anon, authenticated;

-- Staff list: every unit stall, what is owed (tenant rent due; association account balance), and any revocation.
create or replace function parking_revocations_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('unit', s.home_unit,
      'rent_due', (select sum(lease_rent_due(l.id, current_date)) from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number = s.home_unit),
      'tenant_balance', (select sum(e.amount) from lease_ledger_entries e join leases l on l.id = e.lease_id join rental_units ru on ru.id = l.unit_id
                          where l.status = 'active' and ru.unit_number = s.home_unit),
      'dues_balance', (select condo_account_balance(roca_unit_account(s.home_unit), current_date)),
      'legacy_setting', s.home_unit = any (string_to_array(replace(condo_setting('parking_blocked_units', ''), ' ', ''), ',')),
      'revocation', (select jsonb_build_object('id', r.id, 'reason', r.reason, 'revoked_at', r.revoked_at, 'revoked_by', r.revoked_by)
                       from parking_revocations r where r.unit_number = s.home_unit and r.restored_at is null),
      'history', (select count(*) from parking_revocations r where r.unit_number = s.home_unit and r.restored_at is not null))
    order by nullif(regexp_replace(s.home_unit, '\D', '', 'g'), '')::int) from parking_stalls s where s.kind = 'unit' and s.active), '[]'::jsonb);
end;
$$;
revoke all on function parking_revocations_staff() from public, anon;
grant execute on function parking_revocations_staff() to authenticated;

create or replace function parking_revoke(p_unit text, p_reason text, p_notify boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r parking_revocations; n int := 0;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  if not exists (select 1 from parking_stalls where kind = 'unit' and active and home_unit = p_unit) then raise exception 'No stall for Unit %.', p_unit; end if;
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'Enter the reason (for example: unpaid rent of $900 since 11/2).'; end if;
  if exists (select 1 from parking_revocations where unit_number = p_unit and restored_at is null) then raise exception 'Parking for Unit % is already revoked.', p_unit; end if;
  insert into parking_revocations (unit_number, reason, revoked_by) values (p_unit, trim(p_reason), lower(auth.email())) returning * into r;
  if coalesce(p_notify, false) then
    n := parking_revoke_notify(p_unit, 'Parking for Unit ' || p_unit || ' is revoked',
      '<p><b>Parking for Unit ' || repair_esc(p_unit) || ' is revoked</b> because of an unpaid balance on the account.</p>'
      || '<p><b>Do not park in stall ' || repair_esc(p_unit) || '.</b> A vehicle in it will be towed at the vehicle owner''s expense.</p>'
      || '<p>To restore parking, pay the balance from your bank on the portal (Payments tab) and call or text the office. Parking is restored once the account is current.</p>');
  end if;
  return jsonb_build_object('id', r.id, 'emailed', n);
end;
$$;
revoke all on function parking_revoke(text, text, boolean) from public, anon;
grant execute on function parking_revoke(text, text, boolean) to authenticated;

create or replace function parking_restore(p_unit text, p_note text, p_notify boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r parking_revocations; n int := 0;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  update parking_revocations set restored_at = now(), restored_by = lower(auth.email()), restore_note = nullif(trim(p_note), '')
   where unit_number = p_unit and restored_at is null returning * into r;
  if r.id is null then raise exception 'Parking for Unit % is not revoked here.', p_unit; end if;
  if coalesce(p_notify, false) then
    n := parking_revoke_notify(p_unit, 'Parking for Unit ' || p_unit || ' is restored',
      '<p><b>Parking for Unit ' || repair_esc(p_unit) || ' is restored.</b> You may park in stall ' || repair_esc(p_unit) || ' again.</p>');
  end if;
  return jsonb_build_object('id', r.id, 'emailed', n);
end;
$$;
revoke all on function parking_restore(text, text, boolean) from public, anon;
grant execute on function parking_restore(text, text, boolean) to authenticated;
