-- Owner requests (Stephen, 10/12/2026): the owners' version of the tenant repair request, for ROCA1.
--
-- Tenants file repairs for their own home. Owners also need to report and rank problems with the COMMON property (both
-- buildings) and with what ROCA1 is responsible for. So an owner request carries what tenants' do not: where it is (6622,
-- 6626, both, or inside my own unit), a category that maps to the ROCA1 budget codes (Budget FY2025: 300 utilities,
-- 400 grounds/commons, 500 buildings), urgency, a safety / housing-inspector flag, and a link to the board's REPAIR
-- PRIORITY LIST ("ROCA1 Repair Rankings", ranked 1 to 32 with estimates and urgent notes), which every owner can read.
-- Repairs to protect the common property are specially assessed to the owner responsible (By-Laws §1500(3)); that is a
-- board vote (see 20261106070000_roca_budget_assessments_liens), never an automatic charge from a request.
-- Locked like the rest of the schema: RLS on, no policies, everything through the functions below.

-- ---------------------------------------------------------------------------
-- The board's repair priority list (from "ROCA1 Repair Rankings"). Staff keep it current; owners read it.
create table if not exists roca_repair_priorities (
  id uuid primary key default gen_random_uuid(),
  rank_label text not null,                -- "1 (A)", "2", ... as printed
  sort numeric not null,
  title text not null,
  estimate numeric(12,2),                  -- null = not evaluated
  detail text,
  urgent boolean not null default false,
  budget_code text,
  status text not null default 'open' check (status in ('open', 'scheduled', 'done', 'dropped')),
  updated_at timestamptz not null default now()
);
alter table roca_repair_priorities enable row level security;

create table if not exists roca_request_categories (
  code text primary key,
  label text not null,
  hint text,
  scope text not null check (scope in ('common', 'unit')),   -- common = association property; unit = inside the owner's own unit
  budget_code text,
  sort int not null default 100
);
alter table roca_request_categories enable row level security;

