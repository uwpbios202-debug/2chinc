#!/usr/bin/env bash
# Read-only: print only the captcha fields of the project's Auth config (never the token or the secret).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
. ./.env.supabase
set +a
curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/hvnsgwfcjpakvhhkfsuy/config/auth" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(JSON.stringify({security_captcha_enabled:j.security_captcha_enabled,security_captcha_provider:j.security_captcha_provider,secret_set:!!j.security_captcha_secret,error:j.message||undefined}))})'
