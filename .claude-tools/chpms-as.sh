#!/bin/sh
# Read-only: call chpms_directory() as one kind of user via simulated claims (no session id = treated as a "view as" session, so nothing can be written).
# Usage: ./.claude-tools/chpms-as.sh <staff|field|navigator|resident|owner> [aal1|aal2]
who="$1"; aal="${2:-aal2}"
case "$who" in
  staff) src="select lower(email) e from condo_staff" ;;
  field) src="select lower(email) e from field_staff where active and lower(email) not in (select lower(email) from condo_staff)" ;;
  navigator) src="select lower(email) e from navigators where status in ('preview','pilot','active')" ;;
  resident) src="select lower(t.email) e from tenants t where t.email is not null and lower(t.email) not in (select lower(email) from condo_staff union select lower(email) from field_staff where active union select lower(email) from navigators)" ;;
  owner) src="select lower(o.email) e from condo_owners o where o.email is not null and lower(o.email) not in (select lower(email) from condo_staff union select lower(email) from navigators)" ;;
  *) echo "unknown"; exit 2 ;;
esac
./.claude-tools/supa-query.sh "with u as (select a.id, a.email from auth.users a where lower(a.email) in ($src) order by a.last_sign_in_at desc nulls last limit 1), s as (select set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'email', u.email, 'aal', '$aal', 'role', 'authenticated')::text, true) x from u), d as (select chpms_directory() j from s) select '$who' as asked, (select count(*) from u) user_found, j->>'role' role, j->>'can_edit' can_edit, j->>'can_act' can_act, j->>'view_as' view_as, jsonb_array_length(j->'orgs') orgs, (select sum(jsonb_array_length(o->'programs')) from jsonb_array_elements(j->'orgs') o) programs, (select count(*) from jsonb_object_keys(j->'sources')) sources, jsonb_array_length(j->'my_people') my_people, j->>'version' version from d"
