-- ===========================================================================
-- Royal Orleans association records: violations, owner notes, board history.
-- Staff only (two-step sign-in). Nothing is ever deleted: a violation moves
-- through statuses, a note is superseded by a newer one, and a board seat is
-- ended with an end date. Each row says who entered it.
-- ===========================================================================

create table if not exists condo_violations (
  id bigint generated always as identity primary key,
  unit_id uuid not null references condo_units(id),
  owner_id uuid references condo_owners(id),          -- the owner at the time
  category text not null,                              -- e.g. Parking, Noise, Trash, Pets, Exterior, Other
  description text not null,
  observed_date date not null default current_date,
  reported_by text,                                    -- who saw or complained
  status text not null default 'open' check (status in ('open', 'notice_sent', 'fined', 'cured', 'dismissed')),
  cure_by date,
  fine_amount numeric(12,2),
  resolved_date date,
  resolution_note text,
  tenant_notified boolean not null default false,      -- passed on to the tenant (2c-condo-violation notice)
  entered_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists condo_violations_unit_idx on condo_violations (unit_id, observed_date);
alter table condo_violations enable row level security;

create table if not exists condo_owner_notes (
  id bigint generated always as identity primary key,
  owner_id uuid not null references condo_owners(id),
  unit_id uuid references condo_units(id),
  note text not null,
  entered_by text,
  created_at timestamptz not null default now()
);
create index if not exists condo_owner_notes_owner_idx on condo_owner_notes (owner_id, created_at);
alter table condo_owner_notes enable row level security;

create table if not exists condo_board_terms (
  id bigint generated always as identity primary key,
  owner_id uuid not null references condo_owners(id),
  unit_id uuid references condo_units(id),
  position text not null,
  start_date date,
  end_date date,
  note text,
  entered_by text,
  created_at timestamptz not null default now()
);
create index if not exists condo_board_terms_idx on condo_board_terms (position, start_date);
alter table condo_board_terms enable row level security;

-- Today's seats become the first rows of the history (start date unknown).
insert into condo_board_terms (owner_id, unit_id, position, start_date, note, entered_by)
select s.owner_id, s.unit_id, s.board_position, null, 'Current seat when board history was first recorded', 'system'
from condo_ownerships s
where s.is_current and coalesce(s.board_position, '') <> ''
  and not exists (select 1 from condo_board_terms t where t.owner_id = s.owner_id and t.position = s.board_position);

-- ---------------------------------------------------------------------------
-- One call for the staff page: everything recorded for a unit.
create or replace function condo_staff_unit_records(p_unit_number text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_unit uuid; v_owner uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select id into v_unit from condo_units where unit_number = p_unit_number;
  if v_unit is null then raise exception 'Unit not found'; end if;
  select owner_id into v_owner from condo_ownerships where unit_id = v_unit and is_current limit 1;
  return jsonb_build_object(
    'owner_id', v_owner,
    'violations', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'category', v.category, 'description', v.description,
        'observed', v.observed_date, 'reported_by', v.reported_by, 'status', v.status, 'cure_by', v.cure_by, 'fine', v.fine_amount,
        'resolved', v.resolved_date, 'resolution_note', v.resolution_note, 'tenant_notified', v.tenant_notified,
        'owner', (select name from condo_owners where id = v.owner_id), 'entered_by', v.entered_by)
        order by v.observed_date desc, v.id desc) from condo_violations v where v.unit_id = v_unit), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'owner', o.name, 'note', n.note, 'at', n.created_at, 'by', n.entered_by)
        order by n.created_at desc) from condo_owner_notes n join condo_owners o on o.id = n.owner_id
        where n.unit_id = v_unit or n.owner_id = v_owner), '[]'::jsonb));
end;
$$;
revoke all on function condo_staff_unit_records(text) from public, anon;
grant execute on function condo_staff_unit_records(text) to authenticated;

-- Every unit at a glance: open violations and last note.
create or replace function condo_staff_records_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit_number', u.unit_number, 'address', u.address,
        'owner', (select o.name from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.unit_id = u.id and s.is_current limit 1),
        'open_violations', (select count(*) from condo_violations v where v.unit_id = u.id and v.status in ('open', 'notice_sent', 'fined')),
        'total_violations', (select count(*) from condo_violations v where v.unit_id = u.id),
        'unpaid_fines', (select coalesce(sum(v.fine_amount), 0) from condo_violations v where v.unit_id = u.id and v.status = 'fined'),
        'last_note', (select n.created_at from condo_owner_notes n where n.unit_id = u.id order by n.created_at desc limit 1))
        order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int nulls last, u.unit_number) from condo_units u), '[]'::jsonb),
    'board', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'position', t.position, 'owner', o.name,
        'unit', (select unit_number from condo_units where id = t.unit_id), 'start', t.start_date, 'end', t.end_date, 'note', t.note, 'by', t.entered_by)
        order by (t.end_date is null) desc, t.end_date desc nulls first, t.start_date desc nulls last, t.id desc)
        from condo_board_terms t join condo_owners o on o.id = t.owner_id), '[]'::jsonb));
end;
$$;
revoke all on function condo_staff_records_overview() from public, anon;
grant execute on function condo_staff_records_overview() to authenticated;

