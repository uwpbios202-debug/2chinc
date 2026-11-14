#!/bin/sh
# Supabase CLI for the 2ndchinc project (hvnsgwfcjpakvhhkfsuy), always with the 2ndchinc login.
# The CLI's saved login on this computer is the SelassieFest account, which gets
# "403 ... necessary privileges" on 2ndchinc. This loads SUPABASE_ACCESS_TOKEN and
# SUPABASE_DB_PASSWORD from .env.supabase (gitignored) and runs the CLI from the repo root.
#   sh tools/sb.sh migration list --linked
#   sh tools/sb.sh db push
#   sh tools/sb.sh functions deploy <name> --project-ref hvnsgwfcjpakvhhkfsuy
set -e
cd "$(dirname "$0")/.."
[ -f .env.supabase ] || { echo "Missing .env.supabase (SUPABASE_ACCESS_TOKEN, SUPABASE_DB_PASSWORD)" >&2; exit 1; }
set -a; . ./.env.supabase; set +a
exec npx supabase "$@"