create table if not exists owner_requests (
  id uuid primary key default gen_random_uuid(),
  number int generated always as identity,
  owner_id uuid not null references condo_owners(id),
  location text not null check (location in ('6622', '6626', 'both', 'my_unit')),
  unit_number text,
  category text not null references roca_request_categories(code),
  subject text not null,
  description text not null,
  urgency text not null default 'normal' check (urgency in ('emergency', 'urgent', 'normal', 'wish')),
  safety boolean not null default false,            -- a safety or health hazard
  inspector_note boolean not null default false,    -- a housing inspector has noted it
  photos text[] not null default '{}',
  status text not null default 'new' check (status in ('new', 'reviewing', 'ranked', 'approved', 'scheduled', 'done', 'declined', 'withdrawn')),
  priority_id uuid references roca_repair_priorities(id),
  budget_code text,
  estimate numeric(12,2),
  response text,                                    -- the board / staff answer, shown to the owner
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists owner_requests_owner_idx on owner_requests (owner_id, created_at desc);
alter table owner_requests enable row level security;

create table if not exists owner_request_updates (
  id bigint generated always as identity primary key,
  request_id uuid not null references owner_requests(id) on delete cascade,
  at timestamptz not null default now(),
  by_role text not null check (by_role in ('owner', 'staff')),
  by_email text,
  note text not null,
  internal boolean not null default false           -- staff-only note, never shown to the owner
);
alter table owner_request_updates enable row level security;

-- Photos
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('owner-requests', 'owner-requests', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/heic'])
on conflict (id) do nothing;
drop policy if exists "owner-requests upload" on storage.objects;
create policy "owner-requests upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'owner-requests' and (storage.foldername(name))[1]::uuid = condo_owner_for_email(auth.email()));
drop policy if exists "owner-requests read" on storage.objects;
create policy "owner-requests read" on storage.objects for select to authenticated
  using (bucket_id = 'owner-requests' and ((storage.foldername(name))[1]::uuid = condo_owner_for_email(auth.email()) or (condo_session_ok() and condo_is_staff())));

-- ---------------------------------------------------------------------------
-- Seed: categories (budget codes from ROCA1 Budget FY2025) and the repair priority list (ROCA1 Repair Rankings).
insert into roca_request_categories (code, label, hint, scope, budget_code, sort) values
  ('roof',        'Roof and chimneys',            'Leaks, flashing, chimneys and stacks',                         'common', '501', 10),
  ('siding',      'Siding, porches, tuckpointing','Holes, peeling paint, rot, rodent entry points',              'common', '509', 20),
  ('windows',     'Windows and window wells',     'Rotted frames, window wells, broken glass',                    'common', '506', 30),
  ('water',       'Water lines and shut-offs',    'Cold or hot water mains, pressure, joint failures',            'common', '511', 40),
  ('sewer',       'Sewer, stacks and clean-outs', 'Leaks into the basement, backups',                            'common', '511', 50),
  ('doors',       'Entry, basement and back doors','Glass entry, basement front door, back doors, closers',       'common', '505', 60),
  ('locks',       'Locks, keys, intercom, cameras','Door locks, key codes, intercom, surveillance',               'common', '307', 70),
  ('gutters',     'Gutters and downspouts',       'Drainage',                                                     'common', '501', 80),
  ('lot',         'Parking lot and drive',        'Pebbles, potholes, striping',                                  'common', '512', 90),
  ('walks',       'Walkways, stairs, concrete',   'Cracks, lifts, entry stairs, covering',                        'common', '509', 100),
  ('lighting',    'Lighting',                     'Exterior, hallway and basement lights, bulbs, motion sensors', 'common', '510', 110),
  ('halls',       'Hallways, foyer, flooring',    'Paint, flooring, lobby repair',                                'common', '507', 120),
  ('cleaning',    'Common area cleaning',         'Foyer, hallways, furnace and water heater rooms',              'common', '408', 130),
  ('grounds',     'Lawn, trees, snow and salt',   'Landscaping, edging, snow plow, salt, tree service',           'common', '402', 140),
  ('garbage',     'Garbage and debris',           'Collection site, debris',                                      'common', '409', 150),
  ('pests',       'Pest control',                 'Bed bugs, roaches, mice, ants in common areas',                'common', '206', 160),
  ('utilities',   'Utilities and fire safety',    'Common electric, gas, water heater, fire safety',              'common', '301', 170),
  ('basement',    'Basement, hookups and storage','Washer and dryer hookups, basement lighting, storage rooms',   'common', '503', 180),
  ('unit',        'Inside my own unit',           'A problem inside my unit that I may be responsible for',       'unit',   null,  190),
  ('other',       'Something else',               'Anything not listed',                                          'common', null,  200)
on conflict (code) do nothing;

insert into roca_repair_priorities (rank_label, sort, title, estimate, detail, urgent, budget_code)
select * from (values
  ('1 (A)', 1.1, 'Roof replacement', 56000, 'A full roof replacement is overdue: repeated leak reports over the East portion of 6626''s roof at every rainfall. All joints around the chimneys and stacks have failed.', true, '502'),
  ('1 (B)', 1.2, 'Roof minor repairs', 8000, 'Seal all edges to stop current leaks, evaluated instead of a complete roof replacement.', true, '501'),
  ('2', 2, 'Install siding on upper porches and parts of the upper buildings', null, 'Housing inspector made a note but has not written the order yet. Holes plus peeling and chipping paint need repair.', true, '509'),
  ('3', 3, 'Secure window wells', 800, 'Remove growth from inside the wells. Seal the wells to prevent animal and water entry.', true, '504'),
  ('4', 4, 'Replace cold water lines in 6626 from the meter to the 6622 coupling', 9000, 'Rust and limescale buildup is causing joint failures. Add shut-offs to individual units.', true, '511'),
  ('5', 5, 'Replace sewer clean-outs', 750, 'Units 12 and 16 main stack is leaking into the basement. Replace all stacks with permanent clean-outs (temporary ones are installed).', true, '511'),
  ('6', 6, 'Replace hot water lines in 6622', 4500, 'Rust, limescale and reduced water pressure are causing joint failures. This was done in 6626.', true, '511'),
  ('7', 7, 'Repair or replace 6626 front basement entry doors, damaged walls and missing Schlage storeroom lock with ROCA1 key code', 1200, 'Calls for repairs are steady, so this repair is a priority.', true, '505'),
  ('8', 8, 'Gutters and downspout repairs', 1000, 'Improve rain water drainage.', false, '501'),
  ('9', 9, 'Replace parking lot', 32000, 'Current plan: sweep away pebbles weekly and repair problem areas each year (about $2,500 for 2025).', false, '512'),
  ('10', 10, 'Repair entry stairs leading to both glass doors and add covering', null, 'Housing inspector made a note and suggests a better solution; has not written the order yet.', false, '509'),
  ('11', 11, 'Pest control', null, 'Bed bug heaters, roach control equipment and materials, mice control and ant control equipment and materials needed.', false, '206'),
  ('12', 12, 'Tuckpointing, entire property', 1500, 'Too many rodent entry points.', false, '509'),
  ('13', 13, 'Install siding on vertical porch walls', null, 'Wood exposure leading to rot.', false, '509'),
  ('14', 14, 'Repair concrete cracks, holes and lifts', 475, 'Repair walkways leading to the front entry doors.', false, '509'),
  ('15', 15, 'Replace both back doors (convert to 36" steel entry doors)', 2000, 'Add a security bar for exit only.', false, '505'),
  ('16', 16, 'Replace 6626 front entry door', 1200, 'Doors seldom close properly.', false, '505'),
  ('17', 17, 'Repair 6622 front entry door', 550, 'Doors seldom close properly.', false, '505'),
  ('18', 18, 'Replace exterior lights', 4000, 'To match surrounding lights.', false, '510'),
  ('19', 19, 'Replace surveillance system', null, 'Low priority.', false, '307'),
  ('20', 20, 'Repair or replace intercom system', null, 'Eight companies contacted for quotes.', false, '307'),
  ('21', 21, 'Lawn edging', null, 'All sidewalks need edging.', false, '402'),
  ('22', 22, 'Furnace and water heater room cleaning', null, 'Remove past sewer backup materials; clean and sanitize the rooms.', false, '408'),
  ('24', 24, 'Basement lighting', null, 'Convert to motion sensing to reduce energy cost and save bulbs; current LED bulbs have a short lifespan.', false, '510'),
  ('25', 25, 'Hallway lighting', null, 'Convert to motion sensing to reduce energy cost and save bulbs; current LED bulbs have a short lifespan.', false, '510'),
  ('26', 26, 'Paint foyer', null, 'Low priority.', false, '507'),
  ('27', 27, 'Hallway flooring', null, 'Government agency staff routinely check in on veterans and elderly residents; a note has been made about the state of the flooring.', false, '508'),
  ('28', 28, 'Common area cleaning', null, 'A note has been made about the cleanliness of the foyer and hallways.', false, '513'),
  ('29', 29, 'Garbage collection site', null, 'Debris litters the surrounding area and needs constant attention.', false, '409'),
  ('30', 30, 'Utility door locks', null, 'Suggestion to update to monitored entry; pilot light tampering complaints have been reported.', false, '307'),
  ('31', 31, 'Individual unit electrical and gas lines in the basement', null, 'Repeated requests for a bank of outlets and gas lines for each unit''s washer and dryer hookups.', false, '503'),
  ('32', 32, 'East-facing windows', null, 'Evaluate and treat each window frame; Units 2, 4, 12, 14 and 16 have rotted wood from rain exposure. Work on Units 12 and 16 has been contracted.', false, '506')
) v(rank_label, sort, title, estimate, detail, urgent, budget_code)
where not exists (select 1 from roca_repair_priorities);

-- ---------------------------------------------------------------------------
-- Owner: categories, the priority list and my own requests (with the replies meant for me).
create or replace function owner_requests_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(cu.unit_number order by nullif(regexp_replace(cu.unit_number, '\D', '', 'g'), '')::int)
        from condo_ownerships s join condo_units cu on cu.id = s.unit_id where s.is_current and s.owner_id = v_owner), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c) - 'budget_code' order by c.sort) from roca_request_categories c), '[]'::jsonb),
    'priorities', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'rank', p.rank_label, 'title', p.title, 'estimate', p.estimate, 'detail', p.detail,
        'urgent', p.urgent, 'status', p.status) order by p.sort) from roca_repair_priorities p where p.status <> 'dropped'), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'location', r.location, 'unit', r.unit_number, 'category', r.category,
        'subject', r.subject, 'description', r.description, 'urgency', r.urgency, 'safety', r.safety, 'inspector_note', r.inspector_note, 'photos', r.photos,
        'status', r.status, 'response', r.response, 'created_at', r.created_at, 'priority_rank', (select rank_label from roca_repair_priorities where id = r.priority_id),
        'updates', coalesce((select jsonb_agg(jsonb_build_object('at', u.at, 'by', u.by_role, 'note', u.note) order by u.at)
                   from owner_request_updates u where u.request_id = r.id and not u.internal), '[]'::jsonb))
        order by r.created_at desc) from owner_requests r where r.owner_id = v_owner), '[]'::jsonb));
