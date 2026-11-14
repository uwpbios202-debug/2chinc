#!/bin/sh
# Adds the Guided Tour (D-28) note to DECISIONS, NEXT_ACTIONS and CLAUDE.md, and stages ONLY these lines
# (CLAUDE.md keeps Stephen's own uncommitted edit unstaged).
set -e
cd "$(dirname "$0")/.."
NOTE="$1"
ROW='| D-28 | **Guided Tour deferred** (Stephen 11/13/2026: "we are deferring the Guided Tour until all phases are done"). The Guided Tour = the real signed-in walk-through with Stephen: switch `mirror_signin_enabled` on, a real emailed-code sign-in, screens walked with real data on a computer, Android and iPhone, Speak / Read aloud in Chrome, Firefox and Edge, and a screen-reader (Narrator) pass. It waits until ALL phases (1-10) are built. Until then: do not ask Stephen for it, plan or schedule it, or let it hold up or block a task; a phase whose only gap is the tour is "built, Guided Tour pending (D-28)", not blocked. Read-only checks Claude runs alone (headless browsers, validators, rolled-back SQL checks) continue. Covers P5-01, the Phase 4 step 5 walk-through and Phase 1 open items 1-4 (devices, screen reader, Edge by hand, real sign-in). |'
grep -q "^| D-28 " docs/human-mirror/DECISIONS.md && echo "D-28 already exists: stop" && exit 1
awk -v row="$ROW" '{print} /^\| D-27 /{print row}' docs/human-mirror/DECISIONS.md > docs/human-mirror/DECISIONS.md.tmp && mv docs/human-mirror/DECISIONS.md.tmp docs/human-mirror/DECISIONS.md
awk 'NR==1{print; print ""; print "0. **Guided Tour deferred until all phases are done (D-28, Stephen 11/13/2026).** The real signed-in walk-through (switch on, real code"; print "   sign-in, phones, Firefox/Edge voice, screen reader) is not asked for, scheduled or waited on until Phases 1-10 are built. Keep building."; next} {print}' docs/human-mirror/NEXT_ACTIONS.md > docs/human-mirror/NEXT_ACTIONS.md.tmp && mv docs/human-mirror/NEXT_ACTIONS.md.tmp docs/human-mirror/NEXT_ACTIONS.md
# CLAUDE.md: stage HEAD + note (not Stephen's edit), then append the note to the working file too.
git show HEAD:CLAUDE.md > "$NOTE.head"
cat "$NOTE" >> "$NOTE.head"
blob=$(git hash-object -w "$NOTE.head")
git update-index --cacheinfo 100644,"$blob",CLAUDE.md
cat "$NOTE" >> CLAUDE.md
git add docs/human-mirror/DECISIONS.md docs/human-mirror/NEXT_ACTIONS.md
git diff --cached --stat
echo "== unstaged left in CLAUDE.md (should be only Stephen's section):"
git diff --stat CLAUDE.md
