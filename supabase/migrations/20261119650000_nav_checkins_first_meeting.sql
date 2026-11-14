-- The Human Mirror Phase N, handoff step 22 (the last Phase N step): TN.5 check-ins from the first meeting (closes NAVIGATOR.md gap N5).
-- Until now a Navigator's check-in plan starts at move-in. Now:
--   * The plan can start at the first meeting: once the housing consent is signed, on any open file (not closed), the Navigator (or the
--     office) sets how often and the next date (nav_checkin_plan_save, unchanged); nav_checkin_schedule now works before move-in too.
--     Recording a check-in before move-in puts the next one on the calendar (trigger; nav_followup_save, which also starts retention
--     pay, is NOT changed). At move-in the open check-in simply continues (nav_referral_step already reschedules it) and the 90-day and
--     12-month reviews are added as before. Closing a file before move-in clears its open check-in.
--   * Check-ins follow the Mirror plan: nav_followups.mirror_need_id links a check-in to one of the person's Mirror needs. The link is made
--     in the Mirror (https://2ndchinc.org/mirror/workspace/checkins/), where the Mirror's own gate applies (authenticator code, D-13, and
--     only needs in topics the person shares). The Navigator portal shows only that a check-in is linked, never the need itself.
--   * Reminder emails are unchanged: still only for people who have moved in (nav_followup_reminders). Reminding before move-in would
--     send email in new cases, so it waits for Stephen's OK.
-- History stays as it was: no existing check-in is changed.

alter table public.nav_followups add column if not exists mirror_need_id uuid references mirror.needs(id) on delete set null;

-- Schedules the next "checkin" for any open file with a signed housing consent (was: moved in only).
create or replace function public.nav_checkin_schedule(p_referral uuid, p_next date, p_from date) returns void
language plpgsql security definer set search_path = public as $$
declare r nav_referrals; v_due date;
begin
  select * into r from nav_referrals where id = p_referral;
  if not found or r.status = 'closed' or r.consent_on is null or r.consent_withdrawn_on is not null then return; end if;
  v_due := coalesce(p_next, (p_from + nav_checkin_interval(coalesce(r.checkin_every, 'weekly')))::date);
  if v_due is null then
    delete from nav_followups where referral_id = p_referral and mark = 'checkin' and done_on is null;
  elsif exists (select 1 from nav_followups where referral_id = p_referral and mark = 'checkin' and done_on is null) then
    update nav_followups set due_on = v_due, reminded_at = null where referral_id = p_referral and mark = 'checkin' and done_on is null;
  else
    insert into nav_followups (referral_id, mark, due_on) values (p_referral, 'checkin', v_due);
  end if;
  update nav_referrals set next_checkin_on = v_due where id = p_referral;
end $$;

-- Before move-in, recording a check-in schedules the next one (after move-in nav_followup_save already does).
create or replace function public.nav_checkin_next_before_housing() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  if new.mark = 'checkin' and old.done_on is null and new.done_on is not null and coalesce(new.outcome, '') <> 'left' then
    select status into v_status from nav_referrals where id = new.referral_id;
    if v_status is not null and v_status not in ('moved_in', 'closed') then
      perform nav_checkin_schedule(new.referral_id, null, (now() at time zone 'America/Chicago')::date);
    end if;
  end if;
  return new;
end $$;
create trigger nav_followups_next_before_housing after update of done_on on public.nav_followups
  for each row execute function public.nav_checkin_next_before_housing();

-- Closing a file before move-in clears its open check-in (housed files are left as they were).
create or replace function public.nav_checkin_clear_on_close() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'closed' and old.status is distinct from 'closed' and old.status <> 'moved_in' then
    delete from nav_followups where referral_id = new.id and mark = 'checkin' and done_on is null;
    new.next_checkin_on := null;
  end if;
  return new;
end $$;
create trigger nav_referrals_checkin_clear_on_close before update of status on public.nav_referrals
  for each row execute function public.nav_checkin_clear_on_close();

-- The Mirror side: a Navigator organization's check-ins with this person, and the needs it may link them to.
create or replace function public.mirror_nav_checkins(p_individual uuid, p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare g jsonb; v_org uuid;
begin
  g := mirror.require(p_individual, 'general', 'view', p_org, 'nav_followups', null);
  v_org := nullif(g ->> 'organization_id', '')::uuid;
  if v_org is null or not exists (select 1 from mirror.organizations o where o.id = v_org and o.kind = 'navigator') then
    raise exception 'Check-ins are kept by a Housing Navigator''s organization.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'checkins', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'mark', f.mark, 'due_on', f.due_on, 'done_on', f.done_on, 'outcome', f.outcome,
        'note', f.note, 'need_id', case when n.id is not null and mirror.may(p_individual, n.category, 'view') then n.id end,
        'need_title', case when n.id is not null and mirror.may(p_individual, n.category, 'view') then n.title end,
        'linked_hidden', n.id is not null and not mirror.may(p_individual, n.category, 'view'),
        'housed', r.status = 'moved_in') order by coalesce(f.done_on, f.due_on) desc)
      from public.nav_followups f join public.nav_referrals r on r.id = f.referral_id
      left join mirror.needs n on n.id = f.mirror_need_id
      where r.mirror_individual_id = p_individual and mirror.navigator_org(r.navigator_id) = v_org), '[]'::jsonb),
    'needs', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'title', n.title, 'status', n.status,
        'can_link', mirror.may(p_individual, n.category, 'edit')) order by n.created_at)
      from mirror.needs n where n.individual_id = p_individual and mirror.may(p_individual, n.category, 'view')), '[]'::jsonb),
    'organization_id', v_org);
end $$;

-- Link a check-in to a Mirror need (or unlink with null). Needs "see and change" for the need's topic.
create or replace function public.mirror_nav_checkin_link(p_followup uuid, p_need uuid, p_org uuid default null) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare f public.nav_followups; r public.nav_referrals; n mirror.needs; g jsonb;
begin
  select * into f from public.nav_followups where id = p_followup;
  select * into r from public.nav_referrals where id = f.referral_id;
  if f.id is null or r.mirror_individual_id is null then raise exception 'Not found.' using errcode = '42501'; end if;
  g := mirror.require(r.mirror_individual_id, 'general', 'edit', p_org, 'nav_followups', f.id::text);
  if mirror.navigator_org(r.navigator_id) is distinct from nullif(g ->> 'organization_id', '')::uuid then raise exception 'Not found.' using errcode = '42501'; end if;
  if p_need is not null then
    select * into n from mirror.needs where id = p_need and individual_id = r.mirror_individual_id;
    if n.id is null then raise exception 'That need is not in their Mirror.' using errcode = '22023'; end if;
    perform mirror.require(r.mirror_individual_id, n.category, 'edit', p_org, 'needs', n.id::text);
  elsif f.mirror_need_id is not null then
    select * into n from mirror.needs where id = f.mirror_need_id;
    perform mirror.require(r.mirror_individual_id, n.category, 'edit', p_org, 'needs', n.id::text);
  end if;
  update public.nav_followups set mirror_need_id = p_need where id = p_followup;
  return public.mirror_nav_checkins(r.mirror_individual_id, p_org);
end $$;

revoke all on function public.nav_checkin_next_before_housing(), public.nav_checkin_clear_on_close() from public, anon, authenticated;
revoke all on function public.mirror_nav_checkins(uuid, uuid), public.mirror_nav_checkin_link(uuid, uuid, uuid) from public, anon;
grant execute on function public.mirror_nav_checkins(uuid, uuid), public.mirror_nav_checkin_link(uuid, uuid, uuid) to authenticated, service_role;