end;
$$;
revoke all on function owner_requests_mine() from public, anon;
grant execute on function owner_requests_mine() to authenticated;

create or replace function owner_request_create(p_location text, p_unit text, p_category text, p_subject text, p_description text,
  p_urgency text, p_safety boolean, p_inspector boolean, p_photos text[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); r owner_requests; v_scope text; v_budget text;
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_subject, ''))) < 3 or length(trim(coalesce(p_description, ''))) < 5 then raise exception 'Please say what needs attention and describe it.'; end if;
  select scope, budget_code into v_scope, v_budget from roca_request_categories where code = p_category;
  if v_scope is null then raise exception 'Choose what kind of problem it is.'; end if;
  if p_location = 'my_unit' or v_scope = 'unit' then
    if not exists (select 1 from condo_ownerships s join condo_units cu on cu.id = s.unit_id where s.is_current and s.owner_id = v_owner and cu.unit_number = p_unit) then
      raise exception 'Choose which of your units it is in.'; end if;
  end if;
  if exists (select 1 from unnest(coalesce(p_photos, '{}')) ph where split_part(ph, '/', 1)::uuid <> v_owner) then raise exception 'Bad photo path'; end if;
  insert into owner_requests (owner_id, location, unit_number, category, subject, description, urgency, safety, inspector_note, photos, budget_code)
  values (v_owner, case when v_scope = 'unit' then 'my_unit' else p_location end, nullif(p_unit, ''), p_category, trim(p_subject), trim(p_description),
          coalesce(nullif(p_urgency, ''), 'normal'), coalesce(p_safety, false), coalesce(p_inspector, false), coalesce(p_photos, '{}'), v_budget)
  returning * into r;
  insert into owner_request_updates (request_id, by_role, by_email, note) values (r.id, 'owner', auth.email(), 'Request sent.');
  return jsonb_build_object('number', r.number);
