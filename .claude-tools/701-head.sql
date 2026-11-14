-- The Human Mirror Phase 11, T11.1: clothing, laundry and garment care (the Clothes paper, "Whole Person Support System"; Stephen 11/14/2026).
-- The short check (laundry access and how often, laundry cost, condition, needs, barriers) is in the Self-care questions (20261119700000).
-- This adds the person's clothing page, also used by a coordinator with them on the workspace person page:
--   * mirror.clothing_items: per category (13), how many they can use, how many need fixing, and how many they want. Only clothes they can
--     reach count. A suggested number comes from how often they can do laundry (the Clothes paper: what you need follows from how often you
--     can wash); the person chooses.
--   * mirror.clothing_profiles: sizes (private: an organization sees and changes them only when the person shares their sizes; a
--     coordinator may record that a person without a sign-in agreed), storage, laundry and mending skills, what they would like to learn.
--   * Every gap (want more than usable) and "no reliable place to do laundry" becomes a suggested need (mirror.need_suggestions_for,
--     branch 5); a need is then "obtained" and "verified" only when it fits and they accepted it (the existing needs lifecycle).
--   * A coordinator sees their organization's donated goods (T8.7) that match a gap, by category and, when sizes are shared, by size.
-- Everything is "general" (shown to organizations the person works with, like their other everyday answers) except sizes (their choice)
-- and the laundry cost question (Money). Every look and change goes through mirror.allowed (logged as before). Deleted with the person.
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026): service_role only; row security on; no anon or authenticated access.

create table mirror.clothing_items (
  individual_id uuid not null references mirror.individuals(id) on delete cascade,
  category text not null check (category in ('tops', 'bottoms', 'under', 'socks', 'sleep', 'outer', 'weather', 'shoes', 'boots', 'work', 'interview', 'athletic', 'special')),
  usable int not null default 0 check (usable between 0 and 999),
  needs_fixing int not null default 0 check (needs_fixing between 0 and 999),
  want int check (want is null or want between 0 and 999),
  note text check (note is null or length(note) <= 300),
  updated_at timestamptz not null default now(),
  updated_by_role text,
  primary key (individual_id, category)
);
create table mirror.clothing_profiles (
  individual_id uuid primary key references mirror.individuals(id) on delete cascade,
  sizes jsonb not null default '{}'::jsonb,
  sizes_shared boolean not null default false,
  storage jsonb not null default '[]'::jsonb,
  skills jsonb not null default '[]'::jsonb,
  wants_learn jsonb not null default '[]'::jsonb,
  note text check (note is null or length(note) <= 1000),
  updated_at timestamptz not null default now(),
  updated_by_role text
);
alter table mirror.clothing_items enable row level security;
alter table mirror.clothing_profiles enable row level security;
revoke all on mirror.clothing_items, mirror.clothing_profiles from public, anon, authenticated;
grant select, insert, update, delete on mirror.clothing_items, mirror.clothing_profiles to service_role;

create or replace function mirror.clothing_label(p text) returns text language sql immutable as $$
  select case p when 'tops' then 'everyday tops' when 'bottoms' then 'pants, jeans or skirts' when 'under' then 'underwear and bras'
    when 'socks' then 'socks' when 'sleep' then 'sleepwear' when 'outer' then 'a coat or jacket' when 'weather' then 'gloves, hats and thermals'
    when 'shoes' then 'everyday shoes' when 'boots' then 'boots' when 'work' then 'work clothes' when 'interview' then 'interview clothes'
    when 'athletic' then 'exercise clothes' when 'special' then 'cultural, religious, adaptive or maternity clothes' else p end;
$$;

-- Days between washes, from the Self-care answer "About how often can you do laundry?" (no answer: a week).
create or replace function mirror.laundry_days(v uuid) returns int language sql stable security definer set search_path = mirror, public as $$
  select coalesce((select case ca.value #>> '{}' when 'weekly' then 7 when 'two_weeks' then 14 when 'month' then 28 when 'rarely' then 35 end
                   from mirror.current_answers ca where ca.individual_id = v and ca.set_key = 'dimension_self_care' and ca.question_key = 'cl_laundry_often'
                   and ca.state = 'answered'), 7);
