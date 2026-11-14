-- The Human Mirror Phase 9, handoff step 24: T2.6 second half, the invitation email and /mirror/register/. D-42 DECIDED; Stephen
-- approved the invitation wording on https://2ndchinc.org/mirror/admin/email/ (11/13/2026: "it is perfect").
--   * Every invitation is emailed through mirror.email_queue (T9.1), whichever way it is made: a coordinator adds a person with their
--     email (mirror_person_add), a Navigator starts a Mirror by invitation (nav_mirror_start), a link is restarted as an invitation, or an
--     admin adds an organization member (mirror_staff_invite). Done by triggers, so those live functions are not changed.
--   * mirror_invitation_resend / mirror_member_invite_resend: "Send the invitation again" (at most once per 12 hours per invitation,
--     the T9.1 repeat guard).
--   * The kinds stay OFF until Stephen turns them on (the hold, D-42): until then each invitation is recorded as held and not sent, and the
--     page tells the coordinator to give the person https://2ndchinc.org/mirror/register/ themselves.
-- No new table.

-- T9.1 fix (found by the T2.6 check): the 12-hour repeat guard counts only emails really queued, not held ones, so "send again"
-- works right after Stephen turns a kind on. Otherwise mirror.email_queue is unchanged from 20261119660000.
-- The one way a Mirror email is queued. Returns 'held', 'queued' or 'skipped'.
create or replace function mirror.email_queue(p_email text, p_kind text, p_data jsonb default '{}'::jsonb, p_individual uuid default null) returns text
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v_email text := lower(trim(coalesce(p_email, ''))); i mirror.individuals; v_data jsonb := coalesce(p_data, '{}'::jsonb); m jsonb; v_out bigint;
        v_ref text := nullif(p_data ->> 'ref', ''); v_reason text; v_status text;
begin
  if not exists (select 1 from jsonb_array_elements(mirror.email_kinds()) k where k ->> 'kind' = p_kind) then raise exception 'Unknown Mirror email kind: %', p_kind using errcode = '22023'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return 'skipped'; end if;
  select * into i from mirror.individuals where id = p_individual or (p_individual is null and auth_email = v_email) limit 1;
  v_data := v_data || jsonb_build_object('safety', coalesce(i.safety_sensitive, false));
  if p_kind in ('mirror_referral', 'mirror_appointment', 'mirror_action') and not mirror.notification_ok(v_email, p_kind) then
    v_reason := case when i.safety_sensitive then 'safety mode' else 'turned off by the person, or no Mirror' end;
  elsif v_ref is not null and exists (select 1 from mirror.notifications n where n.recipient_email = v_email and n.kind = p_kind and n.ref = v_ref
                                       and n.status = 'queued' and n.created_at > now() - interval '12 hours') then
    v_reason := 'already sent for this item in the last 12 hours';
  end if;
  if v_reason is not null then
    v_status := 'skipped';
  elsif p_kind = any (string_to_array(replace(coalesce(public.condo_setting('mirror_email_kinds_enabled', ''), ''), ' ', ''), ',')) then
    m := mirror.email_html(p_kind, v_data);
    insert into public.email_outbox (to_email, subject, html, kind) values (v_email, m ->> 'subject', m ->> 'html', p_kind) returning id into v_out;
    v_status := 'queued';
  else
    v_status := 'held'; v_reason := 'this kind is not turned on yet (Stephen turns each kind on)';
  end if;
  insert into mirror.notifications (recipient_email, individual_id, kind, ref, status, reason, outbox_id)
  values (v_email, i.id, p_kind, v_ref, v_status, v_reason, v_out);
  return v_status;
end $$;

-- A person invited (new link, or a link restarted as an invitation) gets the invitation, if they have an email.
create or replace function mirror.invite_email_on_link() returns trigger
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare i mirror.individuals;
begin
  if new.status = 'invited' and (tg_op = 'INSERT' or old.status is distinct from 'invited') then
    select * into i from mirror.individuals where id = new.individual_id;
    if i.auth_email is not null then
      perform mirror.email_queue(i.auth_email, 'mirror_invite',
        jsonb_build_object('first_name', coalesce(new.invited_name, i.preferred_name), 'organization', (select o.name from mirror.organizations o where o.id = new.organization_id),
                           'ref', 'invite:' || new.organization_id || ':' || new.individual_id), i.id);
    end if;
  end if;
  return new;
end $$;
create trigger organization_individuals_invite_email after insert or update of status on mirror.organization_individuals
  for each row execute function mirror.invite_email_on_link();

-- A new active organization member gets the member invitation.
create or replace function mirror.invite_email_on_member() returns trigger
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
begin
  if new.active and (tg_op = 'INSERT' or (old.active is distinct from true)) then
    perform mirror.email_queue(new.auth_email, 'mirror_staff_invite',
      jsonb_build_object('first_name', split_part(trim(new.name), ' ', 1), 'organization', (select o.name from mirror.organizations o where o.id = new.organization_id),
                         'ref', 'member:' || new.id), null);
  end if;
  return new;
end $$;
create trigger organization_members_invite_email after insert or update of active on mirror.organization_members
  for each row execute function mirror.invite_email_on_member();

-- "Send the invitation again" to a person still waiting to accept. Returns held / queued / skipped.
create or replace function public.mirror_invitation_resend(p_org uuid, p_individual uuid) returns text
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare oi mirror.organization_individuals; i mirror.individuals;
begin
  if p_org is null or not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  select * into oi from mirror.organization_individuals where organization_id = p_org and individual_id = p_individual;
  if oi.id is null then raise exception 'This person is not on your organization''s list.' using errcode = '42501'; end if;
  if oi.status <> 'invited' then raise exception 'Only a person still waiting to accept gets the invitation again.' using errcode = '22023'; end if;
  select * into i from mirror.individuals where id = p_individual;
  if i.auth_email is null then raise exception 'There is no email for this person.' using errcode = '22023'; end if;
  perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'edit', 'general', 'notifications', null, 'invitation sent again');
  return mirror.email_queue(i.auth_email, 'mirror_invite',
    jsonb_build_object('first_name', coalesce(oi.invited_name, i.preferred_name), 'organization', (select o.name from mirror.organizations o where o.id = p_org),
                       'ref', 'invite:' || p_org || ':' || p_individual), i.id);
end $$;

-- The same for an organization member (admins of that organization, or platform admins).
create or replace function public.mirror_member_invite_resend(p_member uuid) returns text
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare m mirror.organization_members;
begin
  select * into m from mirror.organization_members where id = p_member;
  if m.id is null or not mirror.can_manage_members(m.organization_id) then raise exception 'Organization admins only (with your authenticator code).' using errcode = '42501'; end if;
  if not m.active then raise exception 'Make the member active first.' using errcode = '22023'; end if;
  perform mirror.audit(null, m.organization_id, coalesce(mirror.my_role(m.organization_id), 'platform_admin'), 'member_save', 'organization', 'notifications', m.id::text, 'member invitation sent again');
  return mirror.email_queue(m.auth_email, 'mirror_staff_invite',
    jsonb_build_object('first_name', split_part(trim(m.name), ' ', 1), 'organization', (select o.name from mirror.organizations o where o.id = m.organization_id),
                       'ref', 'member:' || m.id), null);
end $$;

revoke all on function mirror.invite_email_on_link(), mirror.invite_email_on_member() from public, anon, authenticated;
revoke all on function public.mirror_invitation_resend(uuid, uuid), public.mirror_member_invite_resend(uuid) from public, anon;
grant execute on function public.mirror_invitation_resend(uuid, uuid), public.mirror_member_invite_resend(uuid) to authenticated, service_role;
