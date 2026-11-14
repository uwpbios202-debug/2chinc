-- Guest requests (Stephen, 10/7/2026): tenants and owners ask, in their portal, for a guest's overnight stay, guest parking,
-- or both. Staff approve or decline every request, because guest parking needs a physical decal that a staff member hands
-- to the tenant or owner; staff record the decal number at the hand-over. Staff can also enter a request for someone.
--
-- The 13-night rule (lease, Rules and Regulations, Guests): "No guest shall remain overnight in the property for more than
-- thirteen (13) nights in total in any twelve (12) month period without the prior written consent of Landlord." Staff see
-- each guest's approved nights at the unit over the last 12 months, counting the request. Approving a request that goes
-- over 13 is the landlord's written consent, and the approval email says so.

create table if not exists guest_requests (
  id uuid primary key default gen_random_uuid(),
  unit_number text not null,
  requester_kind text not null check (requester_kind in ('tenant', 'owner', 'staff')),
  requester_name text,
  requester_email text,               -- where the decision email goes
  tenant_id uuid references tenants(id),
  owner_id uuid references condo_owners(id),
  lease_id uuid references leases(id),
  guest_name text not null,
  guest_phone text,
  overnight boolean not null default false,
  parking boolean not null default false,
  start_date date not null,
  end_date date not null,             -- the guest leaves this day; overnight nights = end_date - start_date
  vehicle_make text, vehicle_model text, vehicle_color text, plate text, plate_state text,
  note text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'cancelled')),
  over_limit_consent boolean not null default false,   -- approved past 13 nights: the landlord's written consent
  staff_note text,
  decided_by text, decided_at timestamptz,
  decal_number text, decal_given_at timestamptz, decal_given_by text,
  created_by text,
  created_at timestamptz not null default now(),
  check (overnight or parking),
  check (end_date >= start_date)
);
create index if not exists guest_requests_unit_idx on guest_requests (unit_number, start_date);
create index if not exists guest_requests_status_idx on guest_requests (status, created_at);
alter table guest_requests enable row level security;
-- No policies: everything goes through the functions below.

-- Approved overnight nights for this guest at this unit in the 12 months up to p_end, plus p_extra (the request itself).
create or replace function guest_nights_12mo(p_unit text, p_guest text, p_end date, p_exclude uuid)
returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(greatest(0, least(g.end_date, p_end) - greatest(g.start_date, p_end - 365))), 0)::int
  from guest_requests g
  where g.unit_number = p_unit and g.overnight and g.status = 'approved' and g.id is distinct from p_exclude
    and lower(regexp_replace(g.guest_name, '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_guest), '\s+', ' ', 'g'))
    and g.end_date > p_end - 365 and g.start_date < p_end;
$$;
revoke all on function guest_nights_12mo(text, text, date, uuid) from public, anon, authenticated;

-- The units the signed-in person can ask for: tenants' current units and owners' current units.
create or replace function guest_my_units()
returns table (unit_number text, kind text)
language sql stable security definer set search_path = public as $$
  select u, 'tenant' from vehicle_my_units() u
  union
  select cu.unit_number, 'owner' from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok();
$$;
revoke all on function guest_my_units() from public, anon;
grant execute on function guest_my_units() to authenticated;

create or replace function guest_row(g guest_requests)
returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(g) - 'tenant_id' - 'owner_id' - 'lease_id' || jsonb_build_object(
    'nights', case when g.overnight then g.end_date - g.start_date else 0 end,
    'nights_12mo', case when g.overnight then guest_nights_12mo(g.unit_number, g.guest_name, g.end_date, g.id) + (g.end_date - g.start_date) else null end);
$$;
revoke all on function guest_row(guest_requests) from public, anon, authenticated;

create or replace function guest_validate(p_guest text, p_overnight boolean, p_parking boolean, p_start date, p_end date,
  p_make text, p_model text, p_color text, p_plate text)
returns void
language plpgsql immutable as $$
begin
  if length(coalesce(trim(p_guest), '')) < 2 then raise exception 'Enter the guest''s full name.'; end if;
  if not (coalesce(p_overnight, false) or coalesce(p_parking, false)) then raise exception 'Choose overnight stay, guest parking, or both.'; end if;
  if p_start is null or p_end is null or p_end < p_start then raise exception 'Enter the dates: the day the guest arrives and the day they leave.'; end if;
  if p_overnight and p_end = p_start then raise exception 'For an overnight stay, the leaving day is after the arriving day.'; end if;
  if p_end - p_start > 60 then raise exception 'A request can cover up to 60 days. Make another request for longer.'; end if;
  if p_parking and (coalesce(trim(p_make), '') = '' or coalesce(trim(p_model), '') = '' or coalesce(trim(p_color), '') = '' or coalesce(trim(p_plate), '') = '') then
    raise exception 'For guest parking, enter the vehicle''s make, model, color and license plate.'; end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tenants and owners
create or replace function guest_requests_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from guest_my_units()) then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', unit_number, 'kind', kind) order by unit_number) from guest_my_units()), '[]'::jsonb),
    'office_phone', (select value from portal_settings where key = 'org_phone'),
    'requests', coalesce((select jsonb_agg(guest_row(g) - 'staff_note' - 'created_by' - 'decided_by' - 'decal_given_by' order by g.created_at desc)
      from guest_requests g where g.unit_number in (select unit_number from guest_my_units()) and g.created_at > now() - interval '18 months'), '[]'::jsonb));
