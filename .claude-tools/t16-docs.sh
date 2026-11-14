#!/bin/sh
# T1.6 documentation: D-31, roadmap, sitemap, status row and log. Stops if D-31 is already taken.
set -e
cd "$(dirname "$0")/.."
D=docs/human-mirror
grep -q "^| D-31 " $D/DECISIONS.md && echo "D-31 already taken: stop" && exit 1
ROW='| D-31 | **Conversation guide, saved (T1.6, 11/13/2026).** DEFAULTS chosen by Claude for Stephen to confirm: (a) the person answers on their OWN My Mirror (/mirror/my-mirror/conversation/), also when sitting with a Navigator; a coordinator never types the answers and never sees them; (b) "what we heard" is saved per finding; the person ticks items and picks ONE organization; ticking one item is consent for that item only (the topic stays closed, D-14); they can change the ticks, take it all back or keep it for themselves; (c) the coordinator sees the ticked items (the person'"'"'s words included) as a draft plan at /mirror/workspace/conversation/?id=&org=, every look at a private item logged; (d) a finding becomes a Phase 6 need through mirror_need_save (a coordinator needs the person'"'"'s "see and change" for that topic; the person can add it themselves); (e) referrals use the existing chpms_referral_save (staff, field staff, Navigators past preview) and are linked to the finding; (f) missed phrases: plain words (no patterns) per organization, used for the people that organization works with; (g) privacy of a finding follows its topic: Financial counseling and Benefits enrollment are now private (topic financial), on top of D-21'"'"'s list. Tables mirror.conversations, conversation_answers, conversation_findings, conversation_referrals, listen_keys, listen_phrases (migration 20261119360000). | DEFAULT (confirm) |'
awk -v row="$ROW" '{print} /^\| D-30 /{print row}' $D/DECISIONS.md > $D/DECISIONS.md.tmp && mv $D/DECISIONS.md.tmp $D/DECISIONS.md
grep -q "^| D-31 " $D/DECISIONS.md || { echo "D-31 not inserted"; exit 1; }

sed -i 's#^\*\*T1.6 Conversation guide and draft plan\*\* (M, D-21) — \(.*\)Status: PREVIEW BUILT 11/13. Next: save answers and the shared findings per person once T2.1-T2.3 exist (consents per category, D-14); Navigator confirms each suggestion and refers through `chpms_referral_save`; Navigators add phrases that were missed (phrase list as data).#**T1.6 Conversation guide and draft plan** (M, D-21) — \1Status: BUILT AND LIVE 11/13/2026 (D-31; migration 20261119360000; check t16 9/9 rolled back): answers saved per person (person only), what-we-heard findings shared item by item with one organization, coordinator draft plan, findings to needs, referrals through `chpms_referral_save` linked back, missed phrases per organization. Guided Tour pending (D-28).#' $D/MASTER_ROADMAP.md
grep -q "BUILT AND LIVE 11/13/2026 (D-31" $D/MASTER_ROADMAP.md || { echo "roadmap not updated"; exit 1; }

sed -i 's#^| my-needs/ |#| conversation/ | A conversation: open questions (speak or type), what we heard, share item by item with one organization or keep it (T1.6, D-31; built 11/13/2026) | 1 |\n| my-needs/ |#' $D/SITEMAP.md
sed -i 's#^| assessments/ | Conduct or review assessments with the person | 8 |#| conversation/?id=\&org= | Conversation plan: what the person shared from a conversation, suggested programs, needs, referrals, missed phrases (T1.6, D-31; built 11/13/2026) | 1 |\n| assessments/ | Conduct or review assessments with the person | 8 |#' $D/SITEMAP.md
grep -c "T1.6, D-31" $D/SITEMAP.md

sed -i 's#^| 1 Foundation | BUILT AND LIVE, Guided Tour pending (D-28) | .*#| 1 Foundation | BUILT AND LIVE, Guided Tour pending (D-28) | T1.1-T1.6 built and checked by Claude. T1.6 saving built 11/13 (D-31, migration 20261119360000, t16 9/9). Open: Guided Tour (deferred, D-28) only. |#' $D/DEVELOPMENT_STATUS.md
grep -q "T1.1-T1.6 built" $D/DEVELOPMENT_STATUS.md || { echo "status row not updated"; exit 1; }
cat >> $D/DEVELOPMENT_STATUS.md <<'EOF'

### 11/13/2026 — T1.6 conversation guide saves (Stephen: "build it"; D-31 defaults to confirm)
- Migration 20261119360000_mirror_conversations.sql: listen_keys (42 meanings = the browser list), conversations (open / kept / shared, one open
  per person), conversation_answers (person only), conversation_findings (ticks, need link), conversation_referrals, listen_phrases (per organization,
  plain words). Functions: mirror_conversation_mine/start/answer_save/share/discard/need, mirror_conversations_shared, mirror_conversation_referral_log,
  mirror_listen_phrases/_add/_retire, mirror_my_export_conversations. Grants: tables service_role only; functions authenticated.
- Pages: /mirror/my-mirror/conversation/ (person), /mirror/workspace/conversation/?id=&org= (coordinator); links on My Mirror and the workspace person
  page; Settings download and printable copy include conversations. mirror-listen.js ?v=20261113c: MEANINGS (same as listen_keys), privacy by topic,
  organization phrases (escaped plain words).
- Checks: t16 9/9 (rolled back): person-only answers, item-by-item sharing with one org, no answers or unticked words to the coordinator, private
  look logged, needs only with edit OK, referral linking, phrases, take back / keep / discard, download, isolation, closed tables. Browser list vs
  database: 42 = 42 meanings, every built-in rule has a meaning. All touched pages: module syntax ok; html-validate 0 errors.
- Not done: Guided Tour (D-28). D-31 is a DEFAULT for Stephen to confirm.
EOF
echo docs-ok
