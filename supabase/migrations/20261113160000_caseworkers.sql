-- Caseworkers (Stephen, 10/21/2026): a social worker or agency that oversees a tenant gets an email, with no login,
-- when that tenant is sent a notice of lease violation (the breach-cure notice, template 2c-breach-cure). The tenant is
-- under the caseworker's purview, so no consent step is needed.
--   * caseworkers: name, agency, email, active. caseworker_clients: which tenants each one oversees.
--   * Trigger on notices: when a breach-cure notice is sent (inserted as sent, or a draft turning sent) and not voided,
--     one email_outbox row per caseworker of any tenant on the lease (kind 'caseworker_notice'; outbox-flush sends it).
--   * Staff manage them through the functions below (staff two-step sign-in), on https://2ndchinc.org/staff/caseworkers/
-- Rows are reached only through these functions; the tables have no policies.

create table if not exists caseworkers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  agency text,
  email text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists caseworkers_email_idx on caseworkers (lower(email));
alter table caseworkers enable row level security;

create table if not exists caseworker_clients (
  caseworker_id uuid not null references caseworkers(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (caseworker_id, tenant_id)
);
alter table caseworker_clients enable row level security;

-- Grants (new tables need them from 10/30/2026): edge functions only; the staff page goes through the functions below.
revoke all on caseworkers, caseworker_clients from anon, authenticated;
grant all on caseworkers, caseworker_clients to service_role;

create or replace function caseworker_notice_queue() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n record; cw record; v_unit text; v_names text; v_html text; v_deadline text;
begin
  if new.status <> 'sent' or new.voided or new.lease_id is null then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'sent' then return new; end if;
  if not exists (select 1 from letter_templates t where t.id = new.template_id and t.template_key = '2c-breach-cure') then return new; end if;

  select ru.address, l.tenants_label into v_unit, v_names
    from leases l join rental_units ru on ru.id = l.unit_id where l.id = new.lease_id;
  v_deadline := case when new.cure_deadline is null then '' else to_char(new.cure_deadline, 'FMMonth FMDD, YYYY') end;

  for cw in
    select distinct c.id, c.name, c.email from caseworkers c
      join caseworker_clients cc on cc.caseworker_id = c.id
      join lease_tenants lt on lt.tenant_id = cc.tenant_id and lt.lease_id = new.lease_id
     where c.active
  loop
    v_html := '<div style="font-family:Arial,sans-serif;max-width:680px;color:#1b2430">'
      || '<p>Hello ' || repair_esc(split_part(cw.name, ' ', 1)) || ',</p>'
      || '<p>2nd Chance Housing Inc sent a <b>notice of lease violation</b> on ' || to_char(new.sent_at at time zone 'America/Chicago', 'FMMonth FMDD, YYYY')
      || ' to your client at <b>' || repair_esc(coalesce(v_unit, 'the rental')) || '</b> (' || repair_esc(coalesce(v_names, '')) || ').'
      || case when v_deadline <> '' then ' The deadline to remedy it is <b>' || v_deadline || '</b>.' else '' end || '</p>'
      || '<p>A copy of the notice is below. If you can help your client resolve it, please reply to this email or contact the office at info@2ndchinc.org.</p>'
      || '<hr style="border:0;border-top:1px solid #ccd3dc;margin:16px 0">' || new.html
      || '<p style="color:#667;font-size:12px">You receive this email because you are listed as a caseworker for this tenant. Reply to this email to be removed.</p></div>';
    insert into email_outbox (to_email, subject, html, kind)
      values (cw.email, 'Notice of lease violation sent to your client (' || coalesce(v_unit, 'rental') || ')', v_html, 'caseworker_notice');
  end loop;
  return new;
end;
$$;
revoke all on function caseworker_notice_queue() from public, anon, authenticated;

drop trigger if exists notices_caseworker_queue on notices;
create trigger notices_caseworker_queue after insert or update of status on notices
  for each row execute function caseworker_notice_queue();

-- Staff list: each caseworker with the clients they oversee.
create or replace function caseworker_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'agency', c.agency, 'email', c.email, 'active', c.active,
      'clients', coalesce((select jsonb_agg(jsonb_build_object('tenant_id', t.id, 'name', t.name) order by t.name)
        from caseworker_clients cc join tenants t on t.id = cc.tenant_id where cc.caseworker_id = c.id), '[]'::jsonb)) order by c.active desc, c.name)
    from caseworkers c), '[]'::jsonb);
end;
$$;

-- Tenants who can be picked: anyone on an active or future lease (Unit 6 has none).
create or replace function caseworker_tenant_choices() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('tenant_id', x.id, 'label', x.label) order by x.label)
    from (select distinct t.id, t.name || ' (' || ru.address || ')' as label
            from tenants t join lease_tenants lt on lt.tenant_id = t.id join leases l on l.id = lt.lease_id and l.status in ('active', 'future')
            join rental_units ru on ru.id = l.unit_id) x), '[]'::jsonb);
end;
$$;

-- Add (p_id null) or change a caseworker, and set the full list of clients.
create or replace function caseworker_save(p_id uuid, p_name text, p_agency text, p_email text, p_active boolean, p_tenants uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  p_email := lower(trim(coalesce(p_email, '')));
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Enter the caseworker''s name.'; end if;
  if p_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Enter a valid email address.'; end if;
  if v_id is null then
    insert into caseworkers (name, agency, email) values (trim(p_name), nullif(trim(coalesce(p_agency, '')), ''), p_email) returning id into v_id;
  else
    update caseworkers set name = trim(p_name), agency = nullif(trim(coalesce(p_agency, '')), ''), email = p_email, active = coalesce(p_active, true) where id = v_id;
    if not found then raise exception 'Caseworker not found.'; end if;
  end if;
  delete from caseworker_clients where caseworker_id = v_id and tenant_id <> all (coalesce(p_tenants, '{}'));
  insert into caseworker_clients (caseworker_id, tenant_id)
    select v_id, t from unnest(coalesce(p_tenants, '{}')) t where exists (select 1 from tenants where id = t)
    on conflict do nothing;
  return v_id;
end;
$$;

create or replace function caseworker_remove(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  delete from caseworkers where id = p_id;
end;
$$;

revoke all on function caseworker_list(), caseworker_tenant_choices(), caseworker_remove(uuid) from public, anon;
revoke all on function caseworker_save(uuid, text, text, text, boolean, uuid[]) from public, anon;
grant execute on function caseworker_list(), caseworker_tenant_choices(), caseworker_remove(uuid) to authenticated;
grant execute on function caseworker_save(uuid, text, text, text, boolean, uuid[]) to authenticated;
