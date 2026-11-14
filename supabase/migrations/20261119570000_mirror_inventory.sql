-- The Human Mirror Phase 8, T8.7: inventory of donated goods (Stephen 11/13/2026 "let us move on"; handoff step 14). Database part.
--
-- Rules (D-38, defaults chosen by Claude)
--   (a) Each organization keeps its own inventory: clothing, shoes, coats, bedding, furniture, kitchen, hygiene, baby, school, household,
--       other; with size, who it fits, condition (new, like new, good, fair), season and quantity on hand. Coordinators and organization
--       admins add and change items (with the authenticator); volunteers do not. Other organizations never see it.
--   (b) An item holds no one's personal information; it is the organization's stock. Quantities never go below 0.
--   (c) Giving: a coordinator records what was given and how many. To a person in the Mirror it needs the person's everyday
--       "see and change" (topic everyday) and goes on the person's Mirror: they see what they received, from which organization, when.
--       Giving to someone not in the Mirror stores no name; it only counts.
--   (d) A gift recorded by mistake is marked "returned" (with a note): the quantity goes back on the shelf; nothing is deleted.
--   (e) Counts only (on hand, given in the last 30 days); no person scores.
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only; authenticated and anon none; row security on.

create table mirror.inventory_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references mirror.organizations(id) on delete restrict,
  category text not null check (category in ('clothing', 'shoes', 'coats', 'bedding', 'furniture', 'kitchen', 'hygiene', 'baby', 'school', 'household', 'other')),
  item text not null check (length(btrim(item)) between 1 and 120),
  size text check (size is null or length(size) <= 40),
  fits text check (fits is null or fits in ('women', 'men', 'girls', 'boys', 'baby', 'anyone')),
  condition text not null default 'good' check (condition in ('new', 'like_new', 'good', 'fair')),
  season text not null default 'all' check (season in ('all', 'winter', 'summer', 'spring_fall')),
  quantity int not null default 1 check (quantity >= 0 and quantity <= 100000),
  location text check (location is null or length(location) <= 120),
  note text check (note is null or length(note) <= 500),
  active boolean not null default true,
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index inventory_items_org on mirror.inventory_items (organization_id, category);

create table mirror.inventory_given (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references mirror.inventory_items(id) on delete restrict,
  organization_id uuid not null references mirror.organizations(id) on delete restrict,
  individual_id uuid references mirror.individuals(id) on delete cascade,     -- null = someone not in the Mirror (no name kept)
  quantity int not null check (quantity between 1 and 1000),
  given_on date not null default current_date,
  note text check (note is null or length(note) <= 500),
  given_by text not null,
  given_by_role text not null,
  returned_at timestamptz,
  returned_note text check (returned_note is null or length(returned_note) <= 500),
  created_at timestamptz not null default now()
);
create index inventory_given_item on mirror.inventory_given (item_id);
create index inventory_given_person on mirror.inventory_given (individual_id) where individual_id is not null;

create trigger inventory_items_touch before update on mirror.inventory_items for each row execute function mirror.touch();
create trigger inventory_items_no_truncate before truncate on mirror.inventory_items for each statement execute function mirror.resource_no_truncate();
create trigger inventory_given_no_truncate before truncate on mirror.inventory_given for each statement execute function mirror.resource_no_truncate();

alter table mirror.inventory_items enable row level security;
alter table mirror.inventory_given enable row level security;
revoke all on mirror.inventory_items, mirror.inventory_given from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.inventory_items, mirror.inventory_given to service_role;

-- ---------------------------------------------------------------- the organization's inventory
create or replace function mirror.inventory_item_json(i mirror.inventory_items) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select jsonb_build_object('id', i.id, 'category', i.category, 'item', i.item, 'size', i.size, 'fits', i.fits, 'condition', i.condition,
    'season', i.season, 'quantity', i.quantity, 'location', i.location, 'note', i.note, 'active', i.active, 'updated_at', i.updated_at,
    'given_30', (select coalesce(sum(g.quantity), 0) from mirror.inventory_given g where g.item_id = i.id and g.returned_at is null
                 and g.given_on >= current_date - 30));
