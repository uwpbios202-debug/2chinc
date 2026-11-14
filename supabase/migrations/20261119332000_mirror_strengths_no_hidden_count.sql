-- The Human Mirror T6.2 follow-up (Stephen 11/13/2026 confirmed D-29 point 5): nobody but the person gets a count of hidden strengths.
-- A coordinator could otherwise tell that private strengths exist. mirror_strengths is unchanged apart from dropping the 'hidden' key.
-- No table is created, so no new grants; the function keeps its grants (create or replace).

create or replace function public.mirror_strengths(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  v_ok text[] := '{}';
  v_add text[] := '{}';
  c text;
  r jsonb;
begin
  r := mirror.allowed(v_id, 'general', 'view', null, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  for c in select distinct s.category from mirror.strengths s where s.individual_id = v_id loop
    if mirror.may(v_id, c, 'view') then
      v_ok := v_ok || c;
      perform mirror.allowed(v_id, c, 'view', null, 'strengths', null);
    end if;
  end loop;
  for c in select unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) loop
    if mirror.may(v_id, c, 'edit') then v_add := v_add || c; end if;
  end loop;
  return jsonb_build_object(
    'self', (r ->> 'role') = 'self',
    'can_add', to_jsonb(v_add),
    'strengths', coalesce((select jsonb_agg(mirror.strength_json(s) order by
        array_position(array['skill', 'talent', 'experience', 'credential', 'language', 'interest', 'relationship'], s.kind), lower(s.title))
      from mirror.strengths s where s.individual_id = v_id and s.category = any (v_ok)), '[]'::jsonb));
end $$;
