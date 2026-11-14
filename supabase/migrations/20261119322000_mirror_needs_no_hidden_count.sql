-- The Human Mirror T6.1: no "hidden" count (Stephen 11/13/2026, D-29 point 5, confirmed: "No 'hidden' count for anyone but the
-- person"). The person always sees all of their own needs, so the count is dropped from mirror_needs_list altogether. An
-- organization no longer learns that private needs exist; it sees only the needs in topics it may see. Same as strengths and the plan.
-- Only the final return changes; everything else is copied unchanged from 20261119320000.

create or replace function public.mirror_needs_list(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid := mirror.target_individual(p_individual);
  v_ok text[] := '{}';
  v_add text[] := '{}';
  c text;
  r jsonb;
  v_self boolean := false;
begin
  -- the caller must at least be able to see everyday topics (the person always can); the reason comes back in plain words
  r := mirror.allowed(v_id, 'general', 'view', null, '_probe', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := (r ->> 'role') = 'self';
  -- topics with needs: a quiet probe decides; only real looks at private topics are logged (no "tried to open" on every list)
  for c in select distinct n.category from mirror.needs n where n.individual_id = v_id loop
    if mirror.may(v_id, c, 'view') then
      v_ok := v_ok || c;
      perform mirror.allowed(v_id, c, 'view', null, 'needs', null);
    end if;
  end loop;
  -- which topics the caller may add a need in (quiet probe, not logged)
  for c in select unnest(array['general', 'health', 'mental_health', 'safety', 'legal', 'financial']) loop
    if mirror.may(v_id, c, 'edit') then v_add := v_add || c; end if;
  end loop;
  return jsonb_build_object(
    'self', v_self,
    'can_add', to_jsonb(v_add),
    'needs', coalesce((select jsonb_agg(mirror.need_json(n) order by
        case n.status when 'verified' then 2 when 'no_longer_needed' then 2 when 'obtained' then 1 else 0 end,
        case n.urgency when 'urgent' then 0 when 'soon' then 1 else 2 end, n.updated_at desc)
      from mirror.needs n where n.individual_id = v_id and n.category = any (v_ok)), '[]'::jsonb));
end $$;

revoke all on function public.mirror_needs_list(uuid) from public, anon;
grant execute on function public.mirror_needs_list(uuid) to authenticated, service_role;
