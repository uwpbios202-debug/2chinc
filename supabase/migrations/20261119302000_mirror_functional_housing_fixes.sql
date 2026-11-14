-- The Human Mirror Phase 5, fixes to 20261119300000 (that file went live early, by another session's push on 11/13; it is left as applied).
-- 1. mirror_housing_get: for a helper, each private topic the person never shared was checked with mirror.allowed(), which logs a
--    'refused' row in the person's "who looked" record on every page load. Now a quiet probe (mirror.may) comes first; the real check,
--    which logs the look, runs only for topics that are shared. What is returned does not change.
-- 2. mirror_my_export_living: operator order left preferred_option_ids (internal ids) in the download; now removed, keys kept.
-- No tables, no grants change (create or replace keeps the existing grants).

create or replace function public.mirror_housing_get(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); r jsonb; v_ok text[] := array['general']; c text; p mirror.housing_profiles;
begin
  r := mirror.allowed(v, 'general', 'view', null, 'housing_profiles', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  -- private parts: a quiet probe first (no refusal logged for topics never shared), then the real check, which logs the look
  foreach c in array array['health', 'mental_health', 'safety', 'legal'] loop
    if mirror.may(v, c, 'view') and (mirror.allowed(v, c, 'view', null, 'housing_profiles', c) ->> 'ok')::boolean then v_ok := v_ok || c; end if;
  end loop;
  select * into p from mirror.housing_profiles where individual_id = v;
  return jsonb_build_object(
    'role', r ->> 'role',
    'can_edit', mirror.may(v, 'general', 'edit'),
    'can_edit_health', mirror.may(v, 'health', 'edit'),
    'can_edit_legal', mirror.may(v, 'legal', 'edit'),
    'can_flag', r ->> 'role' <> 'self' and mirror.may(v, 'general', 'edit'),
    'sees', to_jsonb(v_ok),
    'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'key', o.key, 'title', o.title, 'summary', o.summary) order by o.sort) from mirror.housing_options o where o.active),
    'profile', case when p.individual_id is null then null else jsonb_build_object(
      'current_arrangement', case when mirror.housing_arrangement_topic(p.current_arrangement) = any (v_ok) then p.current_arrangement end,
      'current_private', p.current_arrangement is not null and not (mirror.housing_arrangement_topic(p.current_arrangement) = any (v_ok)),
      'current_note', p.current_note,
      'preferred', coalesce((select jsonb_agg(o.key order by o.sort) from mirror.housing_options o where o.id = any (p.preferred_option_ids)), '[]'::jsonb),
      'barriers', jsonb_build_object('keys', mirror.housing_keys_visible(p.barriers, v_ok), 'note', p.barriers -> 'note',
        'hidden', jsonb_array_length(coalesce(p.barriers -> 'keys', '[]'::jsonb)) - jsonb_array_length(mirror.housing_keys_visible(p.barriers, v_ok))),
      'accessibility', case when 'health' = any (v_ok) then p.accessibility_needs else jsonb_build_object('private', true) end,
      'professional_review_needed', p.professional_review_needed, 'review_note', p.review_note, 'review_by', p.review_by_role, 'review_at', p.review_at,
      'updated_at', p.updated_at, 'updated_by', p.updated_by_role) end,
    'history', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'from_on', h.from_on, 'to_on', h.to_on, 'arrangement', h.arrangement,
        'city', h.city, 'note', h.note, 'private', h.sensitive_category, 'by', h.created_by_role) order by h.from_on desc nulls last, h.created_at desc)
      from mirror.housing_history h where h.individual_id = v
        and mirror.housing_arrangement_topic(h.arrangement) = any (v_ok) and (h.sensitive_category is null or h.sensitive_category = any (v_ok))), '[]'::jsonb),
    'history_hidden', (select count(*) from mirror.housing_history h where h.individual_id = v
        and not (mirror.housing_arrangement_topic(h.arrangement) = any (v_ok) and (h.sensitive_category is null or h.sensitive_category = any (v_ok)))));
end $$;

create or replace function public.mirror_my_export_living() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  perform mirror.audit(v, null, 'self', 'export', 'general', 'functional_housing', null);
  return jsonb_build_object(
    'everyday_activities', coalesce((select jsonb_agg(mirror.fa_json(f.id) order by f.started_at) from mirror.functional_assessments f where f.individual_id = v), '[]'::jsonb),
    'housing_profile', (select (to_jsonb(h) - 'individual_id' - 'preferred_option_ids') || jsonb_build_object('preferred', coalesce((select jsonb_agg(o.key order by o.sort)
        from mirror.housing_options o where o.id = any (h.preferred_option_ids)), '[]'::jsonb))
      from mirror.housing_profiles h where h.individual_id = v),
    'housing_history', coalesce((select jsonb_agg(to_jsonb(h) - 'individual_id' order by h.from_on nulls last, h.created_at)
      from mirror.housing_history h where h.individual_id = v), '[]'::jsonb));
end $$;
