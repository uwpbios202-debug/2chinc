#!/bin/sh
# Like mirror-rollback-check.sh, but for checks written before Phase 2 fix 5 (session_fresh): every made-up session id in the check
# ("'session_id', gen_random_uuid()") is replaced by pg_temp.chk_session(), which creates a fictional auth user + fresh auth session
# inside the same transaction. Everything still ends in the MIRROR CHECK RESULTS error, so all of it is rolled back.
# Usage: sh ./.claude-tools/mirror-rollback-check-sessions.sh <migration.sql> <check.sql>
set -eu
cd "$(dirname "$0")/.."
mig="$1"; chk="$2"
tail -c 400 "$chk" | grep -q "raise exception 'MIRROR CHECK RESULTS" || { echo "Refusing: the check file must end with the MIRROR CHECK RESULTS raise" >&2; exit 2; }
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
cat > "$tmpd/pre.sql" <<'SQL'
create function pg_temp.chk_session() returns uuid language plpgsql security definer set search_path = public as $f$
declare u uuid := gen_random_uuid(); s uuid := gen_random_uuid();
begin
  insert into auth.users (id) values (u);
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values (s, u, now(), now(), now());
  return s;
end $f$;
grant execute on function pg_temp.chk_session() to authenticated;
SQL
sed "s/'session_id', gen_random_uuid()/'session_id', pg_temp.chk_session()/g" "$chk" > "$tmpd/check.sql"
cat "$tmpd/pre.sql" "$tmpd/check.sql" > "$tmpd/check2.sql"
sh ./.claude-tools/mirror-rollback-check.sh "$mig" "$tmpd/check2.sql"
