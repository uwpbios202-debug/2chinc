-- The Human Mirror P2-10 (Phase 9, handoff step 27): changing a person's email (SECURITY_PLAN section 3, "Lost email"). D-44.
-- A person signs in with an emailed code, so the email IS their sign-in. There is no password and no self-service change: the
-- organization that works with them changes it, on the People list (https://2ndchinc.org/mirror/workspace/people/).
--
-- Rules
--   * Only a coordinator of an organization the person is linked to (invited or active), on that organization's list.
--   * Not yet used (nobody ever signed in with the current email and the person is not active with any organization, for example a typo
--     on an invitation): any coordinator of that organization may correct it, with a short reason. The invitation goes to the new address
--     (through mirror.email_queue, so it is held while invitations are off). No notice to the old address (it may be a stranger's).
--   * Used (they signed in, or they are active anywhere): only the organization's admin (org_admin) or a 2nd Chance platform admin who
--     coordinates this organization. They first confirm who the person is (by phone, video or in person, never only by email), tick the
--     box and write why. Both the old and the new address get a security notice (kind mirror_security, always sent once Stephen turns it
--     on; neutral wording in safety mode). The old email's sign-ins are ended, unless that email still signs in to something else
--     (a 2nd Chance portal login or an organization membership).
--   * Never your own email (old or new), never an email another person already uses. At most 5 changes a day per coordinator.
--   * Every change is in the organization's audit log (who, when, whose, why; the addresses themselves are not written there).
--   * The person's display settings (mirror.profiles) move to the new email. Their records, sharing and history are keyed by the person,
--     not the email, so nothing else moves. Past notices keep the address they went to. A Navigator record (nav_referrals.email) is the
--     Navigator's own and is not changed.
-- No new table. No email is sent by this migration.

-- Whether the person's current email has been used (signed in), or they have a Mirror that is active anywhere.
create or replace function mirror.email_used(p_individual uuid) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select exists (select 1 from mirror.individuals i join auth.users u on lower(u.email) = i.auth_email
                 where i.id = p_individual and u.last_sign_in_at is not null)
      or exists (select 1 from mirror.organization_individuals oi where oi.individual_id = p_individual and oi.status = 'active');
$$;

-- Why this caller may not change this person's email in this organization (null = may).
create or replace function mirror.email_change_refusal(p_org uuid, p_individual uuid) returns text
language plpgsql stable security definer set search_path = mirror, public as $$
declare i mirror.individuals;
begin
  if p_org is null or not coalesce(mirror.coordinates(p_org), false) then return 'Coordinators of this organization only (with your authenticator code).'; end if;
  if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual
                 and oi.status in ('invited', 'active')) then
    return 'This person is not on your organization''s list.';
  end if;
  select * into i from mirror.individuals where id = p_individual;
  if i.auth_email = lower(auth.email()) then return 'You cannot change your own email here. Ask another admin, or call 2nd Chance.'; end if;
  if mirror.email_used(p_individual) then
    if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual
                   and oi.status = 'active') then
      return 'They haven''t accepted your invitation yet. The organization they work with can change their email, or call 2nd Chance.';
    end if;
    if not coalesce(mirror.can_manage_members(p_org), false) then                -- org admins and platform admins (mirror.role_permissions, D-41)
      return 'They have used this email to sign in, so only your organization''s admin can change it.';
    end if;
  end if;
  return null;
end $$;

-- For the People list: may this caller change this person's email, and is the confirmation needed.
create or replace function public.mirror_person_email_rule(p_org uuid, p_individual uuid) returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
begin
  if p_org is null or not coalesce(mirror.coordinates(p_org), false) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals oi where oi.organization_id = p_org and oi.individual_id = p_individual) then
    raise exception 'This person is not on your organization''s list.' using errcode = '42501';
  end if;
  return jsonb_build_object('refusal', mirror.email_change_refusal(p_org, p_individual), 'used', mirror.email_used(p_individual));
end $$;

-- The change itself. Returns what happened: the notices (held / queued / skipped) and whether old sign-ins were ended.
create or replace function public.mirror_person_email_change(p_org uuid, p_individual uuid, p_email text, p_reason text, p_confirmed boolean)
returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare i mirror.individuals; v_new text := lower(trim(coalesce(p_email, ''))); v_old text; v_why text; v_used boolean;
        v_role text; v_old_user uuid; v_signed_out int := 0; v_notice_old text; v_notice_new text; v_invite text; oi mirror.organization_individuals;