$$;

create or replace function public.mirror_inventory(p_org uuid) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
begin
  if not mirror.coordinates(p_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(mirror.inventory_item_json(i) order by i.active desc, i.category, lower(i.item), i.size)
      from mirror.inventory_items i where i.organization_id = p_org), '[]'::jsonb),
    'given_30', (select coalesce(sum(g.quantity), 0) from mirror.inventory_given g where g.organization_id = p_org and g.returned_at is null
                 and g.given_on >= current_date - 30),
    'given_30_outside', (select coalesce(sum(g.quantity), 0) from mirror.inventory_given g where g.organization_id = p_org and g.returned_at is null
                 and g.given_on >= current_date - 30 and g.individual_id is null));
end $$;

-- add (no id) or change (id); quantity is set directly (a count of what is on the shelf)
create or replace function public.mirror_inventory_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_item text := btrim(coalesce(p ->> 'item', ''));
  v_qty int;
  i mirror.inventory_items;
begin
  if v_id is not null then
    select * into i from mirror.inventory_items where id = v_id;
    if not found then raise exception 'That item is not available.' using errcode = 'P0002'; end if;
    v_org := i.organization_id;
  end if;
  if v_org is null or not mirror.coordinates(v_org) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  if length(v_item) = 0 then raise exception 'Say what the item is, for example "Winter coat".' using errcode = '22023'; end if;
  if length(v_item) > 120 then raise exception 'Please keep the item name to 120 letters.' using errcode = '22023'; end if;
  begin v_qty := coalesce(nullif(p ->> 'quantity', '')::int, 1);
  exception when others then raise exception 'Enter how many, as a whole number.' using errcode = '22023'; end;
  if v_qty < 0 or v_qty > 100000 then raise exception 'Enter how many, from 0 up.' using errcode = '22023'; end if;
  if v_id is null then
    insert into mirror.inventory_items (organization_id, category, item, size, fits, condition, season, quantity, location, note, created_by)
    values (v_org, coalesce(nullif(p ->> 'category', ''), 'other'), v_item, nullif(btrim(coalesce(p ->> 'size', '')), ''), nullif(p ->> 'fits', ''),
            coalesce(nullif(p ->> 'condition', ''), 'good'), coalesce(nullif(p ->> 'season', ''), 'all'), v_qty,
            nullif(btrim(coalesce(p ->> 'location', '')), ''), nullif(btrim(coalesce(p ->> 'note', '')), ''), lower(auth.email()))
    returning * into i;
  else
    update mirror.inventory_items set category = coalesce(nullif(p ->> 'category', ''), category), item = v_item,
      size = nullif(btrim(coalesce(p ->> 'size', '')), ''), fits = nullif(p ->> 'fits', ''),
      condition = coalesce(nullif(p ->> 'condition', ''), condition), season = coalesce(nullif(p ->> 'season', ''), season), quantity = v_qty,
      location = nullif(btrim(coalesce(p ->> 'location', '')), ''), note = nullif(btrim(coalesce(p ->> 'note', '')), ''),
      active = coalesce((p ->> 'active')::boolean, active)
     where id = i.id returning * into i;
  end if;
  return mirror.inventory_item_json(i);
end $$;

-- give: p = item_id, quantity, individual_id (optional), note
create or replace function public.mirror_inventory_give(p jsonb) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  i mirror.inventory_items;
  v_ind uuid := nullif(p ->> 'individual_id', '')::uuid;
  v_qty int;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_role text;
  g jsonb;
  x mirror.inventory_given;
