#!/bin/sh
# Stage ONLY the T6.2 "My strengths" lines of site/mirror/my-mirror/index.html (HEAD + strengths block), leaving the peer's
# uncommitted needs block unstaged in the working copy.
set -eu
cd "$(dirname "$0")/.."
f=site/mirror/my-mirror/index.html
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
git show HEAD:"$f" | awk '
  { print }
  /href="\/mirror\/my-mirror\/life\/">Areas of life<\/a><\/p>/ {
    print "  <h2>My strengths</h2>"
    print "  <p class=\"mm-read\">Your skills, talents, experience, papers and training, languages, interests and the people in your corner. Your answers suggest some; you choose.</p>"
    print "  <p><a class=\"mm-btn mm-btn-secondary\" href=\"/mirror/my-mirror/my-strengths/\">My strengths</a></p>"
  }' > "$tmp"
blob="$(git hash-object -w "$tmp")"
git update-index --cacheinfo 100644,"$blob","$f"
git diff --cached --stat -- "$f"
git diff --cached -- "$f" | grep '^[+-][^+-]'
