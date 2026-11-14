-- The Human Mirror: making the final privacy page true before it is published (legal's text, Stephen 11/14/2026: "build all 3 first").
--   1. "If you are in danger, tell your coordinator or call us. We will hide your Mirror from everyone right away while the 30 days run."
--      mirror.individuals.hidden_at. Hiding ends every organization's link at once (an organization reaches a person only through an
--      active link, mirror.allowed), takes the person off every People list, shows them in organization audit logs only as "A person
--      not on your list", and stops anyone restarting, re-inviting or re-adding them. The person still signs in and sees their own Mirror.
--        * The person: Settings, "Hide my Mirror from everyone now" (mirror_my_hide) and "Show it to organizations again" (mirror_my_unhide;
--          old links stay ended, organizations can invite them again).
--        * A coordinator of an organization they work with: "Hide their Mirror now" on the People list (mirror_person_hide), after the
--          person asked (in person or by phone), with a reason. It only hides; it never asks for deletion (a coordinator must not be able
--          to have someone's Mirror deleted).
--        * 2nd Chance (platform admin), when the person calls: by email (mirror_platform_hide), optionally recording the deletion request
--          the person made on the phone.
--      Every hide is in the audit log. Hiding does not change a deletion request, and keeping the Mirror does not end the hiding.
--   2. "The Mirror is for adults 18 and older." A birth year that makes the person under 18 (this year minus the birth year < 18) is
--      refused wherever it is entered (trigger on mirror.individuals). Birth year stays optional.
--   3. "If we change how we use or share your information, we will tell you in the Mirror the next time you sign in, before the change
--      starts." portal_settings.mirror_change_notice (empty = none) set by the 2nd Chance main admin (mirror_admin_change_notice_set, the
--      start date must be after today); mirror_whoami returns it until the person presses "I've read it" (mirror_notice_seen,
--      mirror.profiles.notice_seen); every Mirror page shows it at the top.
-- New columns only (no new table). No email is sent.

alter table mirror.individuals add column hidden_at timestamptz;
alter table mirror.profiles add column notice_seen text;
insert into portal_settings (key, value) values ('mirror_change_notice', '') on conflict (key) do nothing;

-- 2. adults only
create or replace function mirror.adults_only() returns trigger
language plpgsql set search_path = mirror as $$
begin
  if new.birth_year is not null and new.birth_year > extract(year from (now() at time zone 'America/Chicago'))::int - 18 then
    raise exception 'The Mirror is for adults 18 and older. For someone under 18: call or text 988, or call 2nd Chance at (262) 236-5443.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger individuals_adults_only before insert or update of birth_year on mirror.individuals
  for each row execute function mirror.adults_only();

-- 1. hiding
create or replace function mirror.hide_individual(p_individual uuid, p_org uuid, p_role text, p_reason text) returns void
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
begin
  update mirror.individuals set hidden_at = coalesce(hidden_at, now()), updated_at = now() where id = p_individual;
  update mirror.organization_individuals set status = 'ended', ended_on = current_date, updated_at = now()
   where individual_id = p_individual and status <> 'ended';
  perform mirror.audit(p_individual, p_org, p_role, 'hide', 'general', 'individuals', null, nullif(left(btrim(coalesce(p_reason, '')), 300), ''));
end $$;

create or replace function public.mirror_my_hide() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  perform mirror.hide_individual(v, null, 'self', null);
  return (select jsonb_build_object('hidden_at', hidden_at) from mirror.individuals where id = v);
end $$;

create or replace function public.mirror_my_unhide() returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me();
begin
  update mirror.individuals set hidden_at = null, updated_at = now() where id = v and hidden_at is not null;
  if found then perform mirror.audit(v, null, 'self', 'unhide', 'general', 'individuals', null, null); end if;
  return jsonb_build_object('hidden_at', null);
end $$;

create or replace function public.mirror_person_hide(p_org uuid, p_individual uuid, p_reason text, p_confirmed boolean) returns void
language plpgsql security definer set search_path = mirror, public as $$
begin
  if p_org is null or not coalesce(mirror.coordinates(p_org), false) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual
                 and oi.status in ('invited', 'active')) then
    raise exception 'This person is not on your organization''s list.' using errcode = '42501';
  end if;
  if coalesce(p_confirmed, false) is not true then raise exception 'Only when they ask for it, in person or by phone. Then tick the box.' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Write a short reason, for example: asked on the phone, not safe.' using errcode = '22023'; end if;
  perform mirror.hide_individual(p_individual, p_org, mirror.my_role(p_org), p_reason);
end $$;

create or replace function public.mirror_platform_hide(p_email text, p_also_delete boolean, p_reason text, p_confirmed boolean) returns text
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid;
begin
  if not coalesce(mirror.is_platform_admin(), false) then raise exception 'Platform admins only (with your authenticator code).' using errcode = '42501'; end if;
  if coalesce(p_confirmed, false) is not true then raise exception 'First confirm it is them (by phone, video or in person), then tick the box.' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Write a short reason, for example: called, not safe.' using errcode = '22023'; end if;
  select id into v from mirror.individuals where auth_email = lower(trim(coalesce(p_email, '')));
  if v is null then return 'No Mirror uses that email.'; end if;
  perform mirror.hide_individual(v, null, 'platform_admin', p_reason);
  if coalesce(p_also_delete, false) then
    update mirror.individuals set deletion_requested_at = coalesce(deletion_requested_at, now()) where id = v;
    perform mirror.audit(v, null, 'platform_admin', 'delete_request', 'general', 'individuals', null, 'asked by phone');
    return 'Hidden from everyone now. Deletion asked for: it will be deleted after 30 days.';
  end if;
  return 'Hidden from everyone now.';
end $$;

-- 3. change notice
create or replace function public.mirror_notice_seen(p_id text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v_email text := lower(auth.email());
begin
  if v_email is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  insert into mirror.profiles (auth_email, notice_seen) values (v_email, left(p_id, 40))
  on conflict (auth_email) do update set notice_seen = excluded.notice_seen, updated_at = now();
end $$;

create or replace function public.mirror_admin_change_notice_set(p_text text, p_starts date) returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v jsonb;
begin
  if not (coalesce(mirror.signed_in_member_ok(), false) and exists (select 1 from public.portal_admins where lower(email) = lower(auth.email()))) then
    raise exception 'The 2nd Chance main admin only (with your authenticator code).' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_text, '')), '') is null then
    update public.portal_settings set value = '' where key = 'mirror_change_notice';
    perform mirror.audit(null, null, 'platform_admin', 'edit', 'organization', 'portal_settings', 'mirror_change_notice', 'cleared');
    return null;
  end if;
  if length(p_text) > 1000 then raise exception 'Keep the notice to 1,000 characters.' using errcode = '22023'; end if;
  if p_starts is null or p_starts <= current_date then raise exception 'Give the day the change starts. It must be after today, so people are told first.' using errcode = '22023'; end if;
  v := jsonb_build_object('id', to_char(now(), 'YYYYMMDDHH24MISS'), 'text', btrim(p_text), 'starts', p_starts);
  update public.portal_settings set value = v::text where key = 'mirror_change_notice';
  perform mirror.audit(null, null, 'platform_admin', 'edit', 'organization', 'portal_settings', 'mirror_change_notice', 'set');
  return v;
end $$;