begin
  select * into i from mirror.inventory_items where id = nullif(p ->> 'item_id', '')::uuid for update;
  if not found or not i.active then raise exception 'That item is not available.' using errcode = 'P0002'; end if;
  if not mirror.coordinates(i.organization_id) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  begin v_qty := coalesce(nullif(p ->> 'quantity', '')::int, 1);
  exception when others then raise exception 'Enter how many, as a whole number.' using errcode = '22023'; end;
  if v_qty < 1 then raise exception 'Enter how many, 1 or more.' using errcode = '22023'; end if;
  if v_qty > i.quantity then raise exception 'Only % on hand.', i.quantity using errcode = '22023'; end if;
  if length(coalesce(v_note, '')) > 500 then raise exception 'The note is too long (500 letters at most).' using errcode = '22023'; end if;
  v_role := mirror.my_role(i.organization_id);
  if v_ind is not null then
    g := mirror.require(v_ind, 'general', 'edit', i.organization_id, 'inventory_given', null);
    if (g ->> 'role') = 'self' then raise exception 'The organization records what it gives.' using errcode = '42501'; end if;
    v_role := g ->> 'role';
  end if;
  update mirror.inventory_items set quantity = quantity - v_qty where id = i.id;
  insert into mirror.inventory_given (item_id, organization_id, individual_id, quantity, note, given_by, given_by_role)
  values (i.id, i.organization_id, v_ind, v_qty, v_note, lower(auth.email()), coalesce(v_role, 'coordinator'))
  returning * into x;
  return jsonb_build_object('id', x.id, 'left', i.quantity - v_qty);
end $$;

-- a gift recorded by mistake: marked returned, quantity back on the shelf
create or replace function public.mirror_inventory_return(p_given uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare x mirror.inventory_given;
begin
  select * into x from mirror.inventory_given where id = p_given for update;
  if not found then raise exception 'That gift is not available.' using errcode = 'P0002'; end if;
  if not mirror.coordinates(x.organization_id) then
    raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501';
  end if;
  if x.individual_id is not null then perform mirror.require(x.individual_id, 'general', 'edit', x.organization_id, 'inventory_given', x.id::text); end if;
  if x.returned_at is not null then raise exception 'Already marked returned.' using errcode = '22023'; end if;
  if length(coalesce(p_note, '')) > 500 then raise exception 'The note is too long (500 letters at most).' using errcode = '22023'; end if;
  update mirror.inventory_given set returned_at = now(), returned_note = nullif(btrim(coalesce(p_note, '')), '') where id = x.id;
  update mirror.inventory_items set quantity = quantity + x.quantity where id = x.item_id;
  return jsonb_build_object('returned', true);
end $$;

-- what a person received: the person (all organizations) or a coordinator (their organization's gifts, everyday topic)
create or replace function public.mirror_received(p_individual uuid default null, p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  r jsonb;
  v_self boolean;
begin
  r := mirror.allowed(v_id, 'general', 'view', p_org, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := (r ->> 'role') = 'self';
  if not v_self and p_org is null then raise exception 'Choose your organization first.' using errcode = '22023'; end if;
  return jsonb_build_object('self', v_self,
    'can_give', not v_self and coalesce((mirror.allowed(v_id, 'general', 'edit', p_org, '_probe', null) ->> 'ok')::boolean, false),
    'received', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'organization', o.name, 'item', i.item, 'category', i.category,
        'size', i.size, 'quantity', g.quantity, 'given_on', g.given_on, 'note', g.note, 'returned', g.returned_at is not null,
        'returned_note', g.returned_note) order by g.given_on desc, g.created_at desc)
      from mirror.inventory_given g join mirror.inventory_items i on i.id = g.item_id join mirror.organizations o on o.id = g.organization_id
      where g.individual_id = v_id and (v_self or g.organization_id = p_org)), '[]'::jsonb));
end $$;

create or replace function public.mirror_my_export_received() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  if v is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  return public.mirror_received() -> 'received';
end $$;

revoke all on function mirror.inventory_item_json(mirror.inventory_items) from public, anon, authenticated;
grant execute on function mirror.inventory_item_json(mirror.inventory_items) to service_role;
revoke all on function public.mirror_inventory(uuid), public.mirror_inventory_save(jsonb), public.mirror_inventory_give(jsonb),
  public.mirror_inventory_return(uuid, text), public.mirror_received(uuid, uuid), public.mirror_my_export_received() from public, anon;
grant execute on function public.mirror_inventory(uuid), public.mirror_inventory_save(jsonb), public.mirror_inventory_give(jsonb),
  public.mirror_inventory_return(uuid, text), public.mirror_received(uuid, uuid), public.mirror_my_export_received() to authenticated, service_role;
