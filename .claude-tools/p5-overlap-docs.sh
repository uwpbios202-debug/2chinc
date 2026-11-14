#!/bin/sh
# Phase 5 follow-up (P5-03 / P5-04 / P5-01) doc edits. DECISIONS.md and SITEMAP.md carry another session's uncommitted
# lines, so for those two the same edit is applied to both the working file and a HEAD copy, and only the HEAD copy is staged.
set -eu
cd "$(dirname "$0")/.."
D=docs/human-mirror
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# --- D-26 confirmed
D26_OLD='| DEFAULT 11/13/2026 (Stephen to confirm, P5-04) |'
D26_NEW='| DECIDED 11/13/2026 (Stephen confirmed the 11 areas) |'
git show HEAD:$D/DECISIONS.md > "$T/dec"
grep -qF "$D26_OLD" "$T/dec"
sed -i "s/| DEFAULT 11\/13\/2026 (Stephen to confirm, P5-04) |/| DECIDED 11\/13\/2026 (Stephen confirmed the 11 areas) |/" "$T/dec" $D/DECISIONS.md
grep -qF "$D26_NEW" "$T/dec"
grep -qF "$D26_NEW" $D/DECISIONS.md

# --- Sitemap: abilities/ row
S_OLD='| abilities/ | 6 FUNCTION: What can I do, where might I want support? (the light reflection; links to the two pages below) | 3 |'
S_NEW='| abilities/ | 6 FUNCTION: paperwork, appointments and where a little help would make life easier (3 questions; the 9 everyday-task questions moved to activities/ below, P5-03); links to the two pages below | 3 / 5 |'
git show HEAD:$D/SITEMAP.md > "$T/site"
grep -qF "$S_OLD" "$T/site"
grep -qF "$S_OLD" $D/SITEMAP.md
node -e "const fs=require('fs');for(const f of process.argv.slice(3)){fs.writeFileSync(f,fs.readFileSync(f,'utf8').split(process.argv[1]).join(process.argv[2]))}" "$S_OLD" "$S_NEW" "$T/site" $D/SITEMAP.md
grep -qF "$S_NEW" "$T/site"

# stage the HEAD-based copies only
git update-index --cacheinfo 100644,"$(git hash-object -w "$T/dec")",$D/DECISIONS.md
git update-index --cacheinfo 100644,"$(git hash-object -w "$T/site")",$D/SITEMAP.md

# --- KNOWN_ISSUES
node -e "
const fs=require('fs');const f='$D/KNOWN_ISSUES.md';let s=fs.readFileSync(f,'utf8');
const rep=(a,b)=>{if(!s.includes(a))throw new Error('missing: '+a.slice(0,40));s=s.replace(a,b)};
rep(/\| P5-01 \|(.*)\| Open \|/.exec(s)[0], '| P5-01 |'+/\| P5-01 \|(.*)\| Open \|/.exec(s)[1]+'| Deferred (Stephen 11/13/2026: leave the walk-through for now) |');
rep(/\| P5-03 \|.*\| Open \|/.exec(s)[0], '| P5-03 | The Phase 3 Function reflection (12 light questions) and the Phase 5 everyday activities overlapped (meals, shopping, medicine...). Stephen 11/13/2026: remove the overlap. Migration 20261119303000 retires the 9 overlapping questions (active false, never deleted; no one had answered them); the reflection keeps paperwork, appointments and the open question. | Fixed 11/13/2026 |');
rep(/\| P5-04 \|.*\| Open \|/.exec(s)[0], '| P5-04 | D-26: the list of the 11 other functional areas was a default (the prompt\'s Part 5 text is not in the repo). Stephen confirmed it 11/13/2026. | Fixed 11/13/2026 |');
fs.writeFileSync(f,s);"

# --- MASTER_ROADMAP heading
sed -i 's/^## Phase 5: Functional and housing assessment (size M) — BUILT AND LIVE 11\/13\/2026 (Part 14 not yet met: P5-01 to P5-04)$/## Phase 5: Functional and housing assessment (size M) — BUILT AND LIVE 11\/13\/2026 (Part 14 not yet met: P5-01 walk-through deferred, P5-02 open)/' $D/MASTER_ROADMAP.md
grep -q 'P5-01 walk-through deferred, P5-02 open' $D/MASTER_ROADMAP.md

# --- DEVELOPMENT_STATUS row + log
node -e "
const fs=require('fs');const f='$D/DEVELOPMENT_STATUS.md';let s=fs.readFileSync(f,'utf8');
const a='Open: P5-01 to P5-04 in KNOWN_ISSUES.md (signed-in walk-through, Settings download, Function reflection overlap, D-26 areas list to confirm). |';
if(!s.includes(a))throw new Error('row');
s=s.replace(a,'Overlap removed (303000) and D-26 confirmed 11/13. Open: P5-02 Settings download; P5-01 signed-in walk-through deferred by Stephen. |');
const b='  public page draws 7 cards in Chrome, no sideways scroll.\n';
if(!s.includes(b))throw new Error('log');
s=s.replace(b,b+'- Follow-up 11/13/2026 (Stephen: \"your 11 areas are confirmed, remove the overlap, leave real walk-through for now\"): D-26 DECIDED.\n  Migration 20261119303000 retires 9 Function reflection questions that Everyday activities asks in full (meals, shopping, medicine,\n  bills, getting around, housekeeping, laundry, phone/computer, bathing and dressing); kept: paperwork, appointments, the open question.\n  Retired = active false, so the version history stays; no one had answered them. Set intro reworded. t33 check now saves paperwork.\n  P5-01 deferred.\n');
fs.writeFileSync(f,s);"
echo docs-ok
