-- Human Mirror Phase 5: "the latest check-in" picked the same way everywhere, with no ties.
-- mirror_fa_get (the review it shows, the last finished check-in, history order) and mirror_fa_review (the check-in it marks)
-- ordered by started_at / completed_at alone. Two check-ins started in one transaction share now(), so the review could mark one
-- row while the page read another (found 11/13/2026: t5 check step 6 flipped to f with no other change). In real use two
-- check-ins never start in one transaction; this makes the choice deterministic: newest first, then id. Bodies otherwise as in 300000.

create or replace function public.mirror_fa_get(p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); r jsonb; v_self boolean; v_open uuid; v_last uuid;
begin
  r := mirror.allowed(v, 'health', 'view', null, 'functional_assessments', null);
  if not (r ->> 'ok')::boolean then raise exception '%', r ->> 'reason' using errcode = '42501'; end if;
  v_self := r ->> 'role' = 'self';
  select id into v_open from mirror.functional_assessments where individual_id = v and completed_at is null and is_self_report = v_self;
  select id into v_last from mirror.functional_assessments where individual_id = v and completed_at is not null order by completed_at desc, started_at desc, id desc limit 1;
  return jsonb_build_object(
    'role', r ->> 'role',
    'can_edit', mirror.may(v, 'health', 'edit'),
    'can_flag', not v_self and mirror.may(v, 'health', 'edit'),
    'open', case when v_open is not null then mirror.fa_json(v_open) end,
    'last', case when v_last is not null then mirror.fa_json(v_last) end,
    'review', (select jsonb_build_object('needed', f.professional_review_needed, 'note', f.review_note, 'by', f.review_by_role, 'at', f.review_at)
      from mirror.functional_assessments f where f.individual_id = v order by f.started_at desc, f.id desc limit 1),
    'history', coalesce((select jsonb_agg(mirror.fa_json(f.id) order by f.started_at desc, f.id desc) from mirror.functional_assessments f
      where f.individual_id = v and f.completed_at is not null), '[]'::jsonb));
end $$;

-- A helper marks (or unmarks) "professional review needed" on the person's latest check-in. Never the person, never automatic.
create or replace function public.mirror_fa_review(p_needed boolean, p_note text default null, p_individual uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.target_individual(p_individual); g jsonb; v_fa uuid;
begin
  g := mirror.require(v, 'health', 'edit', null, 'functional_assessments', 'review');
  if g ->> 'role' = 'self' then raise exception 'Only someone helping you can mark this.' using errcode = '42501'; end if;
  select id into v_fa from mirror.functional_assessments where individual_id = v order by started_at desc, id desc limit 1;
  if v_fa is null then raise exception 'There is no check-in to mark yet.' using errcode = 'P0002'; end if;
  update mirror.functional_assessments set professional_review_needed = coalesce(p_needed, false),
    review_note = case when coalesce(p_needed, false) then nullif(btrim(coalesce(p_note, '')), '') end,
    review_by_role = g ->> 'role', review_at = now(), updated_at = now() where id = v_fa;
  return mirror.fa_json(v_fa);
end $$;
