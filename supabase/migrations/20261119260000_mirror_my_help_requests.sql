-- The Human Mirror: "Things you asked for help with" on the person's My Mirror home (Phase 3 gap list item 8, Stephen 11/12/2026).
-- Answering "I'd like help with this" tells nobody yet (coordinator alerts come with Phase 8), so the person sees their own list.
-- Own Mirror only (mirror.me() refuses View as and anyone without a Mirror). Read-only; not logged as a look (it is the person's own).
-- No new table, so no table grants are needed (CLAUDE.md 10/30 rule applies to tables only).

create or replace function public.mirror_my_help_requests() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'set_key', s.key, 'kind', s.kind, 'reflection', s.reflection_key, 'dimension', s.dimension_key, 'set_title', s.title,
        'prompt', q.prompt, 'note', r.note, 'at', r.answered_at)
      order by r.answered_at desc)
    from mirror.assessment_responses r
    join mirror.assessments a on a.id = r.assessment_id
    join mirror.question_sets s on s.id = a.set_id
    join mirror.reflection_questions q on q.id = r.question_id
    where a.individual_id = v and r.superseded_at is null and r.state = 'needs_help'), '[]'::jsonb);
end $$;

revoke all on function public.mirror_my_help_requests() from public, anon;
grant execute on function public.mirror_my_help_requests() to authenticated, service_role;
