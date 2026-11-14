-- Parking tags: handing them out (Stephen, 11/9/2026). Unit 3 is the first unit to get its tags.
--   * Staff mark a unit's tags HANDED OUT on https://2ndchinc.org/parking/ (and put each red tag on a registered vehicle: vehicles.hanger_number).
--     The tenant / owner then taps "I received my tags" on their Parking tab: both are recorded (issued_* and received_*).
--   * Each unit now has TWO blue guest tags: G12 and G12B (Stephen: guest = 2). Both are guest passes for that unit's stall.
--   * A tag that is not handed out yet is not valid anywhere: Always Towing's page shows guest tags only once handed out, and each unit stall
--     says whether the unit has its tags yet (a car in a stall whose tags are not handed out is checked by plate only).
--   * Lost tag: staff mark it lost and may charge the $25 replacement fee (setting parking_tag_replace_fee). The charge goes on the lease that
--     received the tag (Other Income, "Replacement parking tag 12A"); with no lease (owner-occupied, vacant, Unit 6's occupant) it goes on the
--     unit's association billing account.
--   * Move-out: the unit's handed-out tags are flagged "collect" (and named in the stall-cleared email to info@). Staff mark them back in the
--     office, or lost (with the $25 fee on the old lease).
--   * No emails to residents here (Stephen: no parking emails until the parking system is complete).

alter table parking_tags add column if not exists issued_at timestamptz;
alter table parking_tags add column if not exists issued_by text;
alter table parking_tags add column if not exists issued_lease_id uuid references leases(id);
alter table parking_tags add column if not exists received_at timestamptz;
alter table parking_tags add column if not exists received_by text;
alter table parking_tags add column if not exists collect_since timestamptz;
alter table parking_tags add column if not exists fee_entry text;      -- 'lease:<id>' or 'condo:<id>' of the $25 charge

insert into portal_settings (key, value) values ('parking_tag_replace_fee', '25') on conflict (key) do nothing;

-- The second blue guest tag of every unit.
insert into parking_tags (code, kind, home_unit) select 'G' || u.unit_number || 'B', 'guest', u.unit_number from condo_units u on conflict (code) do nothing;

-- Guest tags valid in a stall: only tags that were handed out.
create or replace function parking_tag_guest_valid(p_unit text, p_day date)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x ->> 'code'), '[]'::jsonb) from (
    select jsonb_build_object('code', t.code, 'unit', t.home_unit, 'lent_until', null) x
      from parking_tags t
     where t.kind = 'guest' and t.status = 'active' and t.issued_at is not null and t.collect_since is null and t.home_unit = p_unit
       and not exists (select 1 from parking_tag_loans l where l.tag_code = t.code and l.returned_at is null and l.lent_until >= p_day)
    union all
    select jsonb_build_object('code', t.code, 'unit', t.home_unit, 'lent_until', l.lent_until)
      from parking_tag_loans l join parking_tags t on t.code = l.tag_code
     where l.to_unit = p_unit and l.returned_at is null and l.lent_until >= p_day and t.status = 'active' and t.issued_at is not null) s;
$$;
revoke all on function parking_tag_guest_valid(text, date) from public, anon, authenticated;

-- For the tow page: has the unit got its tags, and which red tags are out.
create or replace function parking_tag_stall_info(p_unit text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'issued', exists (select 1 from parking_tags t where t.home_unit = p_unit and t.status = 'active' and t.issued_at is not null and t.collect_since is null),
    'resident', coalesce((select jsonb_agg(t.code order by t.code) from parking_tags t
       where t.home_unit = p_unit and t.kind = 'resident' and t.status = 'active' and t.issued_at is not null and t.collect_since is null), '[]'::jsonb));
$$;
revoke all on function parking_tag_stall_info(text) from public, anon, authenticated;

