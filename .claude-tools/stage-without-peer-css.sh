#!/bin/sh
# Stage site/mirror/my-mirror/settings/index.html WITHOUT the peer session's uncommitted mirror.css version bump.
# The working copy keeps both changes. Usage: sh ./.claude-tools/stage-without-peer-css.sh <peer_ver> <head_ver> <tmpfile>
set -e
F=site/mirror/my-mirror/settings/index.html
sed "s#mirror.css?v=$1#mirror.css?v=$2#" "$F" > "$3"
echo "--- diff of what will be staged vs HEAD:"
git show "HEAD:$F" | diff - "$3" || true
H=$(git hash-object -w "$3")
git update-index --cacheinfo 100644,"$H","$F"
echo "staged $H"
