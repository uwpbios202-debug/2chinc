#!/bin/sh
# Like commit-private.sh but ALWAYS takes each path from the working tree (ignores .claude-tools/stage/).
# Commits ONLY the given paths through a private index; afterwards the shared index entries for them are set to the new HEAD.
# Usage: sh .claude-tools/commit-worktree-private.sh <message-file> <path>...
set -eu
cd "$(dirname "$0")/.."
msg="$1"; shift
GIT_INDEX_FILE="$(pwd)/.claude-tools/private-index-wt"; export GIT_INDEX_FILE
rm -f "$GIT_INDEX_FILE"
git read-tree HEAD
git add -- "$@"
git commit -q -F "$msg"
rm -f "$GIT_INDEX_FILE"
unset GIT_INDEX_FILE
git reset -q HEAD -- "$@"
git log --oneline -1
