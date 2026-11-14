-- Parking tags (rear-view mirror hang tags) and guest-tag loans (Stephen, 11/8/2026).
--   * Every unit (1-8, 11-18) gets 2 red resident tags ("12A", "12B"; the A/B is only for inventory) and 1 blue guest tag ("G12",
--     printed ROCA1 / 12 / GUEST). parking_tags lists every physical tag and its status (lost / retired tags are not valid).
--   * The blue guest tag IS the guest parking pass: a guest with it may park in that unit's stall without office approval.
--     Overnight stays still go through guest_requests (13-night rule); nothing about that changes.
--   * A unit may LEND its guest tag to another unit for up to parking_tag_loan_max_days (14) days. The LENDING unit records the loan
--     on its Parking tab (which unit, until when) and only the lender marks it returned. When it is returned the borrowing unit is
--     prompted to send a thank-you (emailed to the lending unit's people; the site never shows anyone's name or email to a neighbor).
--   * Always Towing's page (tow_lot_view) lists, per unit stall, the guest tags valid in it today (the unit's own unless lent out,
--     plus tags lent to it whose return date has not passed), and the lost / retired tags, which are not valid anywhere.
--   * Resident tags stay recorded on the vehicle as vehicles.hanger_number (staff Parking page); this table adds their status.
--   * Rule wording is NOT changed here (Stephen: update it later, when the tags are handed out, with a notice and no re-signing).
-- New tables: explicit grants (Supabase change 10/30/2026). Row security on, no policies: everything goes through the functions below.

create table if not exists parking_tags (
  code text primary key,                                   -- "12A", "12B", "G12"; a replacement is "12C"
  kind text not null check (kind in ('resident', 'guest')),
  home_unit text not null,
  status text not null default 'active' check (status in ('active', 'lost', 'retired')),
  status_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table parking_tags enable row level security;
revoke all on parking_tags from public, anon, authenticated;
grant all on parking_tags to service_role;

create table if not exists parking_tag_loans (
  id uuid primary key default gen_random_uuid(),
  tag_code text not null references parking_tags(code),
  from_unit text not null,
  to_unit text not null,
  lent_on date not null default ((now() at time zone 'America/Chicago')::date),
  lent_until date not null,
  lent_by text,
  lent_at timestamptz not null default now(),
  returned_at timestamptz,
  returned_by text,
  thanked_at timestamptz,
  thanks_skipped boolean not null default false,
  thanks_note text
);
create unique index if not exists parking_tag_loans_one_open on parking_tag_loans (tag_code) where returned_at is null;
create index if not exists parking_tag_loans_to on parking_tag_loans (to_unit) where returned_at is null;
alter table parking_tag_loans enable row level security;
revoke all on parking_tag_loans from public, anon, authenticated;
grant all on parking_tag_loans to service_role;

insert into portal_settings (key, value) values ('parking_tag_loan_max_days', '14') on conflict (key) do nothing;

-- The 48 tags: 12A, 12B and G12 for every unit.
insert into parking_tags (code, kind, home_unit)
select u.unit_number || x.suffix, 'resident', u.unit_number from condo_units u cross join (values ('A'), ('B')) x(suffix)
union all
select 'G' || u.unit_number, 'guest', u.unit_number from condo_units u
on conflict (code) do nothing;

-- Guest tags valid in a unit's stall on day p_day: [{code, unit (the tag's home unit), lent_until (null = its own)}]
create or replace function parking_tag_guest_valid(p_unit text, p_day date)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x ->> 'code'), '[]'::jsonb) from (
    select jsonb_build_object('code', t.code, 'unit', t.home_unit, 'lent_until', null) x
      from parking_tags t
     where t.kind = 'guest' and t.status = 'active' and t.home_unit = p_unit
       and not exists (select 1 from parking_tag_loans l where l.tag_code = t.code and l.returned_at is null and l.lent_until >= p_day)
    union all
    select jsonb_build_object('code', t.code, 'unit', t.home_unit, 'lent_until', l.lent_until)
      from parking_tag_loans l join parking_tags t on t.code = l.tag_code
     where l.to_unit = p_unit and l.returned_at is null and l.lent_until >= p_day and t.status = 'active') s;
$$;
revoke all on function parking_tag_guest_valid(text, date) from public, anon, authenticated;