-- ---------------------------------------------------------------------------
create or replace function condo_staff_add_violation(p_unit_number text, p_category text, p_description text, p_observed date,
                                                     p_reported_by text, p_cure_by date)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare v_unit uuid; v_id bigint;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select id into v_unit from condo_units where unit_number = p_unit_number;
  if v_unit is null then raise exception 'Unit not found'; end if;
  if coalesce(trim(p_category), '') = '' or coalesce(trim(p_description), '') = '' then raise exception 'Choose a category and describe the violation'; end if;
  insert into condo_violations (unit_id, owner_id, category, description, observed_date, reported_by, cure_by, entered_by)
  values (v_unit, (select owner_id from condo_ownerships where unit_id = v_unit and is_current limit 1), trim(p_category), trim(p_description),
          coalesce(p_observed, current_date), nullif(trim(p_reported_by), ''), p_cure_by, auth.email())
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function condo_staff_add_violation(text, text, text, date, text, date) from public, anon;
grant execute on function condo_staff_add_violation(text, text, text, date, text, date) to authenticated;

create or replace function condo_staff_update_violation(p_id bigint, p_status text, p_fine numeric, p_note text, p_tenant_notified boolean)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('open', 'notice_sent', 'fined', 'cured', 'dismissed') then raise exception 'Unknown status'; end if;
  if p_status in ('cured', 'dismissed') and coalesce(trim(p_note), '') = '' then raise exception 'Say how it was resolved'; end if;
  if p_status = 'fined' and coalesce(p_fine, 0) <= 0 then raise exception 'Enter the fine amount'; end if;
  update condo_violations set status = p_status,
    fine_amount = case when p_status = 'fined' then p_fine else fine_amount end,
    resolved_date = case when p_status in ('cured', 'dismissed') then current_date else null end,
    resolution_note = coalesce(nullif(trim(p_note), ''), resolution_note),
    tenant_notified = coalesce(p_tenant_notified, tenant_notified),
    updated_at = now()
  where id = p_id;
  if not found then raise exception 'Violation not found'; end if;
end;
$$;
revoke all on function condo_staff_update_violation(bigint, text, numeric, text, boolean) from public, anon;
grant execute on function condo_staff_update_violation(bigint, text, numeric, text, boolean) to authenticated;

create or replace function condo_staff_add_owner_note(p_unit_number text, p_note text)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare v_unit uuid; v_owner uuid; v_id bigint;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select id into v_unit from condo_units where unit_number = p_unit_number;
  if v_unit is null then raise exception 'Unit not found'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Write the note'; end if;
  select owner_id into v_owner from condo_ownerships where unit_id = v_unit and is_current limit 1;
  if v_owner is null then raise exception 'This unit has no current owner'; end if;
  insert into condo_owner_notes (owner_id, unit_id, note, entered_by) values (v_owner, v_unit, trim(p_note), auth.email()) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function condo_staff_add_owner_note(text, text) from public, anon;
grant execute on function condo_staff_add_owner_note(text, text) to authenticated;

-- Seat someone: the unit's current owner takes the position from p_start.
create or replace function condo_staff_add_board_term(p_unit_number text, p_position text, p_start date, p_note text)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare v_unit uuid; v_owner uuid; v_id bigint;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select id into v_unit from condo_units where unit_number = p_unit_number;
  if v_unit is null then raise exception 'Unit not found'; end if;
  if coalesce(trim(p_position), '') = '' then raise exception 'Enter the board position'; end if;
  select owner_id into v_owner from condo_ownerships where unit_id = v_unit and is_current limit 1;
  if v_owner is null then raise exception 'This unit has no current owner'; end if;
  if exists (select 1 from condo_board_terms where lower(position) = lower(trim(p_position)) and end_date is null) then
    raise exception 'That seat is still held. End the current term first.'; end if;
  insert into condo_board_terms (owner_id, unit_id, position, start_date, note, entered_by)
  values (v_owner, v_unit, trim(p_position), coalesce(p_start, current_date), nullif(trim(p_note), ''), auth.email()) returning id into v_id;
  update condo_ownerships set board_position = trim(p_position), updated_at = now() where unit_id = v_unit and is_current;
  return v_id;
end;
$$;
revoke all on function condo_staff_add_board_term(text, text, date, text) from public, anon;
grant execute on function condo_staff_add_board_term(text, text, date, text) to authenticated;

create or replace function condo_staff_end_board_term(p_id bigint, p_end date, p_note text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare v_t condo_board_terms%rowtype;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into v_t from condo_board_terms where id = p_id and end_date is null;
  if not found then raise exception 'Term not found or already ended'; end if;
  update condo_board_terms set end_date = coalesce(p_end, current_date),
    note = coalesce(nullif(trim(p_note), ''), note) where id = p_id;
  update condo_ownerships set board_position = null, updated_at = now()
  where owner_id = v_t.owner_id and is_current and board_position = v_t.position;
end;
$$;
revoke all on function condo_staff_end_board_term(bigint, date, text) from public, anon;
grant execute on function condo_staff_end_board_term(bigint, date, text) to authenticated;
