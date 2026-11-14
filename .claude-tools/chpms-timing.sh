#!/bin/sh
# Times chpms_directory() and chpms_extras() separately as office staff (simulated claims; read-only). Prints wall time of each query.
S="with u as (select a.id, a.email from auth.users a where lower(a.email) in (select lower(email) from condo_staff) order by a.last_sign_in_at desc nulls last limit 1), s as (select set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'email', u.email, 'aal', 'aal2', 'role', 'authenticated')::text, true) x from u)"
t0=$(date +%s%N); ./.claude-tools/supa-query.sh "$S select length(chpms_directory()::text) n from s"; t1=$(date +%s%N)
echo "directory wall ms: $(( (t1 - t0) / 1000000 ))"
t0=$(date +%s%N); ./.claude-tools/supa-query.sh "$S select length(chpms_extras()::text) n from s"; t1=$(date +%s%N)
echo "extras wall ms: $(( (t1 - t0) / 1000000 ))"
t0=$(date +%s%N); ./.claude-tools/supa-query.sh "select 1 n"; t1=$(date +%s%N)
echo "baseline (select 1) wall ms: $(( (t1 - t0) / 1000000 ))"