begin
  v_why := mirror.email_change_refusal(p_org, p_individual);
  if v_why is not null then raise exception '%', v_why using errcode = '42501'; end if;
  select * into i from mirror.individuals where id = p_individual;
  v_old := i.auth_email;
  v_used := mirror.email_used(p_individual);
  if v_new !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_new) > 254 then raise exception 'Enter a full email address, for example name@example.com.' using errcode = '22023'; end if;
  if v_new = v_old then raise exception 'That is already their email.' using errcode = '22023'; end if;
  if v_new = lower(auth.email()) then raise exception 'That is your own email. Enter theirs.' using errcode = '22023'; end if;
  if exists (select 1 from mirror.individuals x where x.auth_email = v_new and x.id <> p_individual) then
    raise exception 'Another person already uses that email. Each person needs their own.' using errcode = '22023';
  end if;
  if exists (select 1 from mirror.organization_members m where m.auth_email = v_new) then        -- the same rule as adding a person
    raise exception 'That email belongs to a coordinator. Use the person''s own email.' using errcode = '22023';
  end if;
  if v_used and coalesce(p_confirmed, false) is not true then
    raise exception 'First confirm it is them, by phone, video or in person (never only by email), then tick the box.' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Write why, for example: lost access to their old email.' using errcode = '22023'; end if;
  if length(p_reason) > 300 then raise exception 'Keep the reason to 300 characters.' using errcode = '22023'; end if;
  if (select count(*) from mirror.audit_logs where actor_email = lower(auth.email()) and action = 'email_change'
        and at > now() - interval '1 day') >= 5 then
    raise exception 'That is 5 email changes today. Call 2nd Chance at (262) 236-5443 if you need more.';
  end if;

  update mirror.individuals set auth_email = v_new, updated_at = now() where id = p_individual;
  if v_old is not null then
    if exists (select 1 from mirror.profiles where auth_email = v_new) then
      delete from mirror.profiles where auth_email = v_old;
    else
      update mirror.profiles set auth_email = v_new, updated_at = now() where auth_email = v_old;
    end if;
  end if;

  -- End the old email's sign-ins, unless it still signs in to something else.
  if v_old is not null and v_used
     and not coalesce(public.condo_email_on_file(v_old), false)
     and not exists (select 1 from mirror.organization_members m where m.auth_email = v_old and m.active) then
    select id into v_old_user from auth.users where lower(email) = v_old;
    if v_old_user is not null then
      delete from auth.sessions where user_id = v_old_user;
      get diagnostics v_signed_out = row_count;
    end if;
  end if;

  v_role := case when coalesce(mirror.is_platform_admin(), false) and not mirror.i_can(p_org, 'organization', 'edit') then 'platform_admin'
                 else mirror.my_role(p_org) end;                                 -- a label for the audit log only
  perform mirror.audit(p_individual, p_org, v_role, 'email_change', 'general', 'individuals', p_individual::text,
                       left(btrim(p_reason), 300) || case when v_used then ' (identity confirmed)' else ' (email not used yet)' end);

  if v_used then
    if v_old is not null then
      v_notice_old := mirror.email_queue(v_old, 'mirror_security',
        jsonb_build_object('first_name', i.preferred_name, 'reason', 'your sign-in email was changed to a new address',
                           'ref', 'email_change:' || p_individual || ':old:' || extract(epoch from now())::bigint), p_individual);
    end if;
    v_notice_new := mirror.email_queue(v_new, 'mirror_security',
      jsonb_build_object('first_name', i.preferred_name, 'reason', 'this is now your sign-in email',
                         'ref', 'email_change:' || p_individual || ':new:' || extract(epoch from now())::bigint), p_individual);
  else
    select * into oi from mirror.organization_individuals where organization_id = p_org and individual_id = p_individual;
    if oi.status = 'invited' then
      v_invite := mirror.email_queue(v_new, 'mirror_invite',
        jsonb_build_object('first_name', coalesce(oi.invited_name, i.preferred_name), 'organization', (select o.name from mirror.organizations o where o.id = p_org),
                           'ref', 'invite:' || p_org || ':' || p_individual), p_individual);
    end if;
  end if;

  return jsonb_build_object('used', v_used, 'notice_old', v_notice_old, 'notice_new', v_notice_new, 'invitation', v_invite,
                            'signed_out_devices', v_signed_out);
end $$;

revoke all on function mirror.email_used(uuid), mirror.email_change_refusal(uuid, uuid) from public, anon, authenticated;
grant execute on function mirror.email_used(uuid), mirror.email_change_refusal(uuid, uuid) to service_role;
revoke all on function public.mirror_person_email_rule(uuid, uuid), public.mirror_person_email_change(uuid, uuid, text, text, boolean) from public, anon;
grant execute on function public.mirror_person_email_rule(uuid, uuid), public.mirror_person_email_change(uuid, uuid, text, text, boolean) to authenticated, service_role;
