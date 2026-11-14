-- Agent countersignature.
--
-- A lease is sent WITHOUT the agent's signature. After every tenant signs,
-- the lease waits for the agent. The agent signs in (email code + texted
-- code), reviews the tenant-signed lease, and countersigns; only then does
-- the system apply the agent's stored signature image and build and email
-- the executed PDF. The signature image lives in the private lease-signing
-- bucket (agents/<id>.png) and is only ever read by the lease-signing
-- function: it is never sent to a browser or placed in the lease builder.

create table if not exists lease_agents (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  title text,
  org text,
  email text not null unique,          -- the agent's sign-in email
  phone_mobile text,                   -- where the sign-in text code goes
  signature_path text,                 -- lease-signing bucket path; set by tools/site/agent_signature.py
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table lease_agents enable row level security;

alter table lease_signing_docs add column if not exists agent_id uuid references lease_agents(id);
alter table lease_signing_docs add column if not exists agent_signed_at timestamptz;
alter table lease_signing_docs add column if not exists agent_sign_ip text;
alter table lease_signing_docs add column if not exists agent_sign_user_agent text;
alter table lease_signing_docs drop constraint if exists lease_signing_docs_status_check;
alter table lease_signing_docs add constraint lease_signing_docs_status_check
  check (status in ('sent', 'awaiting_agent', 'signed', 'void'));

-- Agents sign in like everyone else (email code, then a texted code).
create or replace function condo_email_on_file(p_email text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email))
      or exists (select 1 from lease_agents where active and lower(email) = lower(p_email));
$$;

create or replace function condo_mfa_phone_for(p_email text)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select phone_mobile from condo_staff where lower(email) = lower(p_email)),
    (select phone_mobile from condo_owners where id = condo_owner_for_email(p_email)),
    (select phone_mobile from lease_agents where active and lower(email) = lower(p_email)));
$$;

create or replace function condo_whoami()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_agent uuid := (select id from lease_agents where active and lower(email) = lower(auth.email()));
  v_phone text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  if v_staff then
    select phone_mobile into v_phone from condo_staff where lower(email) = lower(auth.email());
  elsif v_owner is not null then
    select phone_mobile into v_phone from condo_owners where id = v_owner;
  elsif v_agent is not null then
    select phone_mobile into v_phone from lease_agents where id = v_agent;
  else
    return jsonb_build_object('role', 'none');
  end if;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' else 'agent' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$$;

-- The agent record for the signed-in, two-step-verified user (or null).
create or replace function lease_agent_me()
returns uuid
language sql stable security definer set search_path = public
as $$
  select a.id from lease_agents a
  where a.active and lower(a.email) = lower(auth.email()) and condo_session_ok();
$$;
revoke all on function lease_agent_me() from public, anon;
grant execute on function lease_agent_me() to authenticated;

-- Agents choosable when sending (staff only; never returns the signature).
create or replace function lease_agents_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'title', title, 'org', org,
      'has_signature', signature_path is not null) order by name) from lease_agents where active), '[]'::jsonb);
end;
$$;
revoke all on function lease_agents_list() from public, anon;
grant execute on function lease_agents_list() to authenticated;

-- Leases waiting for the signed-in agent, and one of them in full.
create or replace function lease_agent_queue()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_agent uuid := lease_agent_me();
begin
  if v_agent is null then raise exception 'Agent two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'unit_label', d.unit_label, 'title', d.title, 'status', d.status,
      'created_at', d.created_at, 'agent_signed_at', d.agent_signed_at,
      'signers', (select jsonb_agg(jsonb_build_object('name', s.name, 'signed_at', s.signed_at) order by s.position)
                  from lease_signing_signers s where s.doc_id = d.id)) order by d.created_at desc)
    from lease_signing_docs d where d.agent_id = v_agent and d.status in ('awaiting_agent', 'signed')), '[]'::jsonb);
end;
$$;
revoke all on function lease_agent_queue() from public, anon;
grant execute on function lease_agent_queue() to authenticated;

create or replace function lease_agent_doc(p_doc uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_agent uuid := lease_agent_me(); d lease_signing_docs;
begin
  if v_agent is null then raise exception 'Agent two-step sign-in required' using errcode = '42501'; end if;
  select * into d from lease_signing_docs where id = p_doc and agent_id = v_agent;
  if d.id is null then raise exception 'Lease not found'; end if;
  return jsonb_build_object('id', d.id, 'unit_label', d.unit_label, 'title', d.title, 'status', d.status, 'html', d.html,
    'fingerprint', d.html_sha256, 'agent_signed_at', d.agent_signed_at,
    'signers', (select jsonb_agg(jsonb_build_object('name', s.name, 'email', s.email, 'signed_at', s.signed_at, 'typed_name', s.typed_name) order by s.position)
                from lease_signing_signers s where s.doc_id = d.id));
end;
$$;
revoke all on function lease_agent_doc(uuid) from public, anon;
grant execute on function lease_agent_doc(uuid) to authenticated;

-- Staff list now shows the agent and countersignature.
create or replace function lease_signing_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'unit_label', d.unit_label, 'title', d.title, 'status', d.status, 'created_at', d.created_at,
      'created_by', d.created_by, 'executed_at', d.executed_at, 'executed_pdf_path', d.executed_pdf_path,
      'application_id', d.application_id, 'agent_name', a.name, 'agent_signed_at', d.agent_signed_at,
      'signers', (select jsonb_agg(jsonb_build_object('name', s.name, 'email', s.email, 'sent_at', s.sent_at, 'viewed_at', s.viewed_at,
                   'verified_at', s.verified_at, 'signed_at', s.signed_at) order by s.position) from lease_signing_signers s where s.doc_id = d.id))
      order by d.created_at desc) from lease_signing_docs d left join lease_agents a on a.id = d.agent_id), '[]'::jsonb);
end;
$$;
