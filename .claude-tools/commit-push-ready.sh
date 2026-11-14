#!/bin/sh
# Commit and push every TRACKED change that is ready, and nothing that is held back.
#   Dry run (default):  ./.claude-tools/commit-push-ready.sh "message"
#   Commit and push:    ./.claude-tools/commit-push-ready.sh "message" --yes
# Never staged: untracked files, .gitignore'd files (local-only, .env*, data/, incoming/, files/),
# files marked skip-worktree (held for Stephen's OK, e.g. the Daily Number calculator fixes),
# .claude-tools/ (held work such as sequestered-E), and the HELD list below.
# Never force-pushes. Stops if main cannot fast-forward to origin/main.
set -e
cd "$(dirname "$0")/.."

HELD="supabase/functions/rental-apply/index.ts"

msg="$1"
if [ -z "$msg" ]; then
  echo "Usage: $0 \"commit message\" [--yes]"
  exit 1
fi

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" != "main" ]; then
  echo "STOP: on branch $branch, expected main."
  exit 1
fi

if ! git diff --cached --quiet; then
  echo "STOP: something is already staged (maybe another session's). Staged now:"
  git diff --cached --name-only
  exit 1
fi

git fetch -q origin
behind=$(git rev-list --count HEAD..origin/main)
if [ "$behind" -gt 0 ]; then
  echo "origin/main is $behind commit(s) ahead; fast-forwarding first."
  git merge --ff-only origin/main
fi

ready=""
for f in $(git diff --name-only | tr ' ' '?'); do
  skip=no
  for h in $HELD; do
    [ "$f" = "$h" ] && skip=yes
  done
  case "$f" in
    .env*|*/.env*|LOCAL-ONLY*|data/*|incoming/*|files/*|.claude-tools/*) skip=yes ;;
  esac
  if [ "$skip" = yes ]; then
    echo "  held:  $f"
  else
    echo "  ready: $f"
    ready="$ready $f"
  fi
done
echo "  skip-worktree (held for Stephen's OK):"
git ls-files -v | grep '^S ' | sed 's/^S /    /' || true

if [ -z "$ready" ]; then
  echo "Nothing ready to commit."
  ahead=$(git rev-list --count origin/main..HEAD)
  if [ "$ahead" -gt 0 ] && [ "$2" = "--yes" ]; then
    git push origin main
  fi
  exit 0
fi

if [ "$2" != "--yes" ]; then
  echo "Dry run only. Add --yes to commit and push the 'ready' files."
  exit 0
fi

for f in $ready; do
  git add -- "$(echo "$f" | tr '?' ' ')"
done
git diff --cached --stat
git commit -q -m "$msg" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q origin main
echo "Committed and pushed: $(git log -1 --format='%h %s')"
git status -sb | head -1
