-- The Human Mirror Phase N, handoff step 21: TN.4 own-room disclosure (closes NAVIGATOR.md gap N4: "Steer a person to a room the
-- Navigator runs without saying so"). A Navigator may also lease and run a home and rent its rooms (nav_units.operated_by_navigator).
--   * A match to a unit or room the person's OWN Navigator runs is marked "A room you run" on the file (nav_own_room).
--   * Before the placement can be confirmed (status approved), the person reads one sentence on screen and types their full name as on
--     file: they know their Navigator runs this home and rents them the room, they were told about other places, they choose this one,
--     and they can say no and keep looking without losing their Navigator's help. Kept with the place, the words and the date.
--     Enforced by a trigger on nav_referrals, so the existing nav_referral_step is not changed. A new match (another room) needs a new one.
--   * The office lists every such match, confirmed or not (nav_own_room_matches, office staff only), on the Navigators dashboard.
--   * Records already confirmed or moved in before today are left as they are (the trigger acts only on a change to approved).
-- No email is sent. New table carries explicit grants (CLAUDE.md, 10/30/2026): service_role only; authenticated and anon none.

create table public.nav_own_room_confirms (
  id uuid primary key default gen_random_uuid(),
  nav_referral_id uuid not null references public.nav_referrals(id) on delete cascade,
  nav_unit_id uuid not null references public.nav_units(id) on delete cascade,
  nav_room_id uuid references public.nav_rooms(id) on delete set null,
  navigator_id uuid not null references public.navigators(id) on delete cascade,
  consent_name text not null check (length(consent_name) between 2 and 200),
  consent_text text not null,
  recorded_by text not null,
  confirmed_at timestamptz not null default now()
);
create index nav_own_room_confirms_ref on public.nav_own_room_confirms (nav_referral_id, nav_unit_id);
alter table public.nav_own_room_confirms enable row level security;
revoke all on public.nav_own_room_confirms from public, anon, authenticated, service_role;
grant select, insert, update, delete on public.nav_own_room_confirms to service_role;

-- Is this file matched to a home its own Navigator runs?
create or replace function public.nav_own_room(r public.nav_referrals) returns boolean
language sql stable security definer set search_path = public as $$
  select r.nav_unit_id is not null and r.navigator_id is not null
     and exists (select 1 from nav_units u where u.id = r.nav_unit_id and u.operated_by_navigator = r.navigator_id);
$$;

create or replace function public.nav_own_room_place(r public.nav_referrals) returns text
language sql stable security definer set search_path = public as $$
  select u.address || coalesce(' ' || nullif(trim(u.unit_label), ''), '') || coalesce(', ' || (select rm.label from nav_rooms rm where rm.id = r.nav_room_id), '')
    from nav_units u where u.id = r.nav_unit_id;
$$;

create or replace function public.nav_own_room_words(r public.nav_referrals) returns text
language sql stable security definer set search_path = public as $$
  select 'I know that my Housing Navigator, ' || coalesce((select n.name from navigators n where n.id = r.navigator_id), 'my Navigator')
      || ', runs this home (' || coalesce(nav_own_room_place(r), 'this home') || ') and rents me the room. I was told about other places, and I choose this one.'
      || ' I can say no and keep looking, and my Navigator''s help does not depend on taking this room.';
$$;

-- The current confirmation for the file's current match (same unit and room), if any.
create or replace function public.nav_own_room_current(r public.nav_referrals) returns public.nav_own_room_confirms
language sql stable security definer set search_path = public as $$
  select c.* from nav_own_room_confirms c
   where c.nav_referral_id = r.id and c.nav_unit_id = r.nav_unit_id and c.nav_room_id is not distinct from r.nav_room_id
   order by c.confirmed_at desc limit 1;
$$;

-- What the person's file shows.
create or replace function public.nav_own_room_state(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r nav_referrals; c nav_own_room_confirms;
begin
  if not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  select * into r from nav_referrals where id = p_id;
  if not nav_own_room(r) then return jsonb_build_object('own_room', false); end if;
  c := nav_own_room_current(r);
  return jsonb_build_object('own_room', true, 'place', nav_own_room_place(r), 'words', nav_own_room_words(r),
    'full_name', trim(r.first_name || ' ' || coalesce(r.last_name, '')), 'status', r.status,
    'confirmed', case when c.id is null then null else jsonb_build_object('name', c.consent_name, 'at', c.confirmed_at, 'words', c.consent_text) end);
end $$;

-- The person confirms, typing their own full name on the Navigator's (or the office's) screen.
create or replace function public.nav_own_room_confirm(p_id uuid, p_consent_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r nav_referrals; v_role text := nav_actor_role(); v_full text;
begin
  if v_role is null or not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  select * into r from nav_referrals where id = p_id;
  if not nav_own_room(r) then raise exception 'This match is not to a home the Navigator runs.'; end if;
  if r.status not in ('matched', 'approved') then raise exception 'Confirm while the match is open (matched).'; end if;
  v_full := trim(r.first_name || ' ' || coalesce(r.last_name, ''));
  if lower(regexp_replace(trim(coalesce(p_consent_name, '')), '\s+', ' ', 'g')) <> lower(regexp_replace(v_full, '\s+', ' ', 'g')) then
    raise exception 'The person types their own full name, as on file: %.', v_full using errcode = '22023';
  end if;
  insert into nav_own_room_confirms (nav_referral_id, nav_unit_id, nav_room_id, navigator_id, consent_name, consent_text, recorded_by)
  values (p_id, r.nav_unit_id, r.nav_room_id, r.navigator_id, trim(p_consent_name), nav_own_room_words(r), lower(auth.email()));
  perform nav_log('own_room_confirmed', 'The person confirmed they know the Navigator runs ' || coalesce(nav_own_room_place(r), 'this home')
    || ' and chose it (typed ' || trim(p_consent_name) || ').', p_id);
  return nav_own_room_state(p_id);
end $$;

-- No placement in a home the Navigator runs without the person's confirmation.
create or replace function public.nav_own_room_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and nav_own_room(new) and (nav_own_room_current(new)).id is null then
    raise exception 'This is a home the Navigator runs. First the person confirms on screen that they know it and chose it (A room you run, on the file).'
      using errcode = '22023';
  end if;
  return new;
end $$;
create trigger nav_referrals_own_room_guard before update of status on public.nav_referrals
  for each row execute function public.nav_own_room_guard();

-- The office's list: every file matched to (or housed in) a home its Navigator runs, with the confirmation.
create or replace function public.nav_own_room_matches() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Office staff only.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'label', nav_ref_label(r), 'status', r.status, 'is_sample', r.is_sample,
      'navigator', (select n.name from navigators n where n.id = r.navigator_id), 'place', nav_own_room_place(r),
      'matched_at', r.matched_at, 'confirmed', (select jsonb_build_object('name', c.consent_name, 'at', c.confirmed_at) from nav_own_room_confirms c
                                                where c.id = (nav_own_room_current(r)).id))
      order by r.matched_at desc nulls last)
    from nav_referrals r where r.status in ('matched', 'approved', 'moved_in') and nav_own_room(r)), '[]'::jsonb);
end $$;

revoke all on function public.nav_own_room(public.nav_referrals), public.nav_own_room_place(public.nav_referrals), public.nav_own_room_words(public.nav_referrals),
  public.nav_own_room_current(public.nav_referrals), public.nav_own_room_guard() from public, anon, authenticated;
grant execute on function public.nav_own_room(public.nav_referrals), public.nav_own_room_place(public.nav_referrals), public.nav_own_room_words(public.nav_referrals),
  public.nav_own_room_current(public.nav_referrals) to service_role;
revoke all on function public.nav_own_room_state(uuid), public.nav_own_room_confirm(uuid, text), public.nav_own_room_matches() from public, anon;
grant execute on function public.nav_own_room_state(uuid), public.nav_own_room_confirm(uuid, text), public.nav_own_room_matches() to authenticated, service_role;
