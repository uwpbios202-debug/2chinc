# The Human Mirror: Master Roadmap

Each task card: **Objective**, **Files**, **DB** (database implications), **Deps**, **Security**, **Accept** (acceptance
criteria), **Check** (testing, per D-01), **Status**. A feature is complete only when all 8 conditions of the prompt's Part 14
hold (interface, data model, working DB operations, tested permissions, validation, error handling, checks pass, docs updated).
Size: S (one session), M (2-3 sessions), L (4+).

Status key: DONE, READY (can start), BLOCKED (waits on a decision), LATER.

---

## Phase 0: Repository discovery — DONE 11/12/2026

T0.1 Audit and documents. **Files** docs/human-mirror/*. **Accept** the 11 documents exist and agree with each other. **Status** DONE.

---

## Phase 1: Foundation (size M)

**T1.1 Design system and page shell** (S)
- Objective: `mirror.css` tokens (color, type scale from 18px base, spacing, focus rings, light/dark), components (page shell, header with text wordmark, nav, card, button, form field, progress count, notice), mobile first.
- Files: site/mirror/assets/mirror.css, site/mirror/assets/mirror-ui.js. DB: none. Deps: none.
- Security: no inline scripts that need relaxed headers; no third-party assets except Google Fonts already used by the site.
- Accept: contrast AA for all text pairs; works at 320px wide; keyboard focus visible; no horizontal scroll.
- Check: contrast computed for each token pair (script in tools/mirror-checks); manual keyboard pass. Status: DONE 11/12/2026 (contrast 62 of 62 pairs pass; 320 and 390 px checked; keyboard-only pass still to run, with T1.2).

**T1.2 Public website shell** (S)
- Objective: /mirror/ home, about, how-it-works, life-dimensions, privacy (draft text), accessibility, forgot-password (no-password help). `noindex` (D-15).
- Files: site/mirror/{index,about,how-it-works,life-dimensions,privacy,accessibility,forgot-password}/index.html, site/mirror/assets/dimensions.js.
- DB: none. Deps: T1.1. Security: no forms that collect data. Accept: every page 200 locally, readable on a phone, no invented logos or endorsements.
- Check: link walk returns 200 for every href; HTML validates. Status: DONE 11/13/2026 (8 pages incl. a sign-in placeholder so the menu has no dead link; link walk .claude-tools/mirror-linkwalk.mjs all 200; 390 px no sideways scroll; keyboard order checked). HTML validator not run.

**T1.3 Mirror client and sign-in gate** (S)
- Objective: `mirror-client.js` reuses the site's Supabase client and email-code sign-in; `mirror_whoami()` returns the Mirror role(s); each area page refuses the wrong role with a plain message.
- Files: site/mirror/assets/mirror-client.js, site/mirror/sign-in/index.html. DB: migration with `public.mirror_whoami()` (reads nothing yet but `portal_admins`). Deps: T1.1, T2.1 for real roles.
- Security: no change to `portal.js` (cached shared script); separate auth storage key not needed (same login).
- Accept: signed-out visitor sees sign-in; an existing tenant signing in sees "no Mirror yet" and nothing else. Check: simulated claims in a rolled-back transaction. Status: READY.
- Status: DONE 11/13/2026 (commit 7e92a8e): mirror-client.js (signInBox, requireArea, whoami, signOut), /mirror/sign-in/, /mirror/my-mirror/ and /mirror/workspace/ landing pages. Same browser session as the portals (the email's Sign in button only works that way without changing /sign-in/). Switch mirror_signin_enabled still off.

**T1.4 Environment and conventions doc** (S) — env vars (none new in the browser; function secrets listed by name only), migration naming, `// @ts-check` rule. Status: DONE 11/13/2026 (docs/human-mirror/CONVENTIONS.md).

**T1.5 Speak instead of type** (S, D-19) — `voiceInput` in mirror-ui.js: Speak button on every text field and textarea (browser speech recognition, on-device when offered, consent once, off on sensitive questions until OK), Read aloud on questions, Firefox fallback shows Windows key + H / Mac dictation; styleguide shows it. Check: Chrome desktop, Android, iPhone, Firefox. Status: DONE 11/13 except phone/Firefox/Edge checks: privacy + Speak button + Read aloud (`readAll`: [data-mm-read] questions, "Listen to this page" on main[data-mm-listen], on-device voice preferred).

**T1.6 Conversation guide and draft plan** (M, D-21) — `mirror-listen.js` (QUESTIONS, phrase list, `analyse`, `draftPlan` against `chpms_directory()`), preview page /mirror/demo/conversation/ (made-up people, nothing saved; programs shown to signed-in staff / Navigators). Status: BUILT AND LIVE 11/13/2026 (D-31; migration 20261119360000; check t16 9/9 rolled back): answers saved per person (person only), what-we-heard findings shared item by item with one organization, coordinator draft plan, findings to needs, referrals through `chpms_referral_save` linked back, missed phrases per organization. Guided Tour pending (D-28).

---

## Phase 2: Database and access control (size L)

**T2.1 Schema, organizations, members, individuals, profiles** (M)
- Objective: schema `mirror`, revoke all from anon/authenticated, tables organizations, organization_members, profiles, individuals, organization_individuals; seed 2nd Chance Housing.
- Files: supabase/migrations/*_mirror_identity.sql. DB: new schema, 5 tables, grants service_role only. Deps: T1.3.
- Security: RLS on, deny-all; `mirror.require()` written here. Accept: checks 1-3 of SECURITY_PLAN section 4 pass. Check: SQL check script. Status: DONE 11/13/2026 (migration 20261119150000, live).

**T2.2 Consents and role permissions** (M) — tables consents, role_permissions (seed the matrix), `mirror.require(individual, category, action)`. Accept: check 4. Status: DONE 11/13/2026 (`mirror.allowed()` decides and audits without raising; `mirror.require()` raises, for writes).

**T2.3 Audit architecture** (S) — `mirror.audit_logs`, `mirror.audit()` helper called by require and every write function; person's "who looked" view. Accept: check 5. Status: DONE 11/13/2026 (`public.mirror_who_looked()`).

**T2.4 Sign-in integration** (M) — add Mirror members and individuals to `condo_email_on_file`, role `mirror` to `mfa_required_roles`, session day settings. Touches shared login functions: read live definitions first, change by `create or replace` with the full current body. Security: strangers still cannot sign up unless D-03 option 2. Status: DONE 11/13/2026, built STAND-ALONE at Stephen's request (D-22): condo_email_on_file, View as, mfa_required, session_role and session settings unchanged; new signin_email_on_file() used only by auth-send-email (fallback to the old list); switch mirror_signin_enabled = off.

**T2.5 Admin: organizations, members, roles** (M) — /mirror/admin/organizations, users, roles, teams. Platform admin only. Status: DONE 11/13/2026 as one page /mirror/admin/ (migration 20261119180000): platform admin = portal admin or org_admin of 2nd Chance; org admins manage their own members; last admin protected.

**T2.6 Invite flow** (M) — /mirror/workspace/people/new + /mirror/register/ (invite acceptance), email kind `mirror_invite` (queued, never flushed without Stephen's OK on the first real send). Status: HALF DONE 11/13/2026: /mirror/workspace/people/ adds people (email = invited, none = active), lists, ends/restarts. Second half BUILT + LIVE 11/13/2026 (migration 20261119670000, check t26b 5/5): the invitation email (wording approved by Stephen) goes out through mirror.email_queue for every way a person or member is invited (triggers), "Send the invitation again" on /mirror/workspace/people/ and /mirror/admin/ (once per 12 hours), and https://2ndchinc.org/mirror/register/ explains how to accept. Held until Stephen turns the invitation kinds on at https://2ndchinc.org/mirror/admin/email/. Also fixed: the 12-hour repeat guard counts only emails really queued, not held ones.

---

## Phase 3: Individual Mirror (size L)

**T3.1 Assessment engine (data)** (M) — question_sets, reflection_questions, assessments, assessment_responses (append-only), reflection_answers view; seed the 8 reflections and 15 dimensions. Functions: `mirror_set_get`, `mirror_answer_save`, `mirror_answers_history`. Accept: every answer state (unknown, n/a, prefer not, needs help) saved and shown; old answers kept. Status: DONE 11/13/2026 (migration 20261119190000, t31 9/9; gate quiet probe mirror.may(), t2 re-run 9/9).

**T3.2 Assessment engine (UI)** (M) — assessment-engine.js renders any set; autosave per answer; resume where left; completion counts; works offline-tolerant (retries on reconnect). Status: DONE 11/13/2026 (assessment-engine.js).

**T3.3 Question content for the 8 reflections** (M) — from Mirror 2 (Today, History, Vision, Assets, Needs, Contribution) and the prompt (Function, Preferences); plain language at about 6th-grade reading level; every question optional. Status: DONE 11/13/2026 (94 questions, migration 20261119200000, generated by tools/mirror-checks/reflection-questions.mjs).

**T3.4 Personal dashboard and 8 reflection pages** (M) — /mirror/my-mirror/ + today/ ... contribution/. One continuous conversation feel (Mirror 2): next suggested reflection, never forced order. Status: DONE 11/13/2026 (reflection-page.js; suggested order identity, assets, vision, history, needs, preferences, function, contribution).

**T3.5 Fifteen dimension pages (shell)** (M) — one page per life area using the nine-question pattern (D-10). Status: DONE 11/13/2026 (150 questions, migration 20261119210000, /mirror/my-mirror/life/ + 15 pages).

**T3.6 Privacy controls and settings** (M) — consents per organization and category, "who looked at my record", notification choices, safety mode, export (JSON + printable). Status: DONE 11/13/2026 (migration 20261119220000, /mirror/my-mirror/settings/, t36 5/5). PHASE 3 COMPLETE.

---

## Phase 4: Daily Number (size L) — BUILT 11/13/2026 (audit steps 1-5 live); Guided Tour pending (D-28)

**T4.1 Calculation module** (S) — `daily-number.js` pure functions (normalize, totals per level, the 7 figures, daily/weekly/monthly/annual) per D-08. Check: fixtures from the source emails ($2,300/month -> $75.62/day, $27,600/yr; $600/yr -> $1.64/day; $90/month clothing -> $2.96/day; $50/day gap -> $1,520.83/month) plus irregular, subsidy and noncash cases calculated by hand. Status: DONE 11/13/2026 (now 90 of 90 figures after audit steps 1-2 and the one-time rule; tools/mirror-checks/daily-number-fixtures.mjs).
**T4.2 Tables and server function** (M) — expense_categories (seed 12), living_expenses, income_sources, noncash_resources, financial_goals, daily_number_snapshots; `mirror.daily_number()` gives the same results as T4.1 (same fixtures run in SQL). Status: DONE 11/13/2026 (migration 20261119230000; t42: 45 of 45 in SQL, access/history 6/6).
**T4.3 Pages** (L) — dashboard, survival, stability, aspirations, income, gap, history; snapshot on save; "what changed" between snapshots; public /mirror/daily-number/ explainer with a no-save example. Status: DONE 11/13/2026 (daily-number-page.js; every page drawn locally with made-up data, numbers matched).
**T4.4 Cost of being poor** (S) — optional lines tagged `poverty_premium`, shown as "costs that could go down". Status: DONE 11/13/2026. Phase 4 audit steps 1-5 done 11/13/2026 (DEVELOPMENT_STATUS.md); the real signed-in walk-through is the Guided Tour, deferred until all phases are built (D-28).

---

## Phase 5: Functional and housing assessment (size M) — BUILT AND LIVE 11/13/2026 (open: P5-02 Settings download; Guided Tour (deferred, D-28))

**T5.1 ADL / IADL / functional areas** (M) — tables functional_assessments, adl_assessments, iadl_assessments; question sets for the 11 other areas; levels with the person's own preference beside each. Wording: "this is not a diagnosis".
Status: BUILT 11/13/2026 (commit c89e16e, migrations 20261119300000-302000; check t5 8/8). Pages /mirror/my-mirror/abilities/activities/ and /abilities/areas/; 11 areas per D-26.
**T5.2 Housing profile and living options** (M) — housing_options (seed), housing_profiles, housing_history; /mirror/living-options/ public page. Never auto-recommends assisted living (prompt Part 5); shows options the person can explore and marks "professional review needed" when a coordinator flags it.
Status: BUILT 11/13/2026 (same commit and check). Pages /mirror/my-mirror/living/ and public /mirror/living-options/; review mark set only by a helper.

---

## Phase 6: Personal development (size L)

**T6.1 Needs inventory with lifecycle** (M) — needs + need_events, urgency, statuses identified -> verified (Mirror1 Part 4). Status: BUILT 11/13/2026 (migration 20261119320000, page /mirror/my-mirror/my-needs/, check tools/mirror-checks/t61-needs-check.sql; verify rule D-27 waits on Stephen). Not yet: the coordinator's needs view (workspace, Phase 8).
**T6.2 Strengths inventory** (S). Status: BUILT + LIVE 11/13/2026 (commit 3760df7, migration 20261119330000, page /mirror/my-mirror/my-strengths/, suggestions from answers, check t62).
**T6.3 Goals, plans, action items, milestones** (M) — journey stages 1-6 as labels, not deadlines. Status: BUILT 11/13/2026 (migration 20261119331000, pages /mirror/my-mirror/plan/, actions/, milestones/, check t63; no action_plans table, D-29). Goal suggestions from the Vision reflection built + live 11/13/2026 (Stephen: YES; migration 20261119366000, check t63b 4/4). Not yet: the coordinator's view (Phase 8).
**T6.4 Progress page** (S) — counts per dimension (D-09), history over time. Status: BUILT + LIVE 11/13/2026 (migration 20261119365000 `mirror_progress`, page /mirror/my-mirror/progress/, progress-page.js, check t64 5/5 rolled back). Not yet: the coordinator's view (Phase 8, T8.2 reuses progressBox).

---

## Phase 7: Resource directory (size M)

**T7.1 Link CHPMS to the Mirror** (S) — resource_categories (program -> dimension, expense category). Status: BUILT + LIVE 11/13/2026 (migration 20261119400000, check tools/mirror-checks/t71-resource-categories-check.sql 6/6): `mirror.resource_assist_map` maps all 20 CHPMS help types to an area (+ cost category); `rule` links follow the CHPMS import by a statement trigger on chpms_program_assist; `office` links (for TN.3) survive every refresh; reader `mirror.program_areas(program)` (service_role only). No browser screen yet (T7.2).
**T7.2 Suggestions** (M) — resource_suggestions with statuses suggested / eligibility_confirmed / applied / enrolled; matching on dimension, need, city/county, household; "suggested" label always visible (Part 11). Status: BUILT + LIVE 11/13/2026 (migration 20261119410000, page /mirror/my-mirror/resources/, check t72 6/6; follow-up migration 20261119412000 + check t72b 4/4: no limit, ranked with reasons, Top 1/3/5/All, place and groups shared only by the person's choice; D-32 DECIDED 11/13/2026). Not yet: the coordinator's screen for confirming eligibility (the function is there; workspace Phase 8).
**T7.3 Referrals with consent** (M) — mirror referrals reusing CHPMS referral rules (typed consent, do-not-refer respected). Status: BUILT + LIVE 11/13/2026 (migration 20261119413000, pages /mirror/my-mirror/referrals/ and /mirror/workspace/referrals/, check t73 6/6, rules D-33 DEFAULT for Stephen to confirm). Also fixed: public.chpms_referral_save could not save any new referral (phone/email check on its first insert).
**T7.4 Documents** (M) — document_types, documents, bucket `mirror-docs`, edge function `mirror-files` (signed URLs). Status: BUILT + LIVE 11/13/2026 (migration 20261119414000, function mirror-files, pages /mirror/my-mirror/documents/ and /mirror/workspace/documents/, check t74 6/6). 8 types; photos or PDFs up to 10 MB; the bucket has no storage policy; open links last 5 minutes; delete by the person or whoever added it. Follow-up (migration 20261119415000, check t74b 4/4): when a person is removed (e.g. the 30-day deletion D-18, once built) or any document's details go away, its file is queued and the hourly job mirror-docs-sweep has mirror-files remove it through the Storage API; stray files without details over a day old too.

---

## Phase 8: Organization workspace (size L) — BUILT AND LIVE 11/13/2026 (T8.1-T8.8 and P2-08 platform admin pages; open: Guided Tour (deferred, D-28))

**T8.1 Workspace dashboard and people list** (M). Status: BUILT + LIVE 11/13/2026 (migration 20261119500000: mirror_workspace_dashboard, mirror_people_counts, mirror_org_audit (P2-07); pages /mirror/workspace/, people/ (search, filter, counts), audit/; check t81 6/6). Appointments on the dashboard wait for T8.5. **T8.2 One-person overview** (M, consent-limited sections, safety banner). Status: BUILT + LIVE 11/13/2026 (migration 20261119510000; workspace-person.js on /mirror/workspace/person/: safety note P2-06, needs with status / confirm met / change the words (T6.1 finding 5: recorded in the need's own history), strengths, plan with the milestone confirm button, progress; list pages renamed "My needs list" / "My strengths list" with links to the questions (finding 6); check t82 5/5).
**T8.3 Assessments with the person** (S) — Status: DONE 11/13/2026 (migration 20261119530000, t83 6/6; /mirror/workspace/assessments/). **T8.4 Services and enrollments** (S) — Status: DONE 11/13/2026 (migration 20261119540000, t84 6/6, D-34). **T8.5 Appointments and interactions** (M) — Status: DONE 11/13/2026 (migration 20261119550000, t85 7/7, D-35).
**T8.6 Benefits applications** (S, renewal and appeal dates) — Status: DONE 11/13/2026 (migration 20261119560000, t86 6/6, D-37). **T8.7 Inventory of donated goods** (M, clothing sizes/condition/season) — Status: DONE 11/13/2026 (migration 20261119570000, t87 5/5, D-38).
**T8.8 Outcomes and reports** (M, counts per organization; no person scores; safety-mode records excluded by name) — Status: DONE 11/13/2026 (migration 20261119580000, t88 5/5, D-39; /mirror/workspace/reports/).

---

## Phase N: Navigators in the Mirror (size M; closes the gaps in NAVIGATOR.md section 4)

The live Navigator portal (`/navigator/`, `nav_*`) keeps working throughout; these tasks connect it to the Mirror, never replace it in one step.

**TN.1 Whole-person consent for Navigator people** (S) — a Navigator person's consent moves to `mirror.consents` per dimension and category; the old housing-only consent text stays on the records already signed (history unchanged). Deps: T2.2. Security: a Navigator sees only what the person granted to that Navigator's organization (D-20). Status: BUILT + LIVE 11/13/2026 (migration 20261119610000, check tn1 6/6, D-36 DEFAULT): "Sharing beyond housing" on the Navigator's person screen (/navigator/ and /staff/navigators/): per private topic not shared / can see / can see and change, exact words, typed full name; table nav_whole_consents; ends with the housing consent; mirror.nav_whole_consent_to_mirror copies it into mirror.consents for the Navigator's organization (called by TN.2).
**TN.2 Navigator person = Mirror individual** (M) — `nav_referrals.mirror_individual_id`; each Navigator business is an organization (D-06, D-20) and the Navigator its coordinator; "Open their Mirror" from the person's file; adding a person can start a Mirror with them (invite, D-03, or coordinator-assisted without email). Deps: T2.1, T2.6, T3.4. Status: BUILT + LIVE 11/13/2026 (migration 20261119620000, check tn2 6/6): nav_referrals.mirror_individual_id; mirror.navigator_org makes the Navigator business's organization on first use (Navigator its admin); "Start their Mirror" on the person's file (/navigator/ and /staff/navigators/): invitation by email, or without email filled in together; an existing Mirror is linked, never overwritten; sharing beyond housing copied; "Open their Mirror" when active; withdrawing the housing consent revokes sharing and ends the work (D-36 DECIDED).
**TN.3 Directory by life dimension** (M) — CHPMS programs tagged with dimensions and needs (T7.1); the Resources tab searches by any of the 15 dimensions, not only the 20 housing help types; research of non-housing Milwaukee programs (ID, health, food, phone, work, education, legal) loaded with the same verification rules. Deps: T7.1. Status: BUILT + LIVE 11/13/2026 (migrations 20261119630000 + 20261119631000, check tn3 5/5): Find help has a Life area filter (all 15 areas) on https://2ndchinc.org/staff/resources/ and the Navigator Resources tab; each program shows its life areas; office staff tag programs (office links, kept through every refresh). Researched from official pages 11/13: 7 new organizations and 10 programs (State ID, birth certificate, FoodShare, Hunger Task Force food, Progressive CHC care, Lifeline, library computers, Employ Milwaukee, Literacy Services, Job Center of Wisconsin); legal help was already listed. Show > "Added 11/13 beyond housing" lists them.
**TN.4 Own-room disclosure** (S) — a match to a room the Navigator runs is marked "a room you run"; the person confirms on screen that they know and chose it; staff can list these matches. Deps: none (can be built in the live portal any time). Status: BUILT + LIVE 11/13/2026 (migration 20261119640000, check tn4 6/6): "A room you run" on the file; the person types their full name to confirm the exact sentence; a trigger blocks the placement (approved) until then, and a different room needs a new confirmation; the office's Navigators dashboard lists every such match.
**TN.5 Check-ins from the first meeting** (S) — the check-in plan can start before housing and follows the person's Mirror plan; check-in notes can link to Mirror needs. Deps: T6.1 for the links (the earlier start has no deps). Status: BUILT + LIVE 11/13/2026 (migration 20261119650000, check tn5 6/6): the plan starts once the housing consent is signed ("Start check-ins" on the file); recording one schedules the next; closing before move-in clears it; move-in adds the 90-day and 12-month reviews as before; retention pay unchanged; check-ins are linked to Mirror needs in the Mirror (https://2ndchinc.org/mirror/workspace/checkins/, authenticator and shared topics only). Reminder emails before move-in wait for Stephen. PHASE N BUILT.

---

## Phase 9: Email and notifications (size M)

**T9.1 Templates and preferences** (M) — `mirror.email_html(kind, data)`, notification_prefs, kinds per ARCHITECTURE section 6. Status: BUILT + LIVE 11/13/2026 (migration 20261119660000, check t91 5/5, D-42): mirror.email_html (6 kinds, no details, safety mode neutral with the link https://2ndchinc.org/account/), mirror.email_queue (the one way; the person's choices and safety mode via mirror.notification_ok; repeats within 12 hours skipped; every attempt in mirror.notifications), THE HOLD (portal_settings.mirror_email_kinds_enabled starts empty: nothing is sent until the main admin turns a kind on at https://2ndchinc.org/mirror/admin/email/). Choices in Settings were already built (Phase 3 fix 5, D-25).
**T9.2 Reminders** (S) — appointment and action reminders through the existing cron pattern. Every first real send of a kind asks Stephen (CLAUDE.md). Status: BUILT + LIVE 11/13/2026 (migration 20261119680000, check t92 4/4): mirror.send_reminders, the day before each scheduled appointment and each open plan step due (Milwaukee date), to the person's own sign-in email, date and time only (never the title); job mirror-reminders daily 13:30 UTC (7:30 a.m. Milwaukee in winter); through mirror.email_queue, so the person's choices, safety mode and the hold apply (both kinds off until Stephen turns them on).

---

## Phase 10: Production readiness (size M) — IN PROGRESS (P2-13 one place for the rules, D-41, and P2-15 rate limits, D-43, done 11/13/2026)

Security review (advisor, policies, functions), access-matrix re-check, accessibility pass (keyboard, screen reader on a phone),
mobile pass, performance (page weight, number of calls), error handling, backup and recovery plan (Supabase plan decision:
daily backups need Pro, see KNOWN_ISSUES K-03), deployment documentation, privacy page final text, launch decision by Stephen.

---

## Complexity estimate

41 tasks after Phase 0: 14 S, 26 M, 1 L (T4.3). With S = 1 session, M = 2-3, L = 4+, that is roughly 70-95 working
sessions. This is a large system, comparable to the leasing and portal work already in this repo.
Highest risk: Phase 2 (touches the shared sign-in functions used by the whole site) and Phase 4 (money arithmetic).