end;
$$;
revoke all on function owner_request_create(text, text, text, text, text, text, boolean, boolean, text[]) from public, anon;
grant execute on function owner_request_create(text, text, text, text, text, text, boolean, boolean, text[]) to authenticated;

create or replace function owner_request_comment(p_id uuid, p_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_note, ''))) < 2 then raise exception 'Write a note first.'; end if;
  if not exists (select 1 from owner_requests where id = p_id and owner_id = v_owner) then raise exception 'Request not found'; end if;
  insert into owner_request_updates (request_id, by_role, by_email, note) values (p_id, 'owner', auth.email(), trim(p_note));
  update owner_requests set updated_at = now() where id = p_id;
end;
$$;
revoke all on function owner_request_comment(uuid, text) from public, anon;
grant execute on function owner_request_comment(uuid, text) to authenticated;

create or replace function owner_request_withdraw(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  update owner_requests set status = 'withdrawn', closed_at = now(), updated_at = now()
   where id = p_id and owner_id = v_owner and status in ('new', 'reviewing', 'ranked');
  if not found then raise exception 'Only an open request can be withdrawn.'; end if;
  insert into owner_request_updates (request_id, by_role, by_email, note) values (p_id, 'owner', auth.email(), 'Withdrawn by the owner.');
end;
$$;
revoke all on function owner_request_withdraw(uuid) from public, anon;
grant execute on function owner_request_withdraw(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Staff: the queue, one update function, and the priority list.
create or replace function owner_requests_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'owner', o.name, 'owner_email', o.email, 'owner_phone', o.phone_mobile,
        'location', r.location, 'unit', r.unit_number, 'category', c.label, 'subject', r.subject, 'description', r.description, 'urgency', r.urgency, 'safety', r.safety,
        'inspector_note', r.inspector_note, 'photos', r.photos, 'status', r.status, 'priority_id', r.priority_id, 'budget_code', r.budget_code, 'estimate', r.estimate,
        'response', r.response, 'created_at', r.created_at,
        'updates', coalesce((select jsonb_agg(jsonb_build_object('at', u.at, 'by', u.by_role, 'email', u.by_email, 'note', u.note, 'internal', u.internal) order by u.at)
                   from owner_request_updates u where u.request_id = r.id), '[]'::jsonb))
        order by (r.status in ('done', 'declined', 'withdrawn')), case r.urgency when 'emergency' then 0 when 'urgent' then 1 when 'normal' then 2 else 3 end, r.created_at desc)
        from owner_requests r join condo_owners o on o.id = r.owner_id join roca_request_categories c on c.code = r.category), '[]'::jsonb),
    'priorities', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'rank', p.rank_label, 'title', p.title, 'estimate', p.estimate, 'status', p.status, 'urgent', p.urgent)
        order by p.sort) from roca_repair_priorities p), '[]'::jsonb));