do $$ declare v text := pg_get_functiondef('tow_lot_view()'::regprocedure); n text; begin
  if position('resident_tags' in v) > 0 then return; end if;
  n := replace(v, $a$'guest_tags', case when s ->> 'kind' = 'unit' then parking_tag_guest_valid(s ->> 'used_by', d) else '[]'::jsonb end,$a$,
                  $a$'guest_tags', case when s ->> 'kind' = 'unit' then parking_tag_guest_valid(s ->> 'used_by', d) else '[]'::jsonb end,
        'resident_tags', case when s ->> 'kind' = 'unit' then parking_tag_stall_info(s ->> 'used_by') else null end,$a$);
  if n = v then raise exception 'tow_lot_view changed; update this migration'; end if;
  execute n;
end $$;

-- Lending needs a handed-out tag.
do $$ declare v text := pg_get_functiondef('parking_tag_lend(text, text, date)'::regprocedure); n text; begin
  n := replace(v, $a$if t.status <> 'active' then raise exception$a$,
                  $a$if t.issued_at is null then raise exception 'This guest tag has not been handed out yet.'; end if;
  if t.status <> 'active' then raise exception$a$);
  if n = v then raise exception 'parking_tag_lend changed; update this migration'; end if;
  execute n;
end $$;

-- Resident / owner / Unit 6 occupant: my tags (now with handed-out and received dates).
create or replace function parking_tags_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := (now() at time zone 'America/Chicago')::date;
begin
  if not exists (select 1 from vehicle_reg_units()) then raise exception 'Resident or owner sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('today', d, 'max_days', condo_setting('parking_tag_loan_max_days', '14')::int,
    'replace_fee', condo_setting('parking_tag_replace_fee', '25')::numeric,
    'all_units', (select jsonb_agg(unit_number order by nullif(regexp_replace(unit_number, '\D', '', 'g'), '')::int) from condo_units),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', r.unit_number,
        'tags', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'kind', t.kind, 'status', t.status,
              'issued_at', t.issued_at, 'received_at', t.received_at, 'collect', t.collect_since is not null,
              'loan', (select jsonb_build_object('id', l.id, 'to_unit', l.to_unit, 'lent_on', l.lent_on, 'lent_until', l.lent_until)
                         from parking_tag_loans l where l.tag_code = t.code and l.returned_at is null))
            order by t.kind desc, t.code) from parking_tags t where t.home_unit = r.unit_number and t.status <> 'retired'
              and (t.issued_at is not null or t.status = 'lost')), '[]'::jsonb),
        'borrowed', coalesce((select jsonb_agg(jsonb_build_object('code', l.tag_code, 'from_unit', l.from_unit, 'lent_on', l.lent_on, 'lent_until', l.lent_until)
            order by l.lent_until) from parking_tag_loans l where l.to_unit = r.unit_number and l.returned_at is null), '[]'::jsonb),
        'thank', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'code', l.tag_code, 'from_unit', l.from_unit, 'returned_at', l.returned_at)
            order by l.returned_at desc) from parking_tag_loans l
            where l.to_unit = r.unit_number and l.returned_at > now() - interval '30 days' and l.thanked_at is null and not l.thanks_skipped), '[]'::jsonb))
      order by nullif(regexp_replace(r.unit_number, '\D', '', 'g'), '')::int)
      from (select distinct unit_number from vehicle_reg_units()) r), '[]'::jsonb));
end;
$$;
revoke all on function parking_tags_mine() from public, anon;
grant execute on function parking_tags_mine() to authenticated;

