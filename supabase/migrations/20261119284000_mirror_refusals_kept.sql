-- The Human Mirror, P3-11 (Stephen 11/13/2026, option "Separate write"): refused attempts were never kept in the log.
-- mirror.allowed() logged 'refused', then the caller raised an error, which undid the log row in the same transaction. So
-- "Who looked" could never show "tried to open (not allowed)" for refusals that end in an error (18 functions, Phases 3-5).
-- Now a refusal is written through a SECOND database connection (dblink), which commits on its own:
--  * Login role mirror_refusal_writer: no inherit, connection limit 3, statement timeout 3 s. Its password is made inside the
--    database here and stored only in Supabase Vault (secret mirror_refusal_writer_password); it is never in git, logs or chat.
--    The role can do one thing: call mirror.audit_refusal_write(), which adds a 'refused' row for a person who exists, with one
--    of the three refusal reasons (view_as, no_authenticator, no_consent). It cannot read anything.
--  * mirror.audit_refused() (called by mirror.allowed in place of its three 'refused' log calls) tries the second connection
--    (localhost, then 127.0.0.1). If that fails, or the person does not exist outside this transaction (a made-up person in a
--    rolled-back check), it logs in this transaction as before. So nothing breaks, and a refusal is never logged twice.
--  * mirror.allowed: the live body of 11/13 (with the Phase 2 fix 5 session check) unchanged except those three calls.
--  * dblink functions: execute taken away from anon and authenticated (the extensions schema is not on the Data API either).
-- No table is created, so no new table grants are needed (CLAUDE.md, 10/30/2026 rule).

create extension if not exists dblink with schema extensions;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'extensions' and p.proname like 'dblink%' loop
    begin
      execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    exception when insufficient_privilege then null;   -- dblink_connect_u and the like: owned by the superuser, already closed
    end;
  end loop;
end $$;

do $$
declare pw text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if not exists (select 1 from pg_roles where rolname = 'mirror_refusal_writer') then
    execute format('create role mirror_refusal_writer login noinherit nocreatedb nocreaterole connection limit 3 password %L', pw);
    perform vault.create_secret(pw, 'mirror_refusal_writer_password', 'Human Mirror P3-11: sign-in that only adds refused rows to mirror.audit_logs. Never copy out.');
  end if;
end $$;
alter role mirror_refusal_writer set statement_timeout = '3s';
grant usage on schema mirror to mirror_refusal_writer;

-- Runs in the second connection, as the writer role. Adds one 'refused' row; returns false (adds nothing) when the person does not
-- exist there or the reason is not a refusal reason.
create or replace function mirror.audit_refusal_write(p_actor text, p_individual uuid, p_org uuid, p_role text, p_category text,
  p_table text, p_row text, p_reason text) returns boolean
language plpgsql security definer set search_path = mirror, public as $f$
begin
  if p_individual is null or not exists (select 1 from mirror.individuals where id = p_individual) then return false; end if;
  if p_reason is null or p_reason not in ('view_as', 'no_authenticator', 'no_consent') then return false; end if;
  insert into mirror.audit_logs (actor_email, actor_role, organization_id, individual_id, action, category, table_name, row_id, reason)
  values (lower(p_actor), p_role, p_org, p_individual, 'refused', p_category, p_table, p_row, p_reason);
  return true;
