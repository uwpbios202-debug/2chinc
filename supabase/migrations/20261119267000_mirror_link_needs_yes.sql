-- The Human Mirror, Phase 2 fix 3 of 15 (Stephen, 11/13/2026): adding a person by email linked an existing Mirror without the person's yes.
-- Since fix 1 an invited person's answers stay closed until they accept on My Mirror. Three gaps remained (read on live 11/13):
--  1. mirror_person_status let a coordinator set ANY link to 'active', skipping the person's yes. Now 'active' only for people with no
--     sign-in (no email); people with an email can only be invited (they accept themselves) or ended. 'invited' only for people with an email.
--  2. mirror_people showed the person's OWN Mirror details (preferred and legal name, birth year, safety flag) for an existing Mirror the
--     organization had only invited, or that declined. That also told the coordinator the email already had a Mirror. Now, until the person
--     accepts (audit action invitation_accept) or unless this organization created the record, the list shows only the name the coordinator
--     typed (new column invited_name) and the email the coordinator typed.
--  3. mirror_person_add dropped the typed name when the email already had a Mirror. It now keeps it in invited_name, and answers the same
--     way whether or not the email already had a Mirror.
-- No table is created, so no new grants are needed. Function grants are unchanged (create or replace keeps them).

alter table mirror.organization_individuals
  add column invited_name text check (invited_name is null or length(invited_name) <= 120);

-- Did this person say yes to this organization, or did this organization create the record itself?
create or replace function mirror.known_to_org(p_individual uuid, p_org uuid) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select exists (select 1 from mirror.individuals i where i.id = p_individual and i.created_by_org = p_org)
      or exists (select 1 from mirror.audit_logs a where a.individual_id = p_individual and a.organization_id = p_org and a.action = 'invitation_accept');
$$;
revoke all on function mirror.known_to_org(uuid, uuid) from public;

create or replace function public.mirror_person_add(p jsonb)
returns uuid
language plpgsql security definer set search_path = mirror, public as $$
declare
  v_org uuid := nullif(p ->> 'organization_id', '')::uuid;
  v_name text := nullif(trim(p ->> 'preferred_name'), '');
  v_legal text := nullif(trim(p ->> 'legal_name'), '');
  v_email text := nullif(lower(trim(coalesce(p ->> 'email', ''))), '');
  v_year int := nullif(p ->> 'birth_year', '')::int;
  v_me uuid;
  v_id uuid;
begin
  if v_org is null or not mirror.coordinates(v_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if v_name is null then raise exception 'Enter the name the person goes by.' using errcode = '22023'; end if;
  if length(v_name) > 120 then raise exception 'That name is too long.' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, or leave it empty.' using errcode = '22023'; end if;
  if v_year is not null and (v_year < 1900 or v_year > extract(year from now())::int) then raise exception 'Birth year looks wrong.' using errcode = '22023'; end if;
  if v_email is not null and exists (select 1 from mirror.organization_members m where m.auth_email = v_email) then
    raise exception 'That email belongs to a coordinator. Use the person''s own email.' using errcode = '22023';
  end if;
  select id into v_me from mirror.organization_members where organization_id = v_org and auth_email = lower(auth.email());

  -- The same email already has a Mirror (with another organization): link to it as an INVITATION only; never copy or overwrite
  -- their answers or details, and show this organization nothing of theirs until they accept.
  if v_email is not null then select id into v_id from mirror.individuals where auth_email = v_email; end if;
  if v_id is null then
    insert into mirror.individuals (auth_email, preferred_name, legal_name, birth_year, created_by_org)
    values (v_email, v_name, v_legal, v_year, v_org) returning id into v_id;
  end if;
  if exists (select 1 from mirror.organization_individuals where organization_id = v_org and individual_id = v_id) then
    raise exception 'This person is already on your list.' using errcode = '23505';
  end if;
  insert into mirror.organization_individuals (organization_id, individual_id, status, started_on, primary_member_id, invited_name)
  values (v_org, v_id, case when v_email is null then 'active' else 'invited' end, current_date, v_me, v_name);
  perform mirror.audit(v_id, v_org, mirror.my_role(v_org), 'edit', 'general', 'organization_individuals', v_id::text);
  return v_id;
end $$;

create or replace function public.mirror_people(p_org uuid)
returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(case when mirror.known_to_org(i.id, p_org) then jsonb_build_object(
      'id', i.id, 'preferred_name', i.preferred_name, 'legal_name', i.legal_name, 'email', i.auth_email, 'birth_year', i.birth_year,
      'status', oi.status, 'started_on', oi.started_on, 'ended_on', oi.ended_on,
      'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
      'safety_sensitive', i.safety_sensitive)
    else jsonb_build_object(
      'id', i.id, 'preferred_name', coalesce(oi.invited_name, 'Invited person'), 'legal_name', null, 'email', i.auth_email, 'birth_year', null,
      'status', oi.status, 'started_on', oi.started_on, 'ended_on', oi.ended_on,
      'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
      'safety_sensitive', null) end
    order by (oi.status = 'ended'), lower(case when mirror.known_to_org(i.id, p_org) then i.preferred_name else coalesce(oi.invited_name, '') end))
    from mirror.organization_individuals oi join mirror.individuals i on i.id = oi.individual_id
    where oi.organization_id = p_org), '[]'::jsonb);
end $$;

create or replace function public.mirror_person_status(p_org uuid, p_individual uuid, p_status text)
returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v_email text;
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if p_status not in ('ended', 'active', 'invited') then raise exception 'Unknown status.' using errcode = '22023'; end if;
  select auth_email into v_email from mirror.individuals where id = p_individual;
  if p_status = 'active' and v_email is not null then
    raise exception 'This person has their own sign-in, so they say yes themselves on My Mirror. Invite them instead.' using errcode = '42501';
  end if;
  if p_status = 'invited' and v_email is null then
    raise exception 'This person has no email, so there is no invitation to send. Restart them instead.' using errcode = '22023';
  end if;
  update mirror.organization_individuals
     set status = p_status, ended_on = case when p_status = 'ended' then current_date else null end
   where organization_id = p_org and individual_id = p_individual;
  if not found then raise exception 'This person is not on your list.' using errcode = 'P0002'; end if;
  perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'edit', 'general', 'organization_individuals', p_status);
end $$;
