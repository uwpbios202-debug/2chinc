-- The Human Mirror, P3-11 follow-up to 20261119284000 (Stephen 11/13/2026: "Try pooler, else undo").
-- 284000's second connection went to localhost, which lets connections in without a password; dblink refuses that for a
-- non-superuser, so every refusal took the fallback. A rolled-back try on 11/13 connected through the Supabase pooler
-- (aws-0-ca-central-1.pooler.supabase.com; port 6543 in 40 ms, port 5432 in 190 ms), which always asks for the password.
--  1. mirror.audit_refused() and mirror.refusal_channel_ok() connect through the pooler, transaction mode (port 6543), TLS
--     required, 3-second connect limit, sign-in mirror_refusal_writer.<project>. Fallback unchanged: if the second
--     connection fails or adds nothing, the refusal is logged in this transaction as before. A refusal is never logged twice.
--  2. dblink moves to a private schema, mirror_link, that only postgres can use. Its functions belong to the Supabase superuser
--     and stay executable by PUBLIC, so in the shared "extensions" schema anon and authenticated could call them; without
--     USAGE on mirror_link they cannot. (Nothing used dblink before 284000.)
-- The writer sign-in, its Vault secret and mirror.audit_refusal_write() are unchanged from 284000.
-- No table is created, so no new table grants are needed (CLAUDE.md, 10/30/2026 rule).

-- ---------------------------------------------------------------- 2 dblink into a private schema
create schema if not exists mirror_link;
revoke all on schema mirror_link from public, anon, authenticated, service_role;
drop extension if exists dblink;
create extension dblink with schema mirror_link;

-- ---------------------------------------------------------------- 1 the second connection goes through the pooler
create or replace function mirror.refusal_conninfo(p_pw text) returns text language sql immutable as $f$
  select format('host=aws-0-ca-central-1.pooler.supabase.com port=6543 dbname=postgres user=mirror_refusal_writer.hvnsgwfcjpakvhhkfsuy password=%s sslmode=require connect_timeout=3 application_name=mirror_refusal', p_pw)
$f$;
revoke all on function mirror.refusal_conninfo(text) from public, anon, authenticated;

create or replace function mirror.audit_refused(p_individual uuid, p_org uuid, p_role text, p_category text, p_table text,
  p_row text, p_reason text) returns void
language plpgsql security definer set search_path = mirror, public, mirror_link as $f$
declare pw text; ok boolean := false; q text;
begin
  select decrypted_secret into pw from vault.decrypted_secrets where name = 'mirror_refusal_writer_password';
  if pw is not null then
    q := format('select mirror.audit_refusal_write(%L, %L::uuid, %L::uuid, %L, %L, %L, %L, %L)',
                lower(auth.email()), p_individual, p_org, p_role, p_category, p_table, p_row, p_reason);
    begin
      select t.x into ok from mirror_link.dblink(mirror.refusal_conninfo(pw), q) as t(x boolean);
    exception when others then ok := false;
    end;
  end if;
  if not coalesce(ok, false) then
    perform mirror.audit(p_individual, p_org, p_role, 'refused', p_category, p_table, p_row, p_reason);
  end if;
end $f$;
revoke all on function mirror.audit_refused(uuid, uuid, text, text, text, text, text) from public, anon, authenticated;

-- Is the second connection working? Opens it and runs "select 1", nothing else (for the bug check; service_role only).
create or replace function mirror.refusal_channel_ok() returns text
language plpgsql security definer set search_path = mirror, public, mirror_link as $f$
declare pw text; r int;
begin
  select decrypted_secret into pw from vault.decrypted_secrets where name = 'mirror_refusal_writer_password';
  if pw is null then return 'no secret'; end if;
  select t.x into r from mirror_link.dblink(mirror.refusal_conninfo(pw), 'select 1') as t(x int);
  return 'ok';
exception when others then return 'failed: ' || replace(sqlerrm, coalesce(pw, ''), '***');
end $f$;
revoke all on function mirror.refusal_channel_ok() from public, anon, authenticated;
grant execute on function mirror.refusal_channel_ok() to service_role;
