#!/usr/bin/env bash
# Read-only: downloads one object from Supabase Storage to a local file. Never prints keys.
# Usage: ./.claude-tools/get-storage-file.sh <bucket> <object-path> <out-file>
set -euo pipefail
cd "$(dirname "$0")/.."
REF=hvnsgwfcjpakvhhkfsuy
TOKEN="$(grep '^SUPABASE_ACCESS_TOKEN=' .env.supabase | cut -d= -f2- | tr -d '\r"')"
KEY="$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.supabase.com/v1/projects/$REF/api-keys?reveal=true" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const k=JSON.parse(s).find(x=>x.name==="service_role");process.stdout.write(k?k.api_key:"")})')"
[ -n "$KEY" ] || { echo "ERROR: could not get the service key" >&2; exit 1; }
code="$(curl -s -o "$3" -w '%{http_code}' -H "Authorization: Bearer $KEY" -H "apikey: $KEY" "https://$REF.supabase.co/storage/v1/object/$1/$2")"
echo "HTTP $code -> $3 ($(wc -c < "$3") bytes)"
