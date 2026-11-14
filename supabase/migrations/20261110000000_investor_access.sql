-- Investor research desk sign-in (Stephen, 10/10/2026). An investor signs in with an emailed code, like everyone else,
-- and sees ONLY the research desk at /investor/ and their own saved deals. No tenant, owner, ledger or staff data.
--
-- An investor can sign in only when a row is in `investors` with active = true. THE ROWS (real emails) ARE NOT IN THIS FILE:
-- they live in the local-only seed supabase/migrations/20261110010000_investor_emails.sql (gitignored, see CLAUDE.md).
-- To add one later (SQL editor):
--   insert into investors (email, name) values ('someone@example.com', 'Their Name');

create table if not exists investors (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  name text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists investors_email_key on investors (lower(email));
alter table investors enable row level security;   -- no policies: only the security-definer functions below read it

create or replace function investor_is_me()
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from investors where active and lower(email) = lower(auth.email()));
$$;
revoke all on function investor_is_me() from public, anon;
grant execute on function investor_is_me() to authenticated;

-- One row per saved deal, private to the signed-in investor.
create table if not exists investor_deals (
  user_id uuid not null references auth.users(id) on delete cascade,
  id text not null,
  pin text,
  data jsonb not null,
  updated timestamptz not null default now(),
  primary key (user_id, id)
);
alter table investor_deals enable row level security;
create policy "own deals select" on investor_deals for select using (auth.uid() = user_id and investor_is_me());
create policy "own deals insert" on investor_deals for insert with check (auth.uid() = user_id and investor_is_me());
create policy "own deals update" on investor_deals for update using (auth.uid() = user_id and investor_is_me()) with check (auth.uid() = user_id and investor_is_me());
create policy "own deals delete" on investor_deals for delete using (auth.uid() = user_id and investor_is_me());

-- The sign-in email goes only to people on file; investors are now on file.
create or replace function condo_email_on_file(p_email text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email))
      or exists (select 1 from lease_agents where active and lower(email) = lower(p_email))
      or exists (select 1 from resident_tenant_ids(p_email))
      or exists (select 1 from field_staff where active and lower(email) = lower(p_email))
      or exists (select 1 from contractor_vendor_ids(p_email))
      or exists (select 1 from investors where active and lower(email) = lower(p_email));
$$;
revoke all on function condo_email_on_file(text) from public, anon, authenticated;
grant execute on function condo_email_on_file(text) to service_role;

-- Same as before, plus 'investor' as the last role (anyone who is also staff, owner, etc. keeps their existing role).
create or replace function condo_whoami()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_agent uuid := (select id from lease_agents where active and lower(email) = lower(auth.email()));
  v_resident boolean := exists (select 1 from resident_tenant_ids(auth.email()));
  v_field boolean := field_is_staff();
  v_contractor boolean := exists (select 1 from contractor_vendor_ids(auth.email()));
  v_investor boolean := investor_is_me();
  v_phone text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  v_phone := condo_mfa_phone_for(auth.email());
  if not (v_staff or v_owner is not null or v_agent is not null or v_resident or v_field or v_contractor or v_investor) then
    return jsonb_build_object('role', 'none');
  end if;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' when v_agent is not null then 'agent' when v_resident then 'resident'
                 when v_field then 'field' when v_contractor then 'contractor' else 'investor' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'is_resident', v_resident,
    'is_field', v_field,
    'is_contractor', v_contractor,
    'is_investor', v_investor,
    'mfa_required', mfa_required(),
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$$;
