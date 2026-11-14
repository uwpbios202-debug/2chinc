-- The Human Mirror Phase N, handoff step 20, TN.3 part A: the resource directory by life area (closes NAVIGATOR.md gap N3, with part B).
-- Until now Find help (https://2ndchinc.org/staff/resources/ and the Navigator's Resources tab) sorts only by the 20 housing help types.
-- T7.1 already links every program to the Mirror's 15 life areas (mirror.resource_categories): 'rule' links follow the program's help
-- types after every import, 'office' links are set by hand and survive every refresh. This adds:
--   * chpms_life_areas(): the 15 areas and each program's areas, for whoever may read the directory (same check as chpms_directory);
--   * chpms_program_areas_save(program, areas): office staff tag a program with life areas (office links). Areas that come from the
--     program's help types stay (they follow the help types); only office links are added or removed here.
-- chpms_directory itself is not changed. No new table.

create or replace function public.chpms_life_areas() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_role text := chpms_require(false);
begin
  return jsonb_build_object(
    'areas', (select jsonb_agg(jsonb_build_object('key', d.key, 'title', d.title) order by d.n) from mirror.dimensions d),
    'links', coalesce((select jsonb_object_agg(x.pid, x.keys) from (
        select c.chpms_program_id as pid, jsonb_agg(distinct c.dimension_key) as keys from mirror.resource_categories c group by c.chpms_program_id) x), '{}'::jsonb),
    'by_rule', coalesce((select jsonb_object_agg(x.pid, x.keys) from (
        select c.chpms_program_id as pid, jsonb_agg(distinct c.dimension_key) as keys from mirror.resource_categories c where c.source = 'rule' group by c.chpms_program_id) x), '{}'::jsonb),
    'can_tag', v_role = 'staff' and not autopay_view_as_session());
end $$;

create or replace function public.chpms_program_areas_save(p_program text, p_areas text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_role text := chpms_require(true); v_bad text;
begin
  if v_role <> 'staff' then raise exception 'Office staff only.' using errcode = '42501'; end if;
  if not exists (select 1 from chpms_programs where program_id = p_program) then raise exception 'Not found.' using errcode = '42501'; end if;
  select x into v_bad from unnest(coalesce(p_areas, '{}')) x where not exists (select 1 from mirror.dimensions d where d.key = x) limit 1;
  if v_bad is not null then raise exception 'Unknown life area: %', v_bad using errcode = '22023'; end if;
  delete from mirror.resource_categories c where c.chpms_program_id = p_program and c.source = 'office' and not (c.dimension_key = any (coalesce(p_areas, '{}')));
  insert into mirror.resource_categories (chpms_program_id, dimension_key, expense_category_key, source, note, added_by)
  select p_program, x, null, 'office', 'Tagged by the office on the directory page', lower(auth.email())
    from (select distinct x from unnest(coalesce(p_areas, '{}')) x) a
   where not exists (select 1 from mirror.resource_categories c where c.chpms_program_id = p_program and c.dimension_key = a.x);
  return chpms_life_areas();
end $$;

revoke all on function public.chpms_life_areas(), public.chpms_program_areas_save(text, text[]) from public, anon;
grant execute on function public.chpms_life_areas(), public.chpms_program_areas_save(text, text[]) to authenticated, service_role;