end $f$;
revoke all on function mirror.audit_refusal_write(text, uuid, uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function mirror.audit_refusal_write(text, uuid, uuid, text, text, text, text, text) to mirror_refusal_writer;

-- Called by mirror.allowed for a refusal: second connection first, this transaction as the fallback.
create or replace function mirror.audit_refused(p_individual uuid, p_org uuid, p_role text, p_category text, p_table text,
  p_row text, p_reason text) returns void
language plpgsql security definer set search_path = mirror, public, extensions as $f$
declare pw text; h text; ok boolean := false; q text;
begin
  select decrypted_secret into pw from vault.decrypted_secrets where name = 'mirror_refusal_writer_password';
  if pw is not null then
    q := format('select mirror.audit_refusal_write(%L, %L::uuid, %L::uuid, %L, %L, %L, %L, %L)',
                lower(auth.email()), p_individual, p_org, p_role, p_category, p_table, p_row, p_reason);
    foreach h in array array['localhost', '127.0.0.1'] loop
      begin
        select t.x into ok from extensions.dblink(
          format('host=%s port=5432 dbname=postgres user=mirror_refusal_writer password=%s connect_timeout=2 application_name=mirror_refusal', h, pw),
          q) as t(x boolean);
        exit;
      exception when others then ok := false;
      end;
    end loop;
  end if;
  if not coalesce(ok, false) then
    perform mirror.audit(p_individual, p_org, p_role, 'refused', p_category, p_table, p_row, p_reason);
  end if;
end $f$;
revoke all on function mirror.audit_refused(uuid, uuid, text, text, text, text, text) from public, anon, authenticated;

-- Is the second connection working? Opens it and runs "select 1", nothing else (for the bug check; service_role only).
create or replace function mirror.refusal_channel_ok() returns text
language plpgsql security definer set search_path = mirror, public, extensions as $f$
declare pw text; h text; r int; err text := '';
begin
  select decrypted_secret into pw from vault.decrypted_secrets where name = 'mirror_refusal_writer_password';
  if pw is null then return 'no secret'; end if;
  foreach h in array array['localhost', '127.0.0.1'] loop
    begin
      select t.x into r from extensions.dblink(
        format('host=%s port=5432 dbname=postgres user=mirror_refusal_writer password=%s connect_timeout=2 application_name=mirror_refusal', h, pw),
        'select 1') as t(x int);
      return 'ok via ' || h;
    exception when others then err := err || h || ': ' || replace(sqlerrm, pw, '***') || '; ';
    end;
  end loop;
  return 'failed: ' || err;
end $f$;
revoke all on function mirror.refusal_channel_ok() from public, anon, authenticated;
grant execute on function mirror.refusal_channel_ok() to service_role;

-- mirror.allowed: live body, the three refusal log calls now go through mirror.audit_refused.
CREATE OR REPLACE FUNCTION mirror.allowed(p_individual uuid, p_category text, p_action text, p_org uuid DEFAULT NULL::uuid, p_table text DEFAULT NULL::text, p_row text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'mirror', 'public'
AS $gate$
declare
  v_email text := lower(auth.email());
  v_sensitive boolean := p_category not in ('general', 'safety_flag', 'organization', 'audit');
  v_member boolean := false;
  v_org uuid;
  v_role text;
  v_probe boolean := p_table is not distinct from '_probe';   -- quiet: a permission probe, never logged
  m record;
  p mirror.role_permissions;
begin
  if v_email is null then
    return jsonb_build_object('ok', false, 'reason', 'Sign-in required.');
  end if;
  if not coalesce(public.session_fresh(), false) then
    return jsonb_build_object('ok', false, 'reason', 'Your sign-in on this device has expired. Please sign in again.');
  end if;
  if public.autopay_view_as_session() then
    if not v_probe then perform mirror.audit_refused(p_individual, p_org, 'view_as', p_category, p_table, p_row, 'view_as'); end if;
    return jsonb_build_object('ok', false, 'reason', 'Not available while viewing as someone else.');
  end if;

  -- the person themself
  if exists (select 1 from mirror.individuals i where i.id = p_individual and i.auth_email = v_email) then
    select * into p from mirror.role_permissions where role = 'self' and category = p_category and action = p_action;
    if found then return jsonb_build_object('ok', true, 'role', 'self'); end if;
    return jsonb_build_object('ok', false, 'role', 'self', 'reason', 'Not allowed.');
  end if;

  -- a member of an organization that works with the person (active link only)
  for m in
    select om.role, om.organization_id
    from mirror.organization_members om
    join mirror.organizations o on o.id = om.organization_id and o.active
    join mirror.organization_individuals oi on oi.organization_id = om.organization_id and oi.individual_id = p_individual and oi.status = 'active'
    where om.auth_email = v_email and om.active and (p_org is null or om.organization_id = p_org)
    order by case om.role when 'org_admin' then 1 when 'coordinator' then 2 else 3 end
  loop
    v_member := true;
    if v_org is null then v_org := m.organization_id; v_role := m.role; end if;
    if coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
      if not v_probe then perform mirror.audit_refused(p_individual, m.organization_id, m.role, p_category, p_table, p_row, 'no_authenticator'); end if;
      return jsonb_build_object('ok', false, 'role', m.role, 'reason', 'Enter your authenticator code first.');
    end if;
    select * into p from mirror.role_permissions where role = m.role and category = p_category and action = p_action;
    continue when not found;
    if p.needs_consent and not exists (
         select 1 from mirror.consents c
         where c.individual_id = p_individual and c.organization_id = m.organization_id and c.category = p_category
           and c.revoked_at is null and (c.expires_on is null or c.expires_on >= current_date)
           and (p_action = 'view' or c.access = 'edit')) then
      continue;
    end if;
    if v_sensitive or p_action = 'edit' then
      if not v_probe then perform mirror.audit(p_individual, m.organization_id, m.role, p_action, p_category, p_table, p_row, null); end if;
    end if;
    return jsonb_build_object('ok', true, 'role', m.role, 'organization_id', m.organization_id);
  end loop;

  if v_member then
    if v_sensitive or p_action = 'edit' then
      if not v_probe then perform mirror.audit_refused(p_individual, v_org, v_role, p_category, p_table, p_row, 'no_consent'); end if;
    end if;
    return jsonb_build_object('ok', false, 'reason', 'The person has not shared this with your organization.');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'Not allowed.');
end $gate$
;