-- Resident taps "I received my tags": every handed-out, not yet received tag of that unit.
create or replace function parking_tags_receive(p_unit text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  if not exists (select 1 from vehicle_reg_units() r where r.unit_number = trim(p_unit)) then raise exception 'Only Unit % can confirm its tags.', p_unit using errcode = '42501'; end if;
  update parking_tags set received_at = now(), received_by = lower(auth.email()), updated_at = now()
   where home_unit = trim(p_unit) and status = 'active' and issued_at is not null and received_at is null and collect_since is null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'No tags waiting for your confirmation.'; end if;
  return n;
end;
$$;
revoke all on function parking_tags_receive(text) from public, anon;
grant execute on function parking_tags_receive(text) to authenticated;

-- Staff: every tag with status, handed-out / received, open loan.
create or replace function parking_tags_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'kind', t.kind, 'home_unit', t.home_unit, 'status', t.status, 'status_at', t.status_at, 'notes', t.notes,
      'issued_at', t.issued_at, 'issued_by', t.issued_by, 'received_at', t.received_at, 'collect_since', t.collect_since, 'fee_entry', t.fee_entry,
      'on_vehicle', (select concat_ws(' ', v.color, v.make, v.model, v.plate) from vehicles v where v.status = 'active' and v.hanger_number = t.code limit 1),
      'loan', (select jsonb_build_object('to_unit', l.to_unit, 'lent_on', l.lent_on, 'lent_until', l.lent_until) from parking_tag_loans l where l.tag_code = t.code and l.returned_at is null))
    order by nullif(regexp_replace(t.home_unit, '\D', '', 'g'), '')::int, t.kind desc, t.code) from parking_tags t), '[]'::jsonb);
end;
$$;
revoke all on function parking_tags_staff_list() from public, anon;
grant execute on function parking_tags_staff_list() to authenticated;

-- Staff: hand out tags (p_undo = true takes the mark back, e.g. clicked by mistake), or mark collected tags back in the office (p_back = true).
create or replace function parking_tags_staff_issue(p_codes text[], p_undo boolean default false, p_back boolean default false)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int; d date := (now() at time zone 'America/Chicago')::date;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(array_length(p_codes, 1), 0) = 0 then raise exception 'Choose at least one tag.'; end if;
  if p_undo or p_back then
    update parking_tag_loans set returned_at = now(), returned_by = 'staff:' || lower(auth.email()), thanks_skipped = true
     where tag_code = any (select upper(trim(c)) from unnest(p_codes) c) and returned_at is null;
    update parking_tags set issued_at = null, issued_by = null, issued_lease_id = null, received_at = null, received_by = null, collect_since = null,
           notes = case when p_back then concat_ws(' ', nullif(notes, ''), '[Back in the office ' || to_char(d, 'FMMM/FMDD/YYYY') || '.]') else notes end, updated_at = now()
     where code = any (select upper(trim(c)) from unnest(p_codes) c) and issued_at is not null;
    get diagnostics n = row_count;
    update vehicles set hanger_number = null, updated_at = now() where status = 'active' and hanger_number = any (select upper(trim(c)) from unnest(p_codes) c);
  else
    update parking_tags t set issued_at = now(), issued_by = lower(auth.email()), issued_lease_id = roca_unit_lease_on(t.home_unit, d),
           received_at = null, received_by = null, collect_since = null, updated_at = now()
     where t.code = any (select upper(trim(c)) from unnest(p_codes) c) and t.status = 'active' and t.issued_at is null;
    get diagnostics n = row_count;
  end if;
  if n = 0 then raise exception 'Nothing changed (already handed out, not handed out, or not active).'; end if;
  return n;
end;
$$;
revoke all on function parking_tags_staff_issue(text[], boolean, boolean) from public, anon;
grant execute on function parking_tags_staff_issue(text[], boolean, boolean) to authenticated;