-- Resident / owner / Unit 6 occupant: the tags of my unit(s), loans out and in, and thank-yous to send.
create or replace function parking_tags_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := (now() at time zone 'America/Chicago')::date;
begin
  if not exists (select 1 from vehicle_reg_units()) then raise exception 'Resident or owner sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('today', d, 'max_days', condo_setting('parking_tag_loan_max_days', '14')::int,
    'all_units', (select jsonb_agg(unit_number order by nullif(regexp_replace(unit_number, '\D', '', 'g'), '')::int) from condo_units),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', r.unit_number,
        'tags', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'kind', t.kind, 'status', t.status,
              'loan', (select jsonb_build_object('id', l.id, 'to_unit', l.to_unit, 'lent_on', l.lent_on, 'lent_until', l.lent_until)
                         from parking_tag_loans l where l.tag_code = t.code and l.returned_at is null))
            order by t.kind, t.code) from parking_tags t where t.home_unit = r.unit_number and t.status <> 'retired'), '[]'::jsonb),
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

-- The lending unit records the loan when it hands the tag over.
create or replace function parking_tag_lend(p_code text, p_to_unit text, p_until date)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare t parking_tags; d date := (now() at time zone 'America/Chicago')::date; v_max int := condo_setting('parking_tag_loan_max_days', '14')::int;
begin
  select * into t from parking_tags where code = upper(trim(p_code));
  if t.code is null or t.kind <> 'guest' then raise exception 'Guest tag not found.'; end if;
  if not exists (select 1 from vehicle_reg_units() r where r.unit_number = t.home_unit) then raise exception 'Only Unit % can lend this guest tag.', t.home_unit using errcode = '42501'; end if;
  if t.status <> 'active' then raise exception 'This guest tag is marked % and cannot be lent. Call the office.', t.status; end if;
  if not exists (select 1 from condo_units where unit_number = trim(p_to_unit)) then raise exception 'Choose the unit you are lending it to.'; end if;
  if trim(p_to_unit) = t.home_unit then raise exception 'Choose another unit.'; end if;
  if p_until is null or p_until < d then raise exception 'Choose the return date.'; end if;
  if p_until > d + v_max then raise exception 'A guest tag can be lent for up to % days (return by %).', v_max, to_char(d + v_max, 'FMMM/FMDD/YYYY'); end if;
  if exists (select 1 from parking_tag_loans where tag_code = t.code and returned_at is null) then raise exception 'This guest tag is already lent out. Mark it returned first.'; end if;
  insert into parking_tag_loans (tag_code, from_unit, to_unit, lent_until, lent_by) values (t.code, t.home_unit, trim(p_to_unit), p_until, lower(auth.email()));
end;
$$;
revoke all on function parking_tag_lend(text, text, date) from public, anon;
grant execute on function parking_tag_lend(text, text, date) to authenticated;

-- Only the lending unit marks the tag returned.
create or replace function parking_tag_return(p_loan uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare l parking_tag_loans;
begin
  select * into l from parking_tag_loans where id = p_loan and returned_at is null;
  if l.id is null then raise exception 'This loan is already closed.'; end if;
  if not exists (select 1 from vehicle_reg_units() r where r.unit_number = l.from_unit) then raise exception 'Only Unit % can mark its guest tag returned.', l.from_unit using errcode = '42501'; end if;
  update parking_tag_loans set returned_at = now(), returned_by = lower(auth.email()) where id = l.id;
end;
$$;
revoke all on function parking_tag_return(uuid) from public, anon;
grant execute on function parking_tag_return(uuid) to authenticated;

-- The borrowing unit's thank-you (p_send = false: "not now", the prompt goes away). Emailed to the lending unit's people.
create or replace function parking_tag_thank(p_loan uuid, p_note text, p_send boolean default true)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare l parking_tag_loans; r record; v_note text := left(nullif(trim(coalesce(p_note, '')), ''), 500); v_html text;
begin
  select * into l from parking_tag_loans where id = p_loan and returned_at is not null and thanked_at is null and not thanks_skipped;
  if l.id is null then raise exception 'Nothing to send for this loan.'; end if;
  if not exists (select 1 from vehicle_reg_units() u where u.unit_number = l.to_unit) then raise exception 'Only Unit % can send this thank-you.', l.to_unit using errcode = '42501'; end if;
  if not p_send then update parking_tag_loans set thanks_skipped = true where id = l.id; return; end if;
  update parking_tag_loans set thanked_at = now(), thanks_note = v_note where id = l.id;
  for r in select distinct on (lower(p.email)) lower(p.email) email, p.name from parking_unit_people(l.from_unit) p where p.email like '%@%' order by lower(p.email) loop
    v_html := '<div style="font-family:Arial,sans-serif;max-width:600px;color:#1b2430"><p>Hi ' || repair_esc(split_part(coalesce(r.name, ''), ' ', 1)) || ',</p>'
      || '<p>Your neighbors in <b>Unit ' || repair_esc(l.to_unit) || '</b> say <b>thank you</b> for lending them your guest parking tag ('
      || to_char(l.lent_on, 'FMMM/FMDD') || ' to ' || to_char((l.returned_at at time zone 'America/Chicago')::date, 'FMMM/FMDD') || ').</p>'
      || case when v_note is not null then '<p style="border-left:4px solid #2e7d1f;padding:6px 12px;font-style:italic">' || replace(repair_esc(v_note), E'\n', '<br>') || '</p>' else '' end
      || '<p style="color:#5b6573;font-size:13px">2nd Chance Housing, ' || repair_esc(condo_setting('org_phone', '')) || ', info@2ndchinc.org.</p></div>';
    insert into email_outbox (to_email, subject, html, kind) values (r.email, 'Thank you from Unit ' || l.to_unit || ' for your guest parking tag', v_html, 'parking_tag_thanks');
  end loop;
end;
$$;
revoke all on function parking_tag_thank(uuid, text, boolean) from public, anon;
grant execute on function parking_tag_thank(uuid, text, boolean) to authenticated;

-- Staff: every tag with its status and open loan.
create or replace function parking_tags_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'kind', t.kind, 'home_unit', t.home_unit, 'status', t.status, 'status_at', t.status_at, 'notes', t.notes,
      'on_vehicle', (select concat_ws(' ', v.color, v.make, v.model, v.plate) from vehicles v where v.status = 'active' and v.hanger_number = t.code limit 1),
      'loan', (select jsonb_build_object('to_unit', l.to_unit, 'lent_on', l.lent_on, 'lent_until', l.lent_until) from parking_tag_loans l where l.tag_code = t.code and l.returned_at is null))
    order by nullif(regexp_replace(t.home_unit, '\D', '', 'g'), '')::int, t.kind desc, t.code) from parking_tags t), '[]'::jsonb);
