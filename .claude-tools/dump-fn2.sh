#!/bin/sh
# Writes the live definition of <schema>.<name> to .claude-tools/fn/<schema>.<name>.sql (read-only). Usage: dump-fn2.sh schema name
mkdir -p .claude-tools/fn
./.claude-tools/supa-query.sh "select string_agg(pg_get_functiondef(p.oid), chr(10)||chr(10)) d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = '$1' and p.proname = '$2'" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);require('fs').writeFileSync('.claude-tools/fn/$1.$2.sql',(j[0].d||'')+'\n');console.log('$1.$2',(j[0].d||'').length)})"
