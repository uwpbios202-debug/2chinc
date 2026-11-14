-- The Human Mirror Phase N, handoff step 19: TN.2 Navigator person = Mirror individual (closes NAVIGATOR.md gap N1). D-36 DECIDED.
-- The live Navigator portal keeps working; this connects it, never replaces it.
--   * nav_referrals.mirror_individual_id: the person's Human Mirror, once started.
--   * Each Navigator business is a Mirror organization (D-06, D-20): mirror.navigator_org(navigator) finds it, or creates it on the first
--     "Start their Mirror" (kind navigator, named after the business, the Navigator its admin). Long Lasting Care LLC already exists.
--   * "Start their Mirror" (nav_mirror_start) on the person's file, by their Navigator or the office, after the housing consent, never for
--     a sample person, and only when the Navigator reports the person said yes to a Human Mirror. Two ways (D-03):
--       with their email: an invitation; the Navigator's organization sees nothing until the person signs in and accepts (as T2.6);
--       without email: the Navigator fills it in with them (active at once; choices are recorded for them, as for a paper consent).
--     The same email already having a Mirror links to it as an invitation only (nothing copied or overwritten, as mirror_person_add).
--     The person's sharing beyond housing (TN.1) is copied into mirror.consents for the Navigator's organization.
--   * D-36 (h): once the person has their own Mirror sign-in (an email on their Mirror), they change sharing themselves in Settings; the
--     Navigator screen then only shows it. Without a sign-in, a new signing on the Navigator screen is copied into the Mirror again.
--   * Withdrawing the housing consent ends the Navigator organization's work with the Mirror (sharing revoked, link ended); the Mirror
--     itself stays the person's (they can keep using it or delete it).
--   * "Open their Mirror": the link to /mirror/workspace/person/ (the Mirror's own sign-in with an authenticator code applies, D-13).
-- No email is sent (the invitation email is Phase 9, T2.6 second half).

alter table public.nav_referrals add column if not exists mirror_individual_id uuid references mirror.individuals(id) on delete set null;
create index if not exists nav_referrals_mirror on public.nav_referrals (mirror_individual_id) where mirror_individual_id is not null;

-- The Navigator business's Mirror organization (created on first use, the Navigator as its admin).
create or replace function mirror.navigator_org(p_navigator uuid, p_create boolean default false) returns uuid
language plpgsql security definer set search_path = mirror, public as $$
declare v_org uuid; n public.navigators;
begin
  select id into v_org from mirror.organizations where navigator_id = p_navigator and kind = 'navigator' and active order by created_at limit 1;
  if v_org is not null or not p_create then return v_org; end if;
  select * into n from public.navigators where id = p_navigator;
  if n.id is null then return null; end if;
  insert into mirror.organizations (name, kind, navigator_id) values (coalesce(nullif(trim(n.business_name), ''), n.name), 'navigator', n.id) returning id into v_org;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values (v_org, lower(trim(n.email)), n.name, 'org_admin')
    on conflict (organization_id, auth_email) do nothing;
  perform mirror.audit(null, v_org, 'navigator', 'edit', 'organization', 'organizations', v_org::text, 'created for the Navigator''s business (TN.2)');
  return v_org;
end $$;

-- The person's Mirror as the Navigator screen sees it.
create or replace function mirror.nav_mirror_state(r public.nav_referrals) returns jsonb
language sql stable security definer set search_path = mirror, public as $$
  select case when r.mirror_individual_id is null then null else jsonb_build_object(
    'individual_id', r.mirror_individual_id,
    'organization_id', mirror.navigator_org(r.navigator_id),
    'status', (select oi.status from mirror.organization_individuals oi where oi.individual_id = r.mirror_individual_id
                and oi.organization_id = mirror.navigator_org(r.navigator_id)),
    'own_signin', (select i.auth_email is not null from mirror.individuals i where i.id = r.mirror_individual_id)) end;
$$;

-- Start the person's Mirror from their Navigator file.
create or replace function public.nav_mirror_start(p_id uuid, p_with_email boolean, p_person_agreed boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r nav_referrals; v_role text := nav_actor_role(); v_org uuid; v_member uuid; v_ind uuid; v_email text; v_status text; n int;
begin
  if v_role is null or not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  select * into r from nav_referrals where id = p_id;
  if r.is_sample then raise exception 'Sample people do not get a Human Mirror.'; end if;
  if r.mirror_individual_id is not null then raise exception 'Their Human Mirror is already started.'; end if;
  if r.consent_on is null or r.consent_withdrawn_on is not null or r.status = 'closed' then
    raise exception 'First the person signs the housing consent (Edit details).';
  end if;
  if r.navigator_id is null then raise exception 'Assign a Navigator to this person first.'; end if;
  if coalesce(p_person_agreed, false) is not true then raise exception 'Ask the person first, then tick that they said yes.' using errcode = '22023'; end if;
  v_email := case when coalesce(p_with_email, false) then nullif(lower(trim(coalesce(r.email, ''))), '') end;
  if coalesce(p_with_email, false) and v_email is null then raise exception 'There is no email on their file. Add it (Edit details), or start without email.' using errcode = '22023'; end if;
  if v_email is not null and exists (select 1 from mirror.organization_members m where m.auth_email = v_email) then
    raise exception 'That email belongs to a coordinator. Use the person''s own email, or start without email.' using errcode = '22023';
  end if;
  v_org := mirror.navigator_org(r.navigator_id, true);
  select m.id into v_member from mirror.organization_members m join navigators nv on lower(trim(nv.email)) = m.auth_email
   where m.organization_id = v_org and nv.id = r.navigator_id;
  if v_email is not null then select id into v_ind from mirror.individuals where auth_email = v_email; end if;
  if v_ind is null then
    insert into mirror.individuals (auth_email, preferred_name, legal_name, created_by_org)
    values (v_email, left(trim(r.first_name), 120), nullif(left(trim(r.first_name || ' ' || coalesce(r.last_name, '')), 200), ''), v_org) returning id into v_ind;
  end if;
  v_status := case when v_email is null then 'active' else 'invited' end;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on, primary_member_id, invited_name)
  values (v_org, v_ind, v_status, current_date, v_member, left(trim(r.first_name), 120))
  on conflict (organization_id, individual_id) do update set status = case when mirror.organization_individuals.status = 'ended' then excluded.status
      else mirror.organization_individuals.status end, ended_on = null, updated_at = now();
  update nav_referrals set mirror_individual_id = v_ind, updated_at = now() where id = p_id;
  n := mirror.nav_whole_consent_to_mirror(p_id, v_ind);
  perform mirror.audit(v_ind, v_org, case when v_role = 'staff' then 'platform_admin' else 'navigator' end, 'edit', 'general', 'organization_individuals', v_ind::text,
                       'started from the Navigator file (TN.2)');
  perform nav_log('mirror_started', 'Human Mirror started ' || case when v_email is null then 'without email (filled in together)' else 'as an invitation to their email' end
    || '; sharing beyond housing copied: ' || n || ' private ' || case when n = 1 then 'topic' else 'topics' end || '. The person said yes.', p_id);
  return nav_whole_consent(p_id);
end $$;

-- What the screen shows (TN.1 version + the Mirror link and D-36 (h)).
create or replace function public.nav_whole_consent(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r nav_referrals; c nav_whole_consents; m jsonb;
begin
  if not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  select * into r from nav_referrals where id = p_id;
  select * into c from nav_whole_consents where nav_referral_id = p_id and replaced_at is null;
  m := mirror.nav_mirror_state(r);
  return jsonb_build_object(
    'topics', nav_whole_topics(),
    'receiver', nav_whole_receiver(r),
    'full_name', trim(r.first_name || ' ' || coalesce(r.last_name, '')),
    'has_email', nullif(trim(coalesce(r.email, '')), '') is not null,
    'can_record', r.consent_on is not null and r.consent_withdrawn_on is null and r.status <> 'closed' and not coalesce((m ->> 'own_signin')::boolean, false),
    'own_signin', coalesce((m ->> 'own_signin')::boolean, false),
    'can_start_mirror', r.mirror_individual_id is null and not r.is_sample and r.navigator_id is not null
                        and r.consent_on is not null and r.consent_withdrawn_on is null and r.status <> 'closed',
    'mirror', m,
    'current', case when c.id is null then null else jsonb_build_object('topics', c.topics, 'signed_by', c.consent_name, 'signed_at', c.signed_at,
                 'words', c.consent_text, 'withdrawn_on', c.withdrawn_on) end);
end $$;

-- Saving the choice (TN.1 version + D-36 (h) + copy into the Mirror when linked without a sign-in).
create or replace function public.nav_whole_consent_save(p_id uuid, p_topics jsonb, p_consent_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r nav_referrals; v_role text := nav_actor_role(); v_topics jsonb := '{}'::jsonb; k text; a text; v_words text; v_full text;
begin
  if v_role is null or not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  select * into r from nav_referrals where id = p_id;
  if r.consent_on is null or r.consent_withdrawn_on is not null or r.status = 'closed' then
    raise exception 'First the person signs the housing consent (Edit details). Sharing beyond housing comes after it.';
  end if;
  if coalesce((mirror.nav_mirror_state(r) ->> 'own_signin')::boolean, false) then
    raise exception 'They have their own Human Mirror sign-in, so they change what they share themselves, in their Mirror Settings.';
  end if;
  for k in select x ->> 'key' from jsonb_array_elements(nav_whole_topics()) x loop
    a := coalesce(p_topics ->> k, 'none');
    if a not in ('none', 'view', 'edit') then raise exception 'Choose not shared, can see, or can see and change for each topic.' using errcode = '22023'; end if;
    v_topics := v_topics || jsonb_build_object(k, a);
  end loop;
  v_full := trim(r.first_name || ' ' || coalesce(r.last_name, ''));
  if lower(regexp_replace(trim(coalesce(p_consent_name, '')), '\s+', ' ', 'g')) <> lower(regexp_replace(v_full, '\s+', ' ', 'g')) then
    raise exception 'The person types their own full name, as on file: %.', v_full using errcode = '22023';
  end if;
  v_words := nav_whole_words(r, v_topics);
  update nav_whole_consents set replaced_at = now() where nav_referral_id = p_id and replaced_at is null;
  insert into nav_whole_consents (nav_referral_id, topics, consent_name, consent_text, recorded_by, recorded_role)
  values (p_id, v_topics, trim(p_consent_name), v_words, lower(auth.email()), v_role);
  perform nav_log('whole_consent', 'Sharing beyond housing signed by ' || trim(p_consent_name) || ': '
    || coalesce((select string_agg(x ->> 'label' || case when v_topics ->> (x ->> 'key') = 'edit' then ' (see and change)' else ' (see)' end, ', ')
                 from jsonb_array_elements(nav_whole_topics()) x where v_topics ->> (x ->> 'key') in ('view', 'edit')), 'no private topics'), p_id);
  if r.mirror_individual_id is not null then perform mirror.nav_whole_consent_to_mirror(p_id, r.mirror_individual_id); end if;
  return nav_whole_consent(p_id);
end $$;

-- Withdrawing the housing consent: ends sharing beyond housing (TN.1) and the Navigator organization's work with the Mirror.
create or replace function public.nav_whole_consent_follow_withdraw() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  if new.consent_withdrawn_on is not null and old.consent_withdrawn_on is null then
    update nav_whole_consents set withdrawn_on = new.consent_withdrawn_on where nav_referral_id = new.id and withdrawn_on is null;
    if new.mirror_individual_id is not null then
      v_org := mirror.navigator_org(new.navigator_id);
      if v_org is not null then
        update mirror.consents set revoked_at = now(), revoked_by = coalesce(lower(auth.email()), 'navigator consent withdrawn')
         where individual_id = new.mirror_individual_id and organization_id = v_org and revoked_at is null;
        update mirror.organization_individuals set status = 'ended', ended_on = current_date, updated_at = now()
         where individual_id = new.mirror_individual_id and organization_id = v_org and status <> 'ended';
        perform mirror.audit(new.mirror_individual_id, v_org, 'navigator', 'edit', 'general', 'organization_individuals', new.mirror_individual_id::text,
                             'housing consent withdrawn: sharing revoked, work ended');
      end if;
    end if;
  end if;
  return new;
end $$;

revoke all on function mirror.navigator_org(uuid, boolean), mirror.nav_mirror_state(public.nav_referrals) from public, anon, authenticated;
grant execute on function mirror.navigator_org(uuid, boolean), mirror.nav_mirror_state(public.nav_referrals) to service_role;
revoke all on function public.nav_mirror_start(uuid, boolean, boolean) from public, anon;
grant execute on function public.nav_mirror_start(uuid, boolean, boolean) to authenticated, service_role;