end;
$$;
revoke all on function guest_requests_mine() from public, anon;
grant execute on function guest_requests_mine() to authenticated;

create or replace function guest_request_create(p_unit text, p_guest text, p_guest_phone text, p_overnight boolean, p_parking boolean,
  p_start date, p_end date, p_make text, p_model text, p_color text, p_plate text, p_plate_state text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_kind text; v_tenant uuid; v_lease uuid; v_owner uuid; v_name text; g guest_requests; v_n int;
begin
  select kind into v_kind from guest_my_units() where unit_number = p_unit order by kind = 'tenant' desc limit 1;
  if v_kind is null then raise exception 'That unit isn''t yours.' using errcode = '42501'; end if;
  perform guest_validate(p_guest, p_overnight, p_parking, p_start, p_end, p_make, p_model, p_color, p_plate);
  if p_start < current_date then raise exception 'The arriving day can''t be in the past.'; end if;
  if v_kind = 'tenant' then
    select lt.tenant_id, l.id into v_tenant, v_lease from lease_tenants lt join leases l on l.id = lt.lease_id and l.status = 'active'
      join rental_units ru on ru.id = l.unit_id where ru.unit_number = p_unit and lt.tenant_id in (select resident_me()) limit 1;
    select name into v_name from tenants where id = v_tenant;
  else
    v_owner := condo_owner_for_email(auth.email());
    select name into v_name from condo_owners where id = v_owner;
  end if;
  insert into guest_requests (unit_number, requester_kind, requester_name, requester_email, tenant_id, owner_id, lease_id, guest_name, guest_phone,
    overnight, parking, start_date, end_date, vehicle_make, vehicle_model, vehicle_color, plate, plate_state, note, created_by)
  values (p_unit, v_kind, v_name, lower(auth.email()), v_tenant, v_owner, v_lease, trim(p_guest), nullif(trim(coalesce(p_guest_phone, '')), ''),
    coalesce(p_overnight, false), coalesce(p_parking, false), p_start, p_end, nullif(trim(coalesce(p_make, '')), ''), nullif(trim(coalesce(p_model, '')), ''),
    nullif(trim(coalesce(p_color, '')), ''), upper(nullif(trim(coalesce(p_plate, '')), '')), upper(nullif(trim(coalesce(p_plate_state, '')), '')),
    left(nullif(trim(coalesce(p_note, '')), ''), 500), lower(auth.email()))
  returning * into g;
  v_n := case when g.overnight then guest_nights_12mo(g.unit_number, g.guest_name, g.end_date, g.id) + (g.end_date - g.start_date) end;
  perform vehicle_alert('Guest request — Unit ' || g.unit_number || ' (' || g.guest_name || ')',
    '<p><b>' || repair_esc(coalesce(v_name, auth.email())) || '</b> (' || v_kind || ', Unit ' || repair_esc(g.unit_number) || ') asks for '
    || case when g.overnight and g.parking then 'an overnight stay and guest parking' when g.overnight then 'an overnight stay' else 'guest parking' end
    || ' for <b>' || repair_esc(g.guest_name) || '</b>, ' || to_char(g.start_date, 'FMMM/FMDD/YYYY') || ' to ' || to_char(g.end_date, 'FMMM/FMDD/YYYY') || '.</p>'
    || case when v_n is not null then '<p>Overnight nights for this guest in the last 12 months, counting this request: <b>' || v_n || '</b> (the lease allows 13 without written consent).</p>' else '' end
    || '<p>Approve or decline it on the Parking page: https://2ndchinc.org/parking/</p>');
  return guest_row(g);
end;
$$;
revoke all on function guest_request_create(text, text, text, boolean, boolean, date, date, text, text, text, text, text, text) from public, anon;
grant execute on function guest_request_create(text, text, text, boolean, boolean, date, date, text, text, text, text, text, text) to authenticated;

create or replace function guest_request_cancel(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  update guest_requests set status = 'cancelled' where id = p_id and status in ('pending', 'approved') and decal_given_at is null
    and unit_number in (select unit_number from guest_my_units());
  if not found then raise exception 'That request can''t be cancelled here. If the decal was already handed over, return it to the office.'; end if;
end;
$$;
revoke all on function guest_request_cancel(uuid) from public, anon;
grant execute on function guest_request_cancel(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Staff
create or replace function guest_requests_staff_list(p_all boolean)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(guest_row(g) order by g.status <> 'pending', (g.status = 'approved' and g.parking and g.decal_given_at is null) desc, g.start_date desc)
    from guest_requests g
    where coalesce(p_all, false) or g.status = 'pending' or (g.status = 'approved' and (g.end_date >= current_date - 7 or (g.parking and g.decal_given_at is null)))), '[]'::jsonb);
end;
$$;
revoke all on function guest_requests_staff_list(boolean) from public, anon;
grant execute on function guest_requests_staff_list(boolean) to authenticated;

create or replace function guest_request_staff_create(p_unit text, p_requester text, p_email text, p_guest text, p_guest_phone text, p_overnight boolean, p_parking boolean,
  p_start date, p_end date, p_make text, p_model text, p_color text, p_plate text, p_plate_state text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare g guest_requests;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from condo_units where unit_number = trim(p_unit)) then raise exception 'Unit % isn''t on file.', p_unit; end if;
  perform guest_validate(p_guest, p_overnight, p_parking, p_start, p_end, p_make, p_model, p_color, p_plate);
  insert into guest_requests (unit_number, requester_kind, requester_name, requester_email, guest_name, guest_phone, overnight, parking, start_date, end_date,
    vehicle_make, vehicle_model, vehicle_color, plate, plate_state, note, created_by)
  values (trim(p_unit), 'staff', nullif(trim(coalesce(p_requester, '')), ''), lower(nullif(trim(coalesce(p_email, '')), '')), trim(p_guest), nullif(trim(coalesce(p_guest_phone, '')), ''),
    coalesce(p_overnight, false), coalesce(p_parking, false), p_start, p_end, nullif(trim(coalesce(p_make, '')), ''), nullif(trim(coalesce(p_model, '')), ''),
    nullif(trim(coalesce(p_color, '')), ''), upper(nullif(trim(coalesce(p_plate, '')), '')), upper(nullif(trim(coalesce(p_plate_state, '')), '')),
    left(nullif(trim(coalesce(p_note, '')), ''), 500), lower(auth.email()))
  returning * into g;
  return guest_row(g);
end;
$$;
revoke all on function guest_request_staff_create(text, text, text, text, text, boolean, boolean, date, date, text, text, text, text, text, text) from public, anon;
grant execute on function guest_request_staff_create(text, text, text, text, text, boolean, boolean, date, date, text, text, text, text, text, text) to authenticated;

create or replace function guest_request_decide(p_id uuid, p_approve boolean, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare g guest_requests; v_n int; v_over boolean; v_phone text := (select value from portal_settings where key = 'org_phone'); v_what text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into g from guest_requests where id = p_id for update;
  if g.id is null then raise exception 'Request not found'; end if;
  if g.status <> 'pending' then raise exception 'This request was already %.', g.status; end if;
  if not p_approve and length(coalesce(trim(p_note), '')) < 3 then raise exception 'Say why the request is declined (the requester sees it).'; end if;
  v_n := case when g.overnight then guest_nights_12mo(g.unit_number, g.guest_name, g.end_date, g.id) + (g.end_date - g.start_date) end;
  v_over := p_approve and coalesce(v_n, 0) > 13;
  update guest_requests set status = case when p_approve then 'approved' else 'declined' end, staff_note = nullif(trim(coalesce(p_note, '')), ''),
    decided_by = lower(auth.email()), decided_at = now(), over_limit_consent = v_over
  where id = p_id returning * into g;
  v_what := case when g.overnight and g.parking then 'overnight stay and guest parking' when g.overnight then 'overnight stay' else 'guest parking' end;
  if g.requester_email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (g.requester_email,
      'Guest request ' || case when p_approve then 'approved' else 'declined' end || ' — ' || g.guest_name,
      '<p>Hi ' || repair_esc(split_part(coalesce(g.requester_name, ''), ' ', 1)) || ',</p><p>Your request for ' || v_what || ' for <b>' || repair_esc(g.guest_name) || '</b> at Unit '
      || repair_esc(g.unit_number) || ', ' || to_char(g.start_date, 'FMMM/FMDD/YYYY') || ' to ' || to_char(g.end_date, 'FMMM/FMDD/YYYY') || ', is <b>'
      || case when p_approve then 'approved' else 'declined' end || '</b>.</p>'
      || case when p_approve and g.parking then '<p>Pick up the guest parking decal from the office' || coalesce(' (' || v_phone || ')', '') || ' before your guest parks. The decal must be displayed in the guest''s vehicle (' || repair_esc(concat_ws(' ', g.vehicle_color, g.vehicle_make, g.vehicle_model)) || ', plate ' || repair_esc(coalesce(g.plate, '')) || '). Guest parking without a decal isn''t allowed.</p>' else '' end
      || case when v_over then '<p>This approval is the Landlord''s written consent for ' || repair_esc(g.guest_name) || ' to stay overnight beyond the lease''s 13 nights in 12 months, for these dates only.</p>' else '' end
      || case when g.staff_note is not null then '<p>Note from the office: ' || repair_esc(g.staff_note) || '</p>' else '' end
      || '<p>2nd Chance Housing</p>', 'guest_request');
  end if;
  return guest_row(g);
end;
$$;
revoke all on function guest_request_decide(uuid, boolean, text) from public, anon;
grant execute on function guest_request_decide(uuid, boolean, text) to authenticated;

create or replace function guest_request_decal(p_id uuid, p_decal text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare g guest_requests;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_decal), '')) < 1 then raise exception 'Enter the decal number.'; end if;
  update guest_requests set decal_number = trim(p_decal), decal_given_at = now(), decal_given_by = lower(auth.email())
   where id = p_id and status = 'approved' and parking and decal_given_at is null returning * into g;
  if g.id is null then raise exception 'Only an approved parking request without a decal yet can get one.'; end if;
  return guest_row(g);
end;
$$;
revoke all on function guest_request_decal(uuid, text) from public, anon;
grant execute on function guest_request_decal(uuid, text) to authenticated;