-- Staff: mark a tag lost / retired / active again; p_charge posts the replacement fee (once per tag).
drop function if exists parking_tags_staff_set(text, text, text);
create or replace function parking_tags_staff_set(p_code text, p_status text, p_notes text default null, p_charge boolean default false)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare t parking_tags; d date := (now() at time zone 'America/Chicago')::date; v_fee numeric := condo_setting('parking_tag_replace_fee', '25')::numeric;
  v_lease uuid; v_acct uuid; v_id bigint; v_msg text := 'Saved.'; v_desc text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('active', 'lost', 'retired') then raise exception 'Unknown status.'; end if;
  select * into t from parking_tags where code = upper(trim(p_code)) for update;
  if t.code is null then raise exception 'Tag not found.'; end if;
  update parking_tags set status = p_status, status_at = now(), notes = coalesce(nullif(trim(p_notes), ''), notes), updated_at = now(),
         collect_since = case when p_status = 'active' then collect_since end where code = t.code;
  if p_status <> 'active' then
    update parking_tag_loans set returned_at = now(), returned_by = 'staff:' || lower(auth.email()), thanks_skipped = true where tag_code = t.code and returned_at is null;
    update vehicles set hanger_number = null, updated_at = now() where status = 'active' and hanger_number = t.code;
  end if;
  if p_charge then
    if p_status <> 'lost' then raise exception 'The replacement fee is only for a lost tag.'; end if;
    if t.fee_entry is not null then raise exception 'The replacement fee for % was already charged.', t.code; end if;
    v_desc := 'Replacement parking tag ' || case when t.kind = 'guest' then 'Guest ' || t.home_unit || case when t.code like '%B' then ' (2nd)' else '' end else t.code end;
    v_lease := coalesce(t.issued_lease_id, roca_unit_lease_on(t.home_unit, d));
    if v_lease is not null then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
      values (v_lease, 'Other Income', d, 'charge', 'Charge', v_desc, v_fee, 'staff', 'Entered by ' || auth.email() || ': lost parking tag')
      returning id into v_id;
      update parking_tags set fee_entry = 'lease:' || v_id where code = t.code;
      v_msg := 'Marked lost. $' || v_fee || ' charged on the tenant ledger.';
    else
      v_acct := condo_billing_account((select id from condo_units where unit_number = t.home_unit));
      if v_acct is null then raise exception 'Marked lost, but Unit % has no lease and no association account to charge.', t.home_unit; end if;
      insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
      values (v_acct, 'Parking Income', d, 'charge', 'Charge', v_desc, v_fee, 'staff', auth.email(), 'Lost parking tag')
      returning id into v_id;
      update parking_tags set fee_entry = 'condo:' || v_id where code = t.code;
      v_msg := 'Marked lost. $' || v_fee || ' charged on the owner''s association account.';
    end if;
  end if;
  return v_msg;
end;
$$;
revoke all on function parking_tags_staff_set(text, text, text, boolean) from public, anon;
grant execute on function parking_tags_staff_set(text, text, text, boolean) to authenticated;

-- Move-out: flag the unit's handed-out tags to collect and name them in the stall-cleared email.
do $$ declare v text := pg_get_functiondef('parking_clear_for_lease(uuid, date)'::regprocedure); n text; begin
  if position('collect_since' in v) > 0 then return; end if;
  n := replace(v, $a$  insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', 'Stall ' || v_unit || ' cleared at move-out',$a$,
                  $a$  update parking_tags set collect_since = now(), updated_at = now() where home_unit = v_unit and status = 'active' and issued_at is not null and collect_since is null;
  select string_agg(case when kind = 'guest' then 'Guest ' || home_unit || case when code like '%B' then ' (2nd)' else '' end else code end, ', ' order by kind desc, code)
    into v_hangers from parking_tags where home_unit = v_unit and collect_since is not null;
  insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', 'Stall ' || v_unit || ' cleared at move-out',$a$);
  n := replace(n, $a$'<p><b>Collect parking hanger' || case when position(',' in v_hangers) > 0 then 's' else '' end || ' #' || repair_esc(v_hangers) || '.</b></p>'$a$,
                  $a$'<p><b>Collect parking tag' || case when position(',' in v_hangers) > 0 then 's' else '' end || ': ' || repair_esc(v_hangers) || '.</b> Mark them back in the office (or lost, $' || condo_setting('parking_tag_replace_fee', '25') || ' each) at https://2ndchinc.org/parking/</p>'$a$);
  if n = v or position('collect_since' in n) = 0 or position('Collect parking tag' in n) = 0 then raise exception 'parking_clear_for_lease changed; update this migration'; end if;
  execute n;
end $$;
