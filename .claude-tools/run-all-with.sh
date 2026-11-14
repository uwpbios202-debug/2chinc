#!/bin/sh
# Runs every Mirror check (list in .claude-tools/allchecks.txt) strictly with the given migration, rolled back.
cd "$(dirname "$0")/.."
sh ./.claude-tools/run-all-checks-strict.sh "$1" $(cat .claude-tools/allchecks.txt)
