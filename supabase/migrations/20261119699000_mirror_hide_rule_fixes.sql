-- The Human Mirror P10-02, P10-03, P10-04 (found by the Phase 10 step 31 security re-check of 20261119698000; Stephen 11/14/2026: "yes";
-- agreed with lease-d6, which built 698000). Three functions; no table, no data, no email.
--
--   P10-02 mirror_person_hide: only a coordinator of an organization the person is ACTIVELY working with may hide them. An organization
--          that only invited them (they never accepted) must not be able to cut them off from the organizations they work with: hiding
--          ends every link at once, and unhiding does not bring the links back. Once allowed, hiding still ends every link (unchanged).
--   P10-03 mirror_person_email_rule: the same rule as the change itself. Unless the link is invited or active and the person is not
--          hidden, it answers only with a refusal (no "used"), so an organization whose link ended learns nothing about the person.
--   P10-04 mirror_notice_seen: the same checks as every other Mirror function of the person (mirror.me()): a current Mirror session,
--          not while viewing as someone else.

create or replace function public.mirror_person_hide(p_org uuid, p_individual uuid, p_reason text, p_confirmed boolean)
returns void
language plpgsql security definer set search_path = mirror, public as $function$
begin
  if p_org is null or not coalesce(mirror.coordinates(p_org), false) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual
                 and oi.status in ('invited', 'active')) then
    raise exception 'This person is not on your organization''s list.' using errcode = '42501';
  end if;
  -- P10-02: an invitation they have not accepted is not enough
  if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual
                 and oi.status = 'active') then
    raise exception 'They haven''t accepted your invitation, so your organization cannot hide their Mirror. They can hide it themselves in Settings, or call 2nd Chance at (262) 236-5443.' using errcode = '42501';
  end if;
  if coalesce(p_confirmed, false) is not true then raise exception 'Only when they ask for it, in person or by phone. Then tick the box.' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Write a short reason, for example: asked on the phone, not safe.' using errcode = '22023'; end if;
  perform mirror.hide_individual(p_individual, p_org, mirror.my_role(p_org), p_reason);
end $function$;

create or replace function public.mirror_person_email_rule(p_org uuid, p_individual uuid)
returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $function$
declare v_why text;
begin
  if p_org is null or not coalesce(mirror.coordinates(p_org), false) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual) then
    raise exception 'This person is not on your organization''s list.' using errcode = '42501';
  end if;
  -- P10-03: an ended link, or a hidden person, gets only a refusal (the change itself refuses the same way)
  if exists (select 1 from mirror.individuals where id = p_individual and hidden_at is not null) then
    return jsonb_build_object('refusal', 'This person is not on your organization''s list.', 'used', null);
  end if;
  v_why := mirror.email_change_refusal(p_org, p_individual);
  if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual
                 and oi.status in ('invited', 'active')) then
    return jsonb_build_object('refusal', coalesce(v_why, 'This person is not on your organization''s list.'), 'used', null);
  end if;
  return jsonb_build_object('refusal', v_why, 'used', mirror.email_used(p_individual));
end $function$;

create or replace function public.mirror_notice_seen(p_id text)
returns void
language plpgsql security definer set search_path = mirror, public as $function$
declare v_email text := lower(auth.email());
begin
  if v_email is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  -- P10-04: the same checks as mirror.me()
  if not mirror.session_ok() then raise exception '%', mirror.session_message() using errcode = '42501'; end if;
  if public.autopay_view_as_session() then raise exception 'Not available while viewing as someone else.' using errcode = '42501'; end if;
  insert into mirror.profiles (auth_email, notice_seen) values (v_email, left(p_id, 40))
  on conflict (auth_email) do update set notice_seen = excluded.notice_seen, updated_at = now();
end $function$;

revoke all on function public.mirror_person_hide(uuid, uuid, text, boolean), public.mirror_person_email_rule(uuid, uuid),
  public.mirror_notice_seen(text) from public, anon;
grant execute on function public.mirror_person_hide(uuid, uuid, text, boolean), public.mirror_person_email_rule(uuid, uuid),
  public.mirror_notice_seen(text) to authenticated, service_role;
