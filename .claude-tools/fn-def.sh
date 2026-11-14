#!/bin/sh
# Prints the live definition of public functions by name (read-only).
./.claude-tools/supa-query.sh "select string_agg(pg_get_functiondef(p.oid), E'\n-----\n') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = '$1'" | sed 's/\n/\n/g; s/\\"/"/g'
