#!/bin/sh
# Read-only: chpms_directory() orgs as office staff (simulated claims), saved to the file given as $1.
./.claude-tools/supa-query.sh "with u as (select a.id, a.email from auth.users a where lower(a.email) in (select lower(email) from condo_staff) order by a.last_sign_in_at desc nulls last limit 1), s as (select set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'email', u.email, 'aal', 'aal2', 'role', 'authenticated')::text, true) x from u) select jsonb_build_object('orgs', chpms_directory()->'orgs') d from s" > "$1"
