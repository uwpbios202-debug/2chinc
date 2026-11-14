-- Caseworkers, part 2 (Stephen, 10/21/2026): the application asks for an optional caseworker (name, email, phone), kept in
-- rental_applications.applicant as cw_name / cw_email / cw_phone. Staff pre-fill a caseworker from an application on
-- https://2ndchinc.org/staff/caseworkers/; the applicant who became a tenant (same email) is ticked as the client.
-- Nothing is emailed from an application alone: the caseworker only gets mail once staff save them there.

alter table caseworkers add column if not exists phone text;

drop function if exists caseworker_save(uuid, text, text, text, boolean, uuid[]);
create or replace function caseworker_save(p_id uuid, p_name text, p_agency text, p_email text, p_phone text, p_active boolean, p_tenants uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  p_email := lower(trim(coalesce(p_email, '')));
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Enter the caseworker''s name.'; end if;
  if p_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Enter a valid email address.'; end if;
  if v_id is null then
    insert into caseworkers (name, agency, email, phone) values (trim(p_name), nullif(trim(coalesce(p_agency, '')), ''), p_email, nullif(trim(coalesce(p_phone, '')), ''))
      on conflict ((lower(email))) do update set name = excluded.name, agency = coalesce(excluded.agency, caseworkers.agency),
        phone = coalesce(excluded.phone, caseworkers.phone), active = true
      returning id into v_id;
  else
    update caseworkers set name = trim(p_name), agency = nullif(trim(coalesce(p_agency, '')), ''), email = p_email,
      phone = nullif(trim(coalesce(p_phone, '')), ''), active = coalesce(p_active, true) where id = v_id;
    if not found then raise exception 'Caseworker not found.'; end if;
  end if;
  insert into caseworker_clients (caseworker_id, tenant_id)
    select v_id, t from unnest(coalesce(p_tenants, '{}')) t where exists (select 1 from tenants where id = t)
    on conflict do nothing;
  if p_id is not null then
    delete from caseworker_clients where caseworker_id = v_id and tenant_id <> all (coalesce(p_tenants, '{}'));
  end if;
  return v_id;
end;
$$;
revoke all on function caseworker_save(uuid, text, text, text, text, boolean, uuid[]) from public, anon;
grant execute on function caseworker_save(uuid, text, text, text, text, boolean, uuid[]) to authenticated;

create or replace function caseworker_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'agency', c.agency, 'email', c.email, 'phone', c.phone, 'active', c.active,
      'clients', coalesce((select jsonb_agg(jsonb_build_object('tenant_id', t.id, 'name', t.name) order by t.name)
        from caseworker_clients cc join tenants t on t.id = cc.tenant_id where cc.caseworker_id = c.id), '[]'::jsonb)) order by c.active desc, c.name)
    from caseworkers c), '[]'::jsonb);
end;
$$;

-- Applications that named a caseworker with an email, newest first, with the matching tenant (same email) and whether the
-- caseworker is already on the list.
create or replace function caseworker_from_applications() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'created_at') desc) from (
    select jsonb_build_object('id', a.id, 'created_at', a.created_at, 'applicant', a.applicant->>'name', 'status', a.status,
        'cw_name', a.applicant->>'cw_name', 'cw_email', lower(a.applicant->>'cw_email'), 'cw_phone', a.applicant->>'cw_phone', 'agency', a.applicant->>'agency',
        'tenant_id', (select t.id from tenants t where lower(t.email) = lower(a.applicant->>'email') limit 1),
        'listed', exists (select 1 from caseworkers c where lower(c.email) = lower(a.applicant->>'cw_email'))) as x
      from rental_applications a
     where coalesce(a.applicant->>'cw_email', '') <> '') s), '[]'::jsonb);
end;
$$;
revoke all on function caseworker_list(), caseworker_from_applications() from public, anon;
grant execute on function caseworker_list(), caseworker_from_applications() to authenticated;
