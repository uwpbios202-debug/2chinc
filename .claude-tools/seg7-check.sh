#!/bin/sh
# Read-only bug check, segment 7 (sign-in, sessions and security). Counts and statuses only.
cd "$(dirname "$0")/.."
Q=./.claude-tools/supa-query.sh
echo "refusal channel:"; $Q "select mirror.refusal_channel_ok() as r"
echo "mirror_link usage (anon, authenticated, service_role):"; $Q "select has_schema_privilege('anon','mirror_link','USAGE') a, has_schema_privilege('authenticated','mirror_link','USAGE') b, has_schema_privilege('service_role','mirror_link','USAGE') c"
echo "refusal writer role:"; $Q "select rolconnlimit, rolinherit from pg_roles where rolname='mirror_refusal_writer'"
echo "auth sessions:"; $Q "select count(*) n, min(created_at)::date oldest from auth.sessions"
echo "session settings present:"; $Q "select count(*) filter (where key like 'session_idle_days_%') idle, count(*) filter (where key like 'session_max_days_%') maxd, count(*) filter (where key='step_up_minutes') stepup from public.portal_settings"
echo "step_up_codes:"; $Q "select count(*) n, count(*) filter (where attempts >= 3) many_attempts, min(created_at)::date oldest from public.step_up_codes"
echo "auth users total / audit log rows:"; $Q "select (select count(*) from auth.users) users, (select count(*) from auth.audit_log_entries) audit_rows"
echo "mirror sign-in switch and platform admins:"; $Q "select (select value from public.portal_settings where key='mirror_signin_enabled') switch, (select count(*) from mirror.platform_admins where active) platform_admins"
echo "storage policies reading a table authenticated cannot select:"; $Q "select count(*) bad from pg_policies p, lateral (select (regexp_matches(coalesce(p.qual,'') || ' ' || coalesce(p.with_check,''), 'FROM ([a-z_]+\.[a-z_]+)', 'gi'))[1] t) x where p.schemaname='storage' and p.tablename='objects' and not has_table_privilege('authenticated', x.t, 'SELECT')"
echo "anon-executable public functions:"; $Q "select count(*) n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('anon', p.oid, 'EXECUTE') and p.prosecdef"
echo "pages:"
echo "  sign-in $(curl -s -o /dev/null -w '%{http_code}' https://2ndchinc.org/sign-in/)  mirror sign-in $(curl -s -o /dev/null -w '%{http_code}' https://2ndchinc.org/mirror/sign-in/)  mirror admin $(curl -s -o /dev/null -w '%{http_code}' https://2ndchinc.org/mirror/admin/)"
echo "headers on home page:"; curl -sI https://2ndchinc.org/ | grep -i -c "strict-transport-security\|x-frame-options\|frame-ancestors\|permissions-policy"
echo "captcha:"; sh ./.claude-tools/auth-captcha-read.sh 2>&1 | grep -i "captcha" | head -3