end;
$$;
revoke all on function parking_tags_staff_list() from public, anon;
grant execute on function parking_tags_staff_list() to authenticated;

-- Staff: mark a tag lost / retired / active again, or add a replacement tag ("12C", "G12B"...).
create or replace function parking_tags_staff_set(p_code text, p_status text, p_notes text default null)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('active', 'lost', 'retired') then raise exception 'Unknown status.'; end if;
  update parking_tags set status = p_status, status_at = now(), notes = coalesce(nullif(trim(p_notes), ''), notes), updated_at = now() where code = upper(trim(p_code));
  if not found then raise exception 'Tag not found.'; end if;
  if p_status <> 'active' then update parking_tag_loans set returned_at = now(), returned_by = 'staff:' || lower(auth.email()), thanks_skipped = true
    where tag_code = upper(trim(p_code)) and returned_at is null; end if;
end;
$$;
revoke all on function parking_tags_staff_set(text, text, text) from public, anon;
grant execute on function parking_tags_staff_set(text, text, text) to authenticated;

create or replace function parking_tags_staff_add(p_code text, p_kind text, p_unit text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_code text := upper(trim(coalesce(p_code, '')));
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_kind not in ('resident', 'guest') then raise exception 'Choose resident or guest.'; end if;
  if not exists (select 1 from condo_units where unit_number = trim(p_unit)) then raise exception 'Unit not found.'; end if;
  if v_code !~ '^[A-Z0-9]{1,8}$' then raise exception 'Tag code: letters and numbers only, e.g. 12C.'; end if;
  insert into parking_tags (code, kind, home_unit) values (v_code, p_kind, trim(p_unit));
exception when unique_violation then raise exception 'Tag % already exists.', v_code;
end;
$$;
revoke all on function parking_tags_staff_add(text, text, text) from public, anon;
grant execute on function parking_tags_staff_add(text, text, text) to authenticated;

-- Always Towing's page: valid guest tags per unit stall, and the lost / retired tags.
do $$ declare v text := pg_get_functiondef('tow_lot_view()'::regprocedure); n text; begin
  n := replace(v, $a$'swap', s -> 'swap', 'hold', s -> 'hold',$a$,
                  $a$'swap', s -> 'swap', 'hold', s -> 'hold',
        'guest_tags', case when s ->> 'kind' = 'unit' then parking_tag_guest_valid(s ->> 'used_by', d) else '[]'::jsonb end,$a$);
  n := replace(n, $a$'office_email', 'info@2ndchinc.org',$a$,
                  $a$'office_email', 'info@2ndchinc.org',
    'lost_tags', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'kind', t.kind, 'unit', t.home_unit, 'status', t.status) order by t.code)
      from parking_tags t where t.status <> 'active'), '[]'::jsonb),$a$);
  if n = v or position('guest_tags' in n) = 0 or position('lost_tags' in n) = 0 then raise exception 'tow_lot_view changed; update this migration'; end if;
  execute n;
end $$;