$$;

-- A suggested number per category (a starting point; the person chooses). Null: depends on their life (work, interviews, sports, special).
create or replace function mirror.clothing_suggested(p_category text, p_days int) returns int language sql immutable as $$
  select case p_category when 'tops' then least(p_days, 14) when 'bottoms' then greatest(3, ceil(least(p_days, 14) / 2.0)::int)
    when 'under' then least(p_days, 28) + 3 when 'socks' then least(p_days, 28) + 3 when 'sleep' then 2 when 'outer' then 1
    when 'weather' then 1 when 'shoes' then 1 when 'boots' then 1 end;
$$;

-- Which donated-goods category and which size fit a clothing category.
create or replace function mirror.clothing_inventory_category(p text) returns text language sql immutable as $$
  select case when p in ('outer') then 'coats' when p in ('shoes', 'boots') then 'shoes' else 'clothing' end;
$$;
create or replace function mirror.clothing_size_key(p text) returns text language sql immutable as $$
  select case p when 'tops' then 'top' when 'sleep' then 'top' when 'athletic' then 'top' when 'work' then 'top' when 'interview' then 'top'
    when 'bottoms' then 'bottom' when 'under' then 'under' when 'outer' then 'coat' when 'shoes' then 'shoe' when 'boots' then 'shoe' end;
$$;

create or replace function public.mirror_clothing_get(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); r jsonb; p mirror.clothing_profiles; v_self boolean; v_days int; v_org uuid;
        v_sizes_ok boolean; i mirror.individuals;
begin
  r := mirror.allowed(v, 'general', 'view', null, 'clothing_items', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := r ->> 'role' = 'self';
  v_org := nullif(r ->> 'organization_id', '')::uuid;
  select * into p from mirror.clothing_profiles where individual_id = v;
  select * into i from mirror.individuals where id = v;
  v_sizes_ok := v_self or coalesce(p.sizes_shared, false);
  v_days := mirror.laundry_days(v);
  return jsonb_build_object(
    'role', r ->> 'role', 'self', v_self, 'can_edit', mirror.may(v, 'general', 'edit'), 'has_signin', i.auth_email is not null,
    'laundry_days', v_days,
    'laundry', (select jsonb_object_agg(ca.question_key, ca.value) from mirror.current_answers ca where ca.individual_id = v
                and ca.set_key = 'dimension_self_care' and ca.question_key in ('cl_laundry_access', 'cl_laundry_often', 'cl_condition', 'cl_barriers', 'cl_needs')
                and ca.state = 'answered'),
    'items', (select jsonb_agg(jsonb_build_object('category', k.c, 'label', mirror.clothing_label(k.c), 'suggested', mirror.clothing_suggested(k.c, v_days),
                'usable', c.usable, 'needs_fixing', c.needs_fixing, 'want', c.want, 'note', c.note, 'updated_at', c.updated_at, 'by', c.updated_by_role) order by k.n)
              from unnest(array['tops', 'bottoms', 'under', 'socks', 'sleep', 'outer', 'weather', 'shoes', 'boots', 'work', 'interview', 'athletic', 'special'])
                   with ordinality k(c, n)
              left join mirror.clothing_items c on c.individual_id = v and c.category = k.c),
    'profile', jsonb_build_object('sizes', case when v_sizes_ok then coalesce(p.sizes, '{}'::jsonb) end, 'sizes_shared', coalesce(p.sizes_shared, false),
                'storage', coalesce(p.storage, '[]'::jsonb), 'skills', coalesce(p.skills, '[]'::jsonb), 'wants_learn', coalesce(p.wants_learn, '[]'::jsonb),
                'note', p.note, 'updated_at', p.updated_at, 'by', p.updated_by_role),
    -- a coordinator: their organization's donated goods that fit a gap (by category; by size when the person shares sizes)
    'matches', case when v_self or v_org is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('for', c.category, 'for_label', mirror.clothing_label(c.category), 'item', it.item, 'size', it.size, 'fits', it.fits,
               'condition', it.condition, 'season', it.season, 'quantity', it.quantity) order by c.category, it.item)
      from mirror.clothing_items c
      join mirror.inventory_items it on it.organization_id = v_org and it.active and it.quantity > 0
        and it.category = mirror.clothing_inventory_category(c.category)
        and (it.size is null or lower(btrim(it.size)) in ('one size', 'any', '')
             or (v_sizes_ok and mirror.clothing_size_key(c.category) is not null
                 and lower(btrim(it.size)) = lower(btrim(coalesce(p.sizes ->> mirror.clothing_size_key(c.category), '')))))
      where c.individual_id = v and c.want is not null and c.want > c.usable), '[]'::jsonb) end);
