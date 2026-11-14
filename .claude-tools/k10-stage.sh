#!/bin/sh
# K-10: apply the edit to the working Settings page AND to the committed copy, then stage only the committed copy + edit
# (keeps the other session's uncommitted "needs" lines out of the commit).
set -e
F=site/mirror/my-mirror/settings/index.html
T=/c/Users/mkepr/AppData/Local/Temp/claude/9595fc9777f5ef61/c94aeaff-31ff-48c1-90d5-23878956dae6/scratchpad/settings-head.html
node .claude-tools/k10-edit.mjs "$F"
git show "HEAD:$F" > "$T"
node .claude-tools/k10-edit.mjs "$T"
H=$(git hash-object -w "$T")
git update-index --cacheinfo "100644,$H,$F"
echo "staged:"
git diff --cached --stat
echo "left unstaged (other session):"
git diff --stat -- "$F"
