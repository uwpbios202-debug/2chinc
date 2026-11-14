#!/bin/sh
# Deploys the LAST COMMIT of this repo, never the working folder, so unfinished edits cannot go live.
#   sh tools/deploy.sh site     build from HEAD (INCLUDE_APPLY=1) and publish to Cloudflare Pages (project 2ndchinc)
#   sh tools/deploy.sh db       supabase db push (applies committed migrations in supabase/migrations); extra flags pass through, e.g. db --yes
#   sh tools/deploy.sh all      db, then site
# Local-only files (see .gitignore and CLAUDE.md) are not in a commit, so they are never published.
# Functions are deployed separately: sh tools/sb.sh functions deploy <name> --project-ref hvnsgwfcjpakvhhkfsuy
set -e
cd "$(dirname "$0")/.."
what="${1:-site}"

deploy_db() { sh tools/sb.sh db push --remote "$@"; }

deploy_site() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  git archive HEAD build.sh site templates/lease-agreement | tar -x -C "$tmp"
  (cd "$tmp" && INCLUDE_APPLY=1 sh build.sh >/dev/null)
  [ -f "$tmp/dist/index.html" ] || { echo "Build failed: no dist/index.html" >&2; exit 1; }
  [ ! -f "$tmp/dist/wrangler-account.json" ] || { echo "Refusing: wrangler-account.json in the build" >&2; exit 1; }
  npx wrangler pages deploy "$tmp/dist" --project-name 2ndchinc --branch main --commit-dirty=true
}

case "$what" in
  site) deploy_site ;;
  db) shift; deploy_db "$@" ;;
  all) deploy_db; deploy_site ;;
  *) echo "Usage: sh tools/deploy.sh site|db|all" >&2; exit 2 ;;
esac
