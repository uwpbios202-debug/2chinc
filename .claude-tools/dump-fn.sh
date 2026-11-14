#!/bin/sh
# Writes the live definition of public.<name> to .claude-tools/fn/<name>.sql (read-only).
mkdir -p .claude-tools/fn
./.claude-tools/supa-query.sh "select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = '$1'" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);require('fs').writeFileSync('.claude-tools/fn/$1.sql',j[0].d+';\n');console.log('$1',j.length)})"