end;
$$;
revoke all on function owner_requests_staff_list() from public, anon;
grant execute on function owner_requests_staff_list() to authenticated;

create or replace function owner_request_staff_update(p_id uuid, p_status text, p_priority uuid, p_budget text, p_estimate numeric, p_response text, p_internal_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare old owner_requests;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into old from owner_requests where id = p_id;
  if old.id is null then raise exception 'Request not found'; end if;
  if p_status not in ('new', 'reviewing', 'ranked', 'approved', 'scheduled', 'done', 'declined', 'withdrawn') then raise exception 'Unknown status'; end if;
  update owner_requests set status = p_status, priority_id = p_priority, budget_code = nullif(trim(p_budget), ''), estimate = p_estimate,
         response = nullif(trim(p_response), ''), updated_at = now(),
         closed_at = case when p_status in ('done', 'declined', 'withdrawn') then coalesce(closed_at, now()) end
   where id = p_id;
  if p_status is distinct from old.status then
    insert into owner_request_updates (request_id, by_role, by_email, note) values (p_id, 'staff', auth.email(), 'Status: ' || replace(p_status, '_', ' ') || '.');
  end if;
  if nullif(trim(p_response), '') is distinct from old.response and nullif(trim(p_response), '') is not null then
    insert into owner_request_updates (request_id, by_role, by_email, note) values (p_id, 'staff', auth.email(), trim(p_response));
  end if;
  if length(trim(coalesce(p_internal_note, ''))) > 0 then
    insert into owner_request_updates (request_id, by_role, by_email, note, internal) values (p_id, 'staff', auth.email(), trim(p_internal_note), true);
  end if;
end;
$$;
revoke all on function owner_request_staff_update(uuid, text, uuid, text, numeric, text, text) from public, anon;
grant execute on function owner_request_staff_update(uuid, text, uuid, text, numeric, text, text) to authenticated;

create or replace function roca_priority_staff_update(p_id uuid, p_status text, p_estimate numeric)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('open', 'scheduled', 'done', 'dropped') then raise exception 'Unknown status'; end if;
  update roca_repair_priorities set status = p_status, estimate = p_estimate, updated_at = now() where id = p_id;
end;
$$;
revoke all on function roca_priority_staff_update(uuid, text, numeric) from public, anon;
grant execute on function roca_priority_staff_update(uuid, text, numeric) to authenticated;

-- The owner's id, used as the first folder of their photo uploads.
create or replace function owner_my_id()
returns uuid
language plpgsql stable security definer set search_path = public as $$
begin
  if not condo_session_ok() then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  return condo_owner_for_email(auth.email());
end;
$$;
revoke all on function owner_my_id() from public, anon;
grant execute on function owner_my_id() to authenticated;
