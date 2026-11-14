#!/bin/sh
# Commits ONLY the given paths, through a private index, so another session's staged files in the shared index are never included.
# Each path's content comes from .claude-tools/stage/<path> when that file exists (to commit only part of a shared file), else the working tree.
# git commit runs normally (the pre-commit hook still runs). Afterwards the shared index entries for these paths are set to the new HEAD.
# Usage: sh .claude-tools/commit-private.sh <message-file> <path>...
set -eu
cd "$(dirname "$0")/.."
msg="$1"; shift
GIT_INDEX_FILE="$(pwd)/.claude-tools/private-index"; export GIT_INDEX_FILE
rm -f "$GIT_INDEX_FILE"
git read-tree HEAD
for p in "$@"; do
  src="$p"; [ -f ".claude-tools/stage/$p" ] && src=".claude-tools/stage/$p"
  git update-index --add --cacheinfo "100644,$(git hash-object -w "$src"),$p"
done
git diff --cached --stat HEAD | tail -1
git commit -q -F "$msg"
unset GIT_INDEX_FILE
rm -f .claude-tools/private-index
git reset -q HEAD -- "$@"
git log -1 --format=%h
