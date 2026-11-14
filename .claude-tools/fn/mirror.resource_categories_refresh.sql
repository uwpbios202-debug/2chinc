CREATE OR REPLACE FUNCTION mirror.resource_categories_refresh()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $function$
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
end $function$

