-- The Human Mirror T7.1: link the CHPMS housing resource directory to the Mirror (Phase 7, step 4 of the handoff).
-- "resource_categories (program -> life area, expense category). Needed by T7.2 and TN.3."
--
-- Rules
--   * mirror.resource_categories says which areas of life (mirror.dimensions) a CHPMS program helps with, and, where it can lower a
--     Daily Number cost, which cost category (mirror.expense_categories). One row per program + area + cost category.
--   * Rows come from two places: 'rule' rows are derived from the program's CHPMS help types (public.chpms_program_assist, provided)
--     through the small map mirror.resource_assist_map; 'office' rows are added by hand later (TN.3 tags non-housing programs).
--     A refresh rebuilds only the 'rule' rows, so office rows are never lost.
--   * The CHPMS import deletes and re-inserts help types; a statement trigger on chpms_program_assist runs the refresh, so the links
--     follow the directory without a separate step. All 20 help types the CHPMS check constraint allows are in the map; a type
--     added there later without a map row simply adds no link (it never blocks the import).
--   * The directory itself is not changed and no browser gets access here: these tables are service_role only (D-03 deny-all).
--     T7.2 reads them through the gated suggestion functions.
-- New tables carry explicit grants (CLAUDE.md, 10/30/2026 rule): service_role only, no TRUNCATE; authenticated and anon none.

-- ---------------------------------------------------------------- the map: CHPMS help type -> area of life (+ cost it can lower)
create table mirror.resource_assist_map (
  assist_category text not null check (length(btrim(assist_category)) between 1 and 100),
  dimension_key text not null references mirror.dimensions(key) on delete restrict,
  expense_category_key text references mirror.expense_categories(key) on delete restrict,
  primary key (assist_category, dimension_key)
);

insert into mirror.resource_assist_map (assist_category, dimension_key, expense_category_key) values
  ('Emergency rental assistance',    'housing',     'housing'),
  ('Monthly rental assistance',      'housing',     'housing'),
  ('First month''s rent',            'housing',     'housing'),
  ('Last month''s rent',             'housing',     'housing'),
  ('Security deposit assistance',    'housing',     'housing'),
  ('Housing vouchers',               'housing',     'housing'),
  ('Moving expenses',                'housing',     'housing'),
  ('Rapid rehousing',                'housing',     'housing'),
  ('Supportive housing',             'housing',     'housing'),
  ('Transitional housing',           'housing',     'housing'),
  ('Permanent housing',              'housing',     'housing'),
  ('Eviction prevention',            'housing',     'housing'),
  ('Eviction prevention',            'identity_legal', null),
  ('Landlord mediation',             'housing',     null),
  ('Housing navigation',             'housing',     null),
  ('Other housing support',          'housing',     null),
  ('Utility assistance',             'housing',     'utilities'),
  ('Furniture and household items',  'housing',     'household'),
  ('Case management',                'life_skills', null),
  ('Benefits enrollment',            'finances',    null),
  ('Financial counseling',           'finances',    'financial');

-- ---------------------------------------------------------------- the links
create table mirror.resource_categories (
  id uuid primary key default gen_random_uuid(),
  chpms_program_id text not null references public.chpms_programs(program_id) on delete cascade,
  dimension_key text not null references mirror.dimensions(key) on delete restrict,
  expense_category_key text references mirror.expense_categories(key) on delete restrict,
  source text not null check (source in ('rule', 'office')),
  note text check (note is null or length(note) <= 500),
  added_by text,                                   -- null for 'rule' rows
  created_at timestamptz not null default now(),
  constraint resource_categories_one unique nulls not distinct (chpms_program_id, dimension_key, expense_category_key)
);
create index resource_categories_area on mirror.resource_categories (dimension_key, expense_category_key);
create index resource_categories_program on mirror.resource_categories (chpms_program_id);

create or replace function mirror.resource_no_truncate() returns trigger language plpgsql set search_path = mirror as $$
begin
  raise exception 'Resource links are never emptied in bulk.' using errcode = '42501';
end $$;
create trigger resource_categories_no_truncate before truncate on mirror.resource_categories
  for each statement execute function mirror.resource_no_truncate();

alter table mirror.resource_assist_map enable row level security;
alter table mirror.resource_categories enable row level security;
revoke all on mirror.resource_assist_map, mirror.resource_categories from public, anon, authenticated;
grant select, insert, update, delete on mirror.resource_assist_map, mirror.resource_categories to service_role;

-- ---------------------------------------------------------------- refresh: rebuild the 'rule' rows from the help types
-- An office row that matches a rule row is kept as the office row (the unique key keeps one).
create or replace function mirror.resource_categories_refresh() returns integer
language plpgsql security definer set search_path = mirror, public as $$
declare n int;
begin
  delete from mirror.resource_categories rc
   where rc.source = 'rule'
     and not exists (
       select 1 from public.chpms_program_assist a
         join mirror.resource_assist_map m on m.assist_category = a.category
        where a.provided and a.program_id = rc.chpms_program_id
          and m.dimension_key = rc.dimension_key
          and m.expense_category_key is not distinct from rc.expense_category_key);
  insert into mirror.resource_categories (chpms_program_id, dimension_key, expense_category_key, source)
  select distinct a.program_id, m.dimension_key, m.expense_category_key, 'rule'
    from public.chpms_program_assist a
    join mirror.resource_assist_map m on m.assist_category = a.category
    join public.chpms_programs p on p.program_id = a.program_id
   where a.provided
  on conflict on constraint resource_categories_one do nothing;
  select count(*) into n from mirror.resource_categories;
  return n;
end $$;
revoke all on function mirror.resource_categories_refresh() from public, anon, authenticated;
grant execute on function mirror.resource_categories_refresh() to service_role;

create or replace function mirror.resource_categories_follow() returns trigger
language plpgsql security definer set search_path = mirror, public as $$
begin
  perform mirror.resource_categories_refresh();
  return null;
end $$;
revoke all on function mirror.resource_categories_follow() from public, anon, authenticated;

create trigger chpms_program_assist_mirror_links
  after insert or update or delete on public.chpms_program_assist
  for each statement execute function mirror.resource_categories_follow();

-- ---------------------------------------------------------------- reader for T7.2 / TN.3 (internal, not for browsers)
-- The areas and cost categories of one program, as jsonb: [{"area": "housing", "cost": "housing"}, ...]
create or replace function mirror.program_areas(p_program text) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('area', rc.dimension_key, 'cost', rc.expense_category_key)
                            order by d.n, rc.expense_category_key nulls last), '[]'::jsonb)
    from mirror.resource_categories rc join mirror.dimensions d on d.key = rc.dimension_key
   where rc.chpms_program_id = p_program;
$$;
revoke all on function mirror.program_areas(text) from public, anon, authenticated;
grant execute on function mirror.program_areas(text) to service_role;

-- ---------------------------------------------------------------- first fill
select mirror.resource_categories_refresh();