end $$;

create or replace function public.mirror_clothing_save(p jsonb, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); r jsonb; x jsonb; v_role text; cur mirror.clothing_profiles; v_self boolean;
        v_sizes jsonb; v_shared boolean; i mirror.individuals; k text;
begin
  r := mirror.allowed(v, 'general', 'edit', null, 'clothing_items', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_role := r ->> 'role'; v_self := v_role = 'self';
  select * into i from mirror.individuals where id = v;
  for x in select * from jsonb_array_elements(coalesce(p -> 'items', '[]'::jsonb)) loop
    insert into mirror.clothing_items (individual_id, category, usable, needs_fixing, want, note, updated_at, updated_by_role)
    values (v, x ->> 'category', coalesce(nullif(x ->> 'usable', '')::int, 0), coalesce(nullif(x ->> 'needs_fixing', '')::int, 0),
            nullif(x ->> 'want', '')::int, nullif(left(btrim(coalesce(x ->> 'note', '')), 300), ''), now(), v_role)
    on conflict (individual_id, category) do update set usable = excluded.usable, needs_fixing = excluded.needs_fixing, want = excluded.want,
      note = excluded.note, updated_at = now(), updated_by_role = v_role
    where (mirror.clothing_items.usable, mirror.clothing_items.needs_fixing, mirror.clothing_items.want, mirror.clothing_items.note)
          is distinct from (excluded.usable, excluded.needs_fixing, excluded.want, excluded.note);
  end loop;
  select * into cur from mirror.clothing_profiles where individual_id = v;
  v_shared := coalesce(cur.sizes_shared, false);
  if v_self and p ? 'sizes_shared' then v_shared := coalesce((p ->> 'sizes_shared')::boolean, false); end if;
  if not v_self and i.auth_email is null and coalesce((p ->> 'sizes_agreed')::boolean, false) then v_shared := true; end if;  -- no sign-in: recorded agreement
  v_sizes := coalesce(cur.sizes, '{}'::jsonb);
  if p ? 'sizes' and (v_self or v_shared) then
    v_sizes := '{}'::jsonb;
    for k in select * from jsonb_object_keys(p -> 'sizes') loop
      if k = any (array['top', 'bottom', 'dress', 'under', 'bra', 'shoe', 'coat']) and nullif(btrim(p -> 'sizes' ->> k), '') is not null then
        v_sizes := v_sizes || jsonb_build_object(k, left(btrim(p -> 'sizes' ->> k), 40));
      end if;
    end loop;
  end if;
  insert into mirror.clothing_profiles (individual_id, sizes, sizes_shared, storage, skills, wants_learn, note, updated_at, updated_by_role)
  values (v, v_sizes, v_shared, coalesce(p -> 'storage', '[]'::jsonb), coalesce(p -> 'skills', '[]'::jsonb), coalesce(p -> 'wants_learn', '[]'::jsonb),
          nullif(left(btrim(coalesce(p ->> 'note', '')), 1000), ''), now(), v_role)
  on conflict (individual_id) do update set sizes = excluded.sizes, sizes_shared = excluded.sizes_shared, storage = excluded.storage,
    skills = excluded.skills, wants_learn = excluded.wants_learn, note = excluded.note, updated_at = now(), updated_by_role = v_role;
  return public.mirror_clothing_get(p_individual);
end $$;
