-- The Human Mirror Phase 8, T8.2: the one-person overview (Stephen 11/13/2026 "go" after T8.1; handoff step 9). Database part.
--
-- 1. T6.1 report finding 5: a coordinator's changes to a need's words, details, area or urgency now go into that need's own history
--    (a need_events row with the status unchanged), so the person sees on the need itself what someone else changed, and what the
--    words were before. The person's own edits stay quiet (their need, their words). Status changes were already recorded.
-- 2. T6.1 report finding 6: the Needs and Assets reflections (questions) and the My needs / My strengths lists (inventories) were easy to
--    confuse. The two reflections' introductions now say where the list is. (The list pages say where the questions are.)
-- No new tables. The rest of T8.2 is in the pages (overview sections, safety banner P2-06, milestone confirm button), using the
-- existing gated functions (mirror_needs_list, mirror_strengths, mirror_plan, mirror_progress, mirror_need_status, mirror_milestone_confirm).

create or replace function public.mirror_need_save(p_id uuid, p_dimension text, p_title text, p_detail text default null,
  p_urgency text default 'soon', p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_id uuid;
  n mirror.needs;
  o mirror.needs;
  g jsonb;
  v_cat text;
  v_title text := btrim(coalesce(p_title, ''));
  v_detail text := nullif(btrim(coalesce(p_detail, '')), '');
  v_what text[] := '{}';
  v_note text;
begin
  if not exists (select 1 from mirror.dimensions d where d.key = p_dimension) then
    raise exception 'Choose an area of life for this need.' using errcode = '22023';
  end if;
  if length(v_title) = 0 then raise exception 'Say in a few words what you need.' using errcode = '22023'; end if;
  if length(v_title) > 200 then raise exception 'Please keep the need to 200 letters; add more in the details.' using errcode = '22023'; end if;
  if length(coalesce(v_detail, '')) > 2000 then raise exception 'The details are too long (2,000 letters at most).' using errcode = '22023'; end if;
  if coalesce(p_urgency, '') not in ('urgent', 'soon', 'later') then raise exception 'Unknown urgency.' using errcode = '22023'; end if;
  v_cat := mirror.dimension_category(p_dimension);

  if p_id is null then
    v_id := mirror.target_individual(p_individual);
    g := mirror.require(v_id, v_cat, 'edit', null, 'needs', null);
    insert into mirror.needs (individual_id, dimension_key, category, title, detail, urgency, identified_by, identified_by_role)
    values (v_id, p_dimension, v_cat, v_title, v_detail, p_urgency, lower(auth.email()), g ->> 'role')
    returning * into n;
    insert into mirror.need_events (need_id, by_email, by_role, from_status, to_status, note)
    values (n.id, lower(auth.email()), g ->> 'role', null, 'identified', null);
    return mirror.need_json(n);
  end if;

  select * into n from mirror.needs where id = p_id;
  if not found then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
  if p_individual is not null and p_individual <> n.individual_id then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(n.individual_id, n.category, 'edit', null, 'needs', n.id::text);
  if v_cat <> n.category then perform mirror.require(n.individual_id, v_cat, 'edit', null, 'needs', n.id::text); end if;
  if (n.dimension_key, n.title, n.detail, n.urgency) is distinct from (p_dimension, v_title, v_detail, p_urgency) then
    o := n;
    update mirror.needs set dimension_key = p_dimension, category = v_cat, title = v_title, detail = v_detail, urgency = p_urgency
     where id = n.id returning * into n;
    -- finding 5: someone else's change is written into the need's own history, with what it was before
    if (g ->> 'role') <> 'self' then
      if o.title is distinct from n.title then v_what := v_what || ('the words (they were: "' || left(o.title, 300) || '")'); end if;
      if o.detail is distinct from n.detail then v_what := v_what || 'the details'::text; end if;
      if o.dimension_key is distinct from n.dimension_key then
        v_what := v_what || ('the part of life (it was: ' || (select d.title from mirror.dimensions d where d.key = o.dimension_key) || ')'); end if;
      if o.urgency is distinct from n.urgency then v_what := v_what || ('how soon (it was: ' || o.urgency || ')'); end if;
      v_note := left('Changed ' || array_to_string(v_what, ', '), 1000);
      insert into mirror.need_events (need_id, by_email, by_role, from_status, to_status, note)
      values (n.id, lower(auth.email()), g ->> 'role', n.status, n.status, v_note);
    end if;
  end if;
  return mirror.need_json(n);
end $$;

revoke all on function public.mirror_need_save(uuid, text, text, text, text, uuid) from public, anon;
grant execute on function public.mirror_need_save(uuid, text, text, text, text, uuid) to authenticated, service_role;

-- finding 6: the reflections say where the lists are
update mirror.question_sets
   set intro = 'What stands between today and the life I want, and what would help most. The bridge from today to tomorrow. '
            || 'These are questions to think it through; your list of needs, one at a time, is "My needs list" on My Mirror.'
 where key = 'reflection_needs'
   and intro = 'What stands between today and the life I want, and what would help most. The bridge from today to tomorrow.';
update mirror.question_sets
   set intro = 'What I''m good at, what I know, what people appreciate about me, and the strengths that helped me get through hard times. '
            || 'These are questions to think it through; your list of strengths is "My strengths list" on My Mirror.'
 where key = 'reflection_assets'
   and intro = 'What I''m good at, what I know, what people appreciate about me, and the strengths that helped me get through hard times.';
