# The Human Mirror: Development Status

Built and live at https://2ndchinc.org/mirror/ (noindex, not linked from the main site): Phases 1, 3, 4 and 5, Phase 2 except its open
fixes, and Phase 6 except T6.4 (as of 11/13/2026; see the table and the session log). Latest Mirror migrations live: 20261119360000
(T1.6) and 20261119269700 (Phase 2 finding E). The switch `mirror_signin_enabled` is OFF, so no real person signs in yet.
Do not mark anything complete until it meets the 8 conditions of the prompt's Part 14.

| Phase | Status | Notes |
|---|---|---|
| 0 Repository discovery | DONE 11/12/2026 | Audit + 11 documents in docs/human-mirror/. |
| 1 Foundation | BUILT AND LIVE, Guided Tour pending (D-28) | T1.1-T1.6 built and checked by Claude. T1.6 saving built 11/13 (D-31, migration 20261119360000, t16 9/9). Open: Guided Tour (deferred, D-28) only. |
| 2 Database and access control | IN PROGRESS | T2.1-T2.5 live. Deep-dive (11/13): fixes 1-5 and 14 of 15 done, finding C (the Mirror's own sign-out limits, migration 20261119269500) and finding E (platform admins an explicit list, migration 20261119269700); fixes 6-13 and 15 open (list in KNOWN_ISSUES.md, P2-06 to P2-15). T2.6 half done: /mirror/register/ and the invitation email (Phase 9) still to do. Guided Tour (deferred, D-28). |
| 3 Individual Mirror | DONE 11/13/2026 | T3.1-T3.6; 23 question sets, 244 questions; hands-free (D-23). |
| 4 Daily Number | BUILT, Guided Tour pending (D-28) | T4.1-T4.4 and audit steps 1-5 built and live 11/13: one-time cost rule (K-09, method 4); step 4 household, benefits, my plan, what if; printable copy (K-10) and phone menu; step 5 change log of helpers' edits, fuller public calculator, bug-check segment 12 line. JS 120/120, SQL 105/105, t42-t45 pass. Open: Guided Tour (deferred, D-28). |
| 5 Functional and housing assessment | BUILT AND LIVE 11/13/2026 (not complete under Part 14) | P5-02 fixed 11/13: Settings' download and printable copy include the Phase 5 records (mirror_my_export_living). T5.1 + T5.2 built, live and checked (t5 8/8, rolled back). Commit c89e16e, migrations 20261119300000-302000. Overlap removed (303000) and D-26 confirmed 11/13. Open: Guided Tour (deferred, D-28). |
| 6 Personal development | BUILT AND LIVE 11/13/2026, Guided Tour pending (D-28) | T6.1 needs, T6.2 strengths, T6.3 goals, steps and milestones, T6.4 progress page (migration 20261119365000, /mirror/my-mirror/progress/, t64 5/5) built and live 11/13 (D-27, D-29, D-30 confirmed). Coordinators see none of it until Phase 8 (T8.2 reuses progressBox). Goal suggestions from the Vision reflection built 11/13 (Stephen: YES; migration 20261119366000, t63b 4/4). |
| 8 Organization workspace | BUILT AND LIVE 11/13/2026 (8 of 8), Guided Tour pending (D-28) | T8.1 dashboard and people list + P2-07 (organization's own audit log) built and live 11/13 (migration 20261119500000, t81 6/6). T8.2 one-person overview + P2-06 safety note, T6.1 findings 5 and 6, milestone confirm button built and live 11/13 (migration 20261119510000, t82 5/5). T8.3 assessments with the person (review page, per-set "last together") built and live 11/13 (migration 20261119530000, t83 6/6). T8.4 services and enrollments built and live 11/13 (migration 20261119540000, t84 6/6, D-34 decided). T8.5 appointments and contact notes built and live 11/13 (migration 20261119550000, t85 7/7, D-35 decided). T8.6 benefits applications built and live 11/13 (migration 20261119560000, t86 6/6, D-37 decided). T8.7 donated goods built and live 11/13 (migration 20261119570000, t87 5/5, D-38 decided). T8.8 outcomes and reports built and live 11/13 (migration 20261119580000, t88 5/5, D-39 decided). Phase 8 open: P2-08 admin pages. Guided Tour (deferred, D-28). |
| 7, 8, N, 9, 10 | NOT STARTED | About 33-45 of the roadmap's 70-95 sessions remain (about 47%), counting T6.4. |

## Session log

### 11/12/2026 — Phase 0
- Completed: read the six emails in full; inspected repo layout, build and deploy scripts, headers, sign-in and role functions,
  existing CHPMS, Navigator and caseworker modules, migration and function state; wrote PROJECT_AUDIT, MASTER_ROADMAP,
  ARCHITECTURE, SITEMAP, DATABASE_DESIGN (with diagram), SECURITY_PLAN, TESTING_PLAN, DECISIONS, KNOWN_ISSUES, NEXT_ACTIONS.
- Tested: nothing to test (documents only). Daily Number examples in the emails re-calculated by hand: $2,300/month =
  $27,600/yr = $75.62/day; $600/yr = $1.64/day; $90/month = $1,080/yr = $2.96/day; $75/day = $2,281.25/month = $27,375/yr;
  $50/day = $1,520.83/month. All match the emails (the emails' two weekly figures use different methods: D-08).
- Incomplete: everything from Phase 1 on.
- Outstanding decisions: D-01 testing, D-03 who creates individual accounts.
- Next task: T1.1 design system and page shell.

### 11/12/2026 — T1.1 Design system and page shell
- Decided by Stephen: D-01 read-only checks, D-03 invite only.
- Completed: `site/mirror/assets/mirror.css` (tokens, light + dark + system dark, larger-text mode, shell, nav, cards, buttons,
  form fields, choice cards with the four no-answer states set apart, notices, tags, counts, figures, tables, toast, workspace
  density, print), `site/mirror/assets/mirror-ui.js` (`// @ts-check`; shell, per-area nav, mobile menu, text size remembered,
  `countBar`, `notice`, `toast`, `esc`), component preview `/mirror/styleguide/` (noindex, not linked),
  check `tools/mirror-checks/contrast.mjs`.
- Tested: `node tools/mirror-checks/contrast.mjs` = all 62 pairs pass (31 light, 31 dark; text 4.5:1, controls 3:1) and the two
  dark blocks match. In Chrome on a local server: desktop layout; 320 px and 390 px frames have no sideways scroll, Menu
  shows and opens the nav (aria-expanded true); dark theme and choice cards render. Found and fixed: Menu button showed on wide
  screens (`.mm-btn` display overrode the toggle rule).
- Not yet: keyboard-only pass and a screen reader pass (do with T1.2); `tsc --checkJs` not run.
- Deployed 11/12 (site deploy of 3ba347e) so Stephen can view https://2ndchinc.org/mirror/styleguide/ (noindex, not linked).
- Next: T1.2 public website shell.

### 11/12/2026 — Review with Stephen (evening)
- Styleguide deployed: https://2ndchinc.org/mirror/styleguide/ . Stephen likes the styles.
- Tables made easier to read at his request: framed, tinted header, every other row shaded, hover row, bold total; on phones
  each row becomes a card with labels (`.mm-stack`, `data-label`). Contrast check: all pairs pass (new pairs added). Checked
  live at desktop and in a 390 px frame (no sideways scroll).
- New requirement (D-19, task T1.5): speech to text on every input; Read aloud on questions.
- Waiting on Stephen: D-19 privacy default; go-ahead for T1.2 + T1.5 together.
- Next: T1.2 public pages + T1.5 Speak button, keyboard-only and screen-reader passes.

### 11/12/2026 — The Navigator in the Mirror (study)
- Stephen: the Mirror is the whole-person approach; housing is one of the things a Navigator connects a person to; the Mirror is
  being built to close the gaps in the Navigator system.
- Completed: NAVIGATOR.md (who a Navigator is, the first meeting, the gaps N1-N5), decision D-20 (Navigators are coordinators,
  the person owns their Mirror, each Navigator business is its own organization), roadmap Phase N (TN.1-TN.5).
- Tested: nothing (documents only). Live Navigator portal unchanged.
- Open: D-20 staff view of sensitive categories (see DECISIONS).

### 11/13/2026 — D-19 privacy setting built
- Stephen: build the D-19 privacy default first, then T1.2. Built `site/mirror/assets/mirror-voice.js` (own file, no shared
  script touched): on-device first, ask once per device before voice goes to Google / Microsoft / Apple, private questions
  (`data-mm-sensitive`) say where the voice goes, "No" and Firefox explain the computer's own dictation, phones keep the
  keyboard mic (one tip). Settings panel `voiceSettings()`. Styles: `.mm-voice*`, `.mm-dialog`, `kbd` (contrast check passes).
- Styleguide shows it: a private question and the settings panel. Assets ?v=20261113a (css, voice).
- Not yet: Read aloud; check on Android, iPhone, Firefox, Edge; screen-reader pass (with T1.2).
- Next: T1.2 public pages + Read aloud.

### 11/13/2026 — Conversation guide preview (D-21, T1.6)
- Stephen asked for open questions -> needs found in the person's words -> a preliminary plan of help connections for the
  Navigator; chose option 1 (phrase matching, no AI service). Built `site/mirror/assets/mirror-listen.js` and the preview
  https://2ndchinc.org/mirror/demo/conversation/ (noindex, not linked; "Fill in an example person" uses a made-up person).
- Checked with the example person against the live directory (simulated office claims, read-only): 8 needs, 4 groups,
  4 private topics held back; programs written for one group only (veterans, seniors, re-entry, HIV, DV survivors) are left
  out unless the person is in that group; youth programs moved down; a program already suggested moves down for later needs.
- Nothing is saved yet: saving waits for T2.1-T2.3 (schema, consents, audit).

### 11/13/2026 — T1.2 public pages + Read aloud
- Pages (noindex, not linked from 2ndchinc.org): https://2ndchinc.org/mirror/ , /about/, /how-it-works/, /life-dimensions/,
  /privacy/ (marked DRAFT), /accessibility/, /forgot-password/ ("Can't sign in?"), /sign-in/ (placeholder: invite only, opens soon).
- Wording from the prompt (Parts 1-3, 9, 12) and Mirror 2 (the mirror, the 38-year-old example). Office contact = public site lines.
- `site/mirror/assets/dimensions.js`: 8 perspectives + 15 dimensions as data, fills [data-mm-list]; T3.1 seeds the same keys.
- Read aloud added to mirror-voice.js (?v=20261113b); conversation preview questions read aloud. CSS ?v=20261113c.
- Checks: link walk all 200 locally; 390 px: no page wider than the screen; keyboard order skip link > wordmark > text size > menu;
  Listen speaks with an on-device voice and stops on a second press. Not run: HTML validator, screen reader, phones, Firefox, Edge.

### 11/13/2026 — Phase 2 T2.1-T2.3 live (migration 20261119150000)
- Schema `mirror`: organizations (2nd Chance seeded as platform owner; `kind` navigator + `navigator_id` for D-20), organization_members,
  profiles, individuals, organization_individuals, consents, role_permissions (59 rows = SECURITY_PLAN matrix), audit_logs (append-only trigger).
- Gate: `mirror.allowed(individual, category, action, org)` returns {ok, role, organization_id, reason} and writes the audit row (members: sensitive
  views, all edits, refusals; never the person's own access). `mirror.require()` raises for writes. Members need aal2; View as refused and logged.
- Check: tools/mirror-checks/t2-identity-check.sql, run with the migration in one transaction that always rolls back
  (.claude-tools/mirror-rollback-check.sh, Stephen OK'd 11/13): 9 of 9 pass. Live after apply: 8 tables, 0 without row security, 0 anon/authenticated grants.
- Next: T2.4 sign-in integration (read live condo_email_on_file, mfa_required, session_role, condo_whoami first), then T1.3 client + sign-in page.

### 11/13/2026 — T2.4 sign-in, stand-alone (D-22, migration 20261119160000, auth-send-email redeployed)
- Stephen asked that nothing in place for everyone else be disturbed. Built: mirror.email_on_file() (invited/active person of an active
  organization, or active member; only while mirror_signin_enabled = on), public.signin_email_on_file() (old list OR Mirror), public.mirror_whoami().
  auth-send-email calls signin_email_on_file and falls back to condo_email_on_file on error. Nothing else changed.
- Check (rolled back on live): 44 known emails give the same answer as before with the switch off and on; Mirror people in/out as designed;
  View as list unchanged; coordinator without authenticator flagged; gate not callable from a browser. Switch is OFF.
- Next: T1.3 Mirror sign-in page + client (own browser session key), then T2.5/T2.6 admin + invite flow. Turning the switch on = Stephen's go.

### 11/13/2026 — T1.3 sign-in page live (commit 7e92a8e)
- /mirror/sign-in/: email -> code (Turnstile, same as the site) -> mirror_whoami -> authenticator for coordinators -> coordinator to
  /mirror/workspace/, person to /mirror/my-mirror/, anyone else "signed in, but not on the Mirror yet". View as refused.
- Uses the site's shared browser session (sch-owner-portal-auth), not a separate one: the code email's Sign in button lands on /sign-in/,
  which only knows the shared session, and D-22 says that page is not changed.
- Menus for "my" and "workspace" now list only built pages; mirror-ui.js ?v=20261113d everywhere.
- Checked live: /mirror/workspace/ with no Mirror sign-in goes to /mirror/sign-in/?next=/mirror/workspace/; no script errors. Not done: a real
  code sign-in (would email a person; needs the switch on and an invited person).
- Next: T2.5 admin (organizations, members) + T2.6 invite flow; then the switch, on Stephen's go.

### 11/13/2026 — Admin + People live (migration 20261119180000, commit 71ab3b6)
- Stephen signed in live as 2ndchinc@gmail.com (Mirror org_admin of 2nd Chance, local-only migration 20261119170000; info@ also admin) and set up its authenticator.
- /mirror/admin/ (organizations, members, roles) and /mirror/workspace/people/ (add, list, end/restart). No email sent anywhere.
- The rolled-back check caught a real gap before it went live: role helpers returned NULL for "no role", and NOT NULL let callers through
  (a Navigator business admin could list 2nd Chance members). Fixed with coalesce(..., false); 6 of 6 pass. mirror.allowed() re-read: not affected.
- Next: invitation email wording for Stephen, /mirror/register/, then the first Mirror questions (T3.1 assessment engine).

### 11/13/2026 — Phase 3 started: T3.1 assessment engine live (migration 20261119190000, commit 3819cdd)
- Stephen: "go back to the prompt" — Phase 2 is done except the invitation email (Phase 9); the prompt's next phase is Phase 3 (Individual Mirror).
- Built: reflections, dimensions, question_sets (8 reflection sets), reflection_questions (9 answer types, privacy category), assessments,
  assessment_responses (append-only trigger; cascade delete with the person only), view current_answers, mirror.clean_answer(),
  mirror_sets / mirror_set_get / mirror_answer_save / mirror_answers_history. Gate: quiet probe (p_table '_probe', mirror.may()).
- The check caught two mistakes before going live (a PL/pgSQL CASE inside IF, and a script edit that collapsed $$); runner now posts from a file.
- Questions: 0 so far (T3.3 writes them). Next: T3.3 question content + T3.2 engine UI + T3.4 reflection pages, so a person can answer.

### 11/13/2026 — T3.2 + T3.3 + T3.4 live (commit d826de9)
- 94 reflection questions (identity 14, history 13, vision 13, assets 12, needs 11, function 12, preferences 10, contribution 9); 9 private
  (health, mental_health, financial). Generated from tools/mirror-checks/reflection-questions.mjs (edit there; new migration for changes).
- assessment-engine.js: one question per screen, all 9 answer types + 4 states, Speak + Read aloud, save on continue, resume, overview,
  earlier answers, offline retry in the tab only. /mirror/my-mirror/ dashboard + 8 reflection pages (today, history, vision, strengths,
  needs, abilities, preferences, contribution).
- Trial: 2ndchinc@gmail.com is also a Mirror person of 2nd Chance ("Stephen (trial)", local-only migration 20261119201000).
- Check t33 (rolled back): 94 loaded, person answers choice/rating/multi, counts right. Not yet walked through signed in (needs Stephen).
- Next: T3.5 fifteen life-area pages (nine-question pattern), T3.6 privacy controls/settings/who looked; then Phase 4 Daily Number.

### 11/13/2026 — T3.5 life areas + hands-free (D-23) live (commit c211080)
- 15 dimension sets x 10 questions (nine-question pattern + help_wanted), generated by tools/mirror-checks/dimension-questions.mjs;
  private areas: physical_health, mental_health, identity_legal (legal), finances, safety; every cost = financial. t35 6/6.
- /mirror/my-mirror/life/ overview + 15 pages (life-area page in reflection-page.js), "Areas of life" in the My Mirror menu.
- Hands-free in assessment-engine.js + mirror-voice.js (canRecognize, voicePermission, hear, speak). Not yet tried with a real voice:
  needs Stephen (Chrome desktop, Android, iPhone). Versions: ui f, voice c, engine b, reflection-page b, css g.
- Next: T3.6 privacy controls + settings + who looked + export; then Phase 4 Daily Number.

### 11/13/2026 — T3.6 live; Phase 3 complete (commit 4dfa760)
- /mirror/my-mirror/settings/: sharing per organization and topic (none / view / edit; general = see while working together, or see and change),
  stop working with an organization, who looked, name/legal name/birth year, safety mode, voice choice, download (JSON) + printable copy,
  deletion request with 30-day hold and cancel. Functions mirror_my_* act only on the caller's own Mirror (mirror.me(), no View as), audited.
- t36 5/5 (two wrong expectations in the check itself corrected: withdrawing closes a row, it does not add one).
- Not built yet: the platform admin's deletion run after 30 days (D-18) and safety-mode effects in the workspace/reports/emails (Phases 8-9).
- Next: Phase 4 Daily Number (T4.1 calculation module with independently calculated examples, T4.2 tables, T4.3 pages, T4.4 cost of being poor).

### 11/13/2026 — Phase 4 Daily Number complete (commits 5acbdd2, 84d55f1)
- T4.1 daily-number.js (D-08) + 13 hand-worked fixtures / 45 figures (the paper's $75.62/day, $1.64, $2.96, $1,520.83/month among them): all pass.
- T4.2 migration 20261119230000: expense_categories (12), living_expenses (level, category, frequency, who pays, poverty_premium), income_sources
  (cash only), noncash_resources (by the category they lower), financial_goals, daily_number_settings (tax rate, household), daily_number_snapshots
  (never changed); mirror.daily_number_calc() = the same arithmetic in SQL (t42: 45/45 + access/history 6/6). Topic "financial" throughout.
- Design choices (from the paper and prompt): four numbers (current, survival, stability, aspirational = stability + goals); who pays per line
  (self / subsidy / assistance / donated); non-cash support lowers only its own category and is never income; gross_needed = cash_needed / (1 - tax),
  tax entered by the person (none assumed); one-time cost spread over m months = amount x 12 / max(m, 12) a year.
- T4.3/T4.4 pages under /mirror/my-mirror/daily-number/ (home, today, survival, stability, aspirations, income, gap, history) and the public
  /mirror/daily-number/ explainer + no-save calculator. Signed-in pages drawn locally with made-up data (client.rpc stubbed): numbers matched.
- Not yet: coordinator view of a person's Daily Number in the workspace (Phase 8); "income opportunities" (paper section 8) belong to Phase 6/7.
- Next: Phase 5 functional and housing assessment (T5.1 ADL/IADL/functional areas, T5.2 housing profile + living options).

### 11/13/2026 — Phase 4 audit and fixes (commit 6e6c1b6, migration 20261119240000)
- Stephen: "You only did a skeleton of phase 4." Audit listed 23 gaps (below). Step 1 (wrong or broken) FIXED and live:
  download/printable include the Daily Number; copy between lists is one all-or-nothing step (mirror_dn_copy); start/end dates on costs,
  income and help that isn't cash (counted only while in effect, "coming up" in 90 days, Starts/Ended tags); savings goals count
  ((target - saved) / ceil(days x 12 / 365) months) in Stability, The life I want, or not counted. Method version 2 (mirror.dn_lines).
  Checks: 58/58 hand-worked figures in JS and SQL; t42 10/10 (incl. impossible-date message, a real fault the check caught); t36 5/5.
- STILL OPEN (Stephen's order: 2 trustworthy, 3 usable, 4 the paper's model, 5 the rest):
  2: resources per level + benefit-cliff warning; tax estimate guidance (benefits untaxed); one "resources available a day" figure;
     history: automatic saves, noncash/tax/goal changes in "what changed", chart over time.
  3: suggested lines / checklist per level (paper's lists); the six Daily Number reflections on the question engine (with hands-free);
     cost-of-being-poor pick-list with cheaper alternatives and likely savings.
  4: income opportunities + "How will I generate my Daily Number?"; benefit and subsidy records (program, renewal/recert dates);
     household (who pays what, contributions); what-if scenarios.
  5: field-level change log for coordinator edits; fuller public calculator; real signed-in walk-through on computer + phone + screen reader;
     bug-check segment for the Daily Number. Depends on later phases: coordinator screen (Phase 8), housing link (Phase 5).

### 11/13/2026 — Phase 4 step 2 "trustworthy" live (commit 0ed1243, migration 20261119250000, method 3)
- applies_to on income_sources and noncash_resources (null = all four numbers); taxable on income (null = by kind: wages, own work, pension taxed).
  Per level: income, untaxed_income, noncash, resources (= income + noncash used + paid for you); gross_needed = (cash needed - untaxed) / (1 - tax).
- Gap page: resources per level; warnings when a benefit counts only today, and when a benefit is still counted at a level with more earnings.
- Income page: "Counts toward" boxes, "Is this income taxed?", rough tax estimate (roughTaxRate, labelled rough) + VITA via 2-1-1.
- Automatic save (mirror.dn_auto_snapshot): only when the numbers on screen were last changed on an EARLIER day, before the first change today;
  never a list still being built today. Snapshots now record the real method version.
- History: "what changed" covers costs, income, help, goals, dates, levels, tax; line chart (Today, Stability per day), colors validated with the
  dataviz script (light #2a78d6/#eb6834, dark #3987e5/#d95926 on #1D242B: all checks pass), legend + end labels, hover/keyboard tooltip.
- Checks: 77/77 hand-worked figures in JS and SQL; t42 13/13 (the check caught the first automatic-save rule saving half-built lists; fixed).
- Known: on a phone the chart's axis text is small (values also in legend, tooltip and save cards).
- Phase 4 still open: steps 3 (usable), 4 (paper's model), 5 (rest) as listed above.

### 11/13/2026 — Phase 4 step 3 "usable" live (commit e822c24, migrations 20261119262000 + 263000)
- Checklists of suggested costs per list (paper's level lists), one press fills the form; ticked when added; "Not for me" per device.
- Six Daily Number reflections (paper section 6) as module question sets dn_today, dn_resources, dn_gap, dn_stable, dn_want, dn_generate
  (24 questions; money "financial", work/training general) on the engine: Reflect tab /mirror/my-mirror/daily-number/reflect/.
- premium_kind (12 kinds + other) on living_expenses; "Does this cost more because money is tight?" pick-list; gap page shows a cheaper way per
  marked cost and a list to add common ones.
- Migration numbers: a peer session used 20261119260000 (mirror_my_help_requests); mine renumbered 262000/263000 and all three applied together.
- A broken string (quotes inside quotes) slipped past node --check (CommonJS parse of an ES module file); caught by the browser import.
  Use "node --input-type=module --check < file" for Mirror modules from now on.
- Checks: t43 3/3, t42 13/13, browser run with made-up data (checklist, pick-list, cheaper ways, Reflect + engine).
- Phase 4 still open: step 4 (income opportunities + "how will I generate", benefit/subsidy records with renewal dates, household, what-if),
  step 5 (coordinator change log, fuller public calculator, real signed-in walk-through, bug-check line).

### 11/13/2026 — Phase 4: one-time costs counted over the months chosen (K-09 option A, method 4, migration 20261119287000)
- Stephen chose A: a one-time cost spread over m months counts amount / m each month, only during those months. $500 over 6 months =
  $83.33/month, $2.74/day (was $41.67, $1.37: spread over at least 12 months and never stopped).
- Ends on start + m months - 1 day (a short month keeps its last day, as Postgres does: Jan 31 + 1 month ends Feb 27), or the line's own end
  date if earlier. mirror.dn_end_on() in SQL = endOn() in daily-number.js; tags "Ended" and "coming up" use it. A one-time cost or
  income saved without a start date starts the day it is saved; the form says so.
- Also fixed: the automatic save recorded method 3 by hand; it now records the method its numbers were calculated with.
- Checks: 90/90 hand-worked figures in JS and SQL (5 new: last day counted, day after, Jan 31 + 1 month, earlier end date); t42 all t
  (8a and 8b now expect method 4); t43 3/3; all rolled back before apply. Scripts: daily-number.js ?v=20261113d, daily-number-page.js ?v=20261113g.
- Saved lines and snapshots unchanged; snapshots keep the method they were calculated with.

### 11/13/2026 — Phase 4 step 4 "the paper's model" live (commits 72f60c8 + this one, migration 20261119290000)
- Household (/mirror/my-mirror/daily-number/household/): household_members; a cost can be paid by "Someone in my household" (paid_by 'household' +
  household_member_id), money from a member is income linked to them; "Who pays what today" table (whoPays() in daily-number.js).
- Benefits (/benefits/): benefit_records with status and applied / approved / renewal / appeal-by / end dates, linked to the line that holds the
  amount (never counted twice). Alerts on Benefits and the Daily Number home: renewal passed, renewal within 60 days (red within 14), appeal within 30.
- My plan (/plan/, "How will I generate my Daily Number?"): income_opportunities (kind, amount before or after taxes, taxed, counts toward,
  may-start date, status, next step). Not counted until "It started" (mirror_dn_save 'opportunity_start'): one step makes a take-home income
  line (amount x (1 - tax rate) when before taxes and taxed). Table: gap now / if these came true / covered (planEffect()). Benefit-cliff warning.
- What if (/what-if/): tick lines that stop, change amounts, add income or a cost, switch plan items on; numbers recalculated in the page
  (whatIf(), withPlan()), nothing saved.
- Fixed on the way: copying a list lost the "could go down" kind; it now keeps it and the household payer.
- Access: everything under the topic "financial" (same rules as the rest of the Daily Number); new tables service_role only, row security on.
- Checks: 120/120 JS figures (step 4: 15 plan / what-if figures, 5 take-home, 4 plan coverage, 6 who pays), 105/105 SQL; t44 6/6 (household,
  benefits, opportunity start, copy, coordinator refused + tables closed + download, deletion); t42 and t43 pass (sessions runner, rolled back).
  Pages drawn locally with made-up data (.claude-tools/dn-stub-server.mjs): plan, It started, benefits add, household, what if, cost form
  household payer, home alerts; numbers matched by hand; no script errors.
- Not done: the printable copy (Settings) does not list household, benefits or opportunities yet (K-10; Settings had another session's
  unsaved edits). The download (mirror_my_export) does include them. Phones: 13 tabs wrap to several rows.
- Migration push: a peer's untracked 20261119284000 was applied with this one (appeared between dry run and push; owner checked, harmless).
  New .claude-tools/push-only.sh pushes only named files.

### 11/13/2026 — Phase 4 step 5: change log of helpers' edits, fuller public calculator

- Change log (migration 20261119345000): table mirror.dn_changes + AFTER row trigger mirror.dn_change_log() on the 8 Daily Number tables
  (costs, income, help that isn't cash, goals, settings, household, benefits, plan items). One line per changed field (added / removed: one line with
  the row). Logged only when the signed-in person is not the person themself (a coordinator or org admin); skipped with nobody signed in and during the
  person's deletion. Read with public.mirror_dn_changes() (money topic, view) and in the download (daily_number.changes); staff named, never their email.
  History page shows "Changes made by someone helping you" (When / Who / Where / What changed). Check t45 6/6 against live (rolled back).
  The migration was applied by another session's push seconds after it was written (before its check); t45 then passed against live, t42-t44 still pass.
- Public calculator (https://2ndchinc.org/mirror/daily-number/): 12 costs, each with how often; pay (before or after taxes), cash benefits, family help,
  other income; tax rate with a rough-rate button; FoodShare, rent help, energy help, phone discount (each covers only its own kind of cost); results:
  Daily Number (week, month, year), coming in each day, short each day or covered, pay before taxes needed and hours a week at a given wage.
  Same arithmetic as the signed-in pages (dailyNumber, level Stability). Example matched by hand: $77.33 a day, $39.22 in, $38.11 short ($1,159.08 a month),
  $1,287.87 before taxes at 10%, 19.8 hours a week at $15; with $600/week pay: covered, $1,187.35 a month to spare. 390px: no sideways scroll; all 43 fields (23 boxes and 20 "how often" lists) labeled.
- Guided Tour (the real signed-in walk-through) deferred until all phases are built (D-28).

### 11/13/2026 — Phase 4: printable copy (K-10) and phone menu

- Printable copy (Settings, dailyNumberPrint): household members (relationship, lives with), who pays a cost or gives income, benefits with status
  and applied / approved / renewal / appeal-by / end dates, plan items with take-home pay, status, may-start date and next step, and the monthly gap
  now and if the open plan items came true (planEffect). Checked on made-up data: Stability gap $557 now, $0 with a $300/week job ($1,170/month take-home).
  Committed only these lines; another session's unsaved needs lines in Settings stay uncommitted.
- Phones (36rem and narrower): the 13 Daily Number tabs become one "Daily Number pages · <this page>" button that opens the list in two columns;
  wider screens keep the tab row. Checked at 390px: one row, 13 links, current page marked, no sideways scroll, no script errors.

### 11/13/2026 — Phase 2 finding C DONE: the Mirror's own sign-out limits (migration 20261119269500)
- Stephen asked whether the plan's numbers (SECURITY_PLAN 2: 1/7 days for members, 30/90 for people) fit real people; they did not cover shared
  devices (library, shelter, borrowed phone) or a coordinator's open laptop. Built (on top of the unchanged, shared session_fresh(), D-22):
  coordinators and admins: screen lock after 15 minutes without activity (authenticator code unlocks; the page is covered, nothing typed is lost),
  signed out after 24 hours unused or 7 days; a person on their own device: 30 days unused / 90 days; a person on a shared device (or not answered):
  30 minutes without activity, and forgotten when the browser closes (session cookie); "remember my email" hidden for shared. Warning 2 minutes
  before a short limit with "Keep me signed in". Sign out asks: here, or everywhere (Supabase global sign-out). After signing in again the page
  returns to the same address, query string included (it used to drop ?id=...). Numbers are portal_settings mirror_session_* (defaults in the migration).
- New: table mirror.device_sessions (no anon/authenticated grants), mirror.session_state/ok/message/limits/device/id, public.mirror_session_touch,
  public.mirror_device_choose. Gates me, signed_in_member_ok, allowed, mirror_who_looked and mirror_whoami use mirror.session_ok() (LIVE bodies, only
  the session lines changed). Page side: site/mirror/assets/mirror-client.js (no page edits needed).
- Form check: every Mirror form saves on its button and question sets save one answer at a time; nothing saves while typing.
- Checks (rolled back): p2-c-session-limits-check.sql 8/8; all 23 earlier Mirror checks re-run. The fix 5 check now records activity for its fresh
  session (a day-old coordinator sign-in with no activity is locked under the new rule). The old runner run-mirror-checks.sh missed errors; a strict runner
  was used instead.
- ACCIDENT: the migration was applied live early, while still uncommitted, by another session's db push (same mistake as 300000 this morning).
  Checked: no later migration redefines these functions, so nothing was overwritten; coordinators could be refused after 15 minutes until the page
  side shipped (person sign-in is off). Rule for every session: push only named migrations (push-one-migration.sh), never --include-all.

### 11/13/2026 — Phase 2 deep-dive: 15 fixes, one at a time (Stephen). Fix 1 of 15 DONE (commit 2face2e, migration 20261119264000)
- The list: 1 invited never becomes active; 2 no-email people dead end (consent on paper); 3 adding by email links an existing Mirror without
  the person's yes; 4 2nd Chance admins can join any organization unseen; 5 Mirror ignores session_fresh; 6 safety flag unused; 7 no org/platform
  audit view; 8 admin pages (teams, roles, consent, email, data) missing; 9 no deletion run after 30 days; 10 no email-change process; 11 no
  authenticator reset for outside coordinators; 12 consent expiry not settable / no reminder; 13 rules in two places (matrix vs admin functions);
  14 audit_logs TRUNCATE not blocked; 15 no rate limits.
- Fix 1: mirror_my_invitations / mirror_my_invitation_answer (own Mirror, audited invitation_accept / invitation_decline); whoami 'invitations';
  My Mirror invitation card (Accept / Decline twice / Decide later); People list "Waiting for them to accept". Check p2-fix01 4/4.
- Applied together with the peer's 20261119270000_mirror_answer_clear (Stephen OK'd). Migration numbers: this session 264000-269999.

### 11/13/2026 — Phase 2 fix 5 of 15 DONE (commit b0c3ed9, migration 20261119269000)
- The Mirror's gates checked only that an email was present, so a remembered device past its idle/maximum days (or signed out everywhere)
  kept working in the Mirror. Now mirror.me(), mirror.signed_in_member_ok() (so my_role / is_platform_admin), mirror.allowed() and
  mirror_who_looked() require public.session_fresh(); mirror_whoami answers signed_in=false, expired=true, so pages ask for a new code.
  Generated from the LIVE bodies with only the session lines added (re-compared with live just before applying: identical). D-22 kept.
- Check p2-fix05 (rolled back, real fictional auth sessions) 5/5. All 16 earlier Mirror checks pass with it.
- FOR EVERY CHECK FROM NOW ON: fictional sign-ins with 'session_id', gen_random_uuid() are now (correctly) expired. Run older checks with
  .claude-tools/mirror-rollback-check-sessions.sh, which swaps in a real fictional session inside the rolled-back transaction.
  (A token with no session_id is treated as View as by autopay_view_as_session, so dropping the id is not an option.)
- Session lengths: Mirror people and non-staff coordinators fall under session_role 'investor' (45 idle / 180 max days); 2nd Chance
  staff under 'staff' (14 / 30). Not changed (D-22); shorter Mirror limits would be Stephen's call.
- MISTAKE: the push also applied another session's uncommitted Phase 5 migration 20261119300000_mirror_functional_housing.sql, which
  appeared between the dry run and the push. Checked after: its 6 tables are empty, row security on, no anon/authenticated grants; no
  Mirror function is anon-callable; its seed 20261119301000 was NOT applied. All sessions were messaged not to push it again.

### 11/13/2026 — Phase 2 fix 4 of 15 DONE (commit c91d7fc, migration 20261119268000)
- Read on live: mirror.can_manage_members() let a platform admin save members of ANY organization, their own email included, which opens
  that organization's people to them; the only trace was an audit row the organization cannot see.
- Now a platform admin acting where they are not the organization's own admin (mirror.platform_outside) cannot add, reactivate or promote
  themselves, or change a member's email to their own; every member they add or change there is marked (platform_changed_at / _by) and
  /mirror/admin/ shows "Added or changed by <name> (2nd Chance), <date>". Setting up a new organization's members still works.
- Check p2-fix04 (rolled back) 5/5; t25 still 6/6. Live: 0 members marked (only 2nd Chance exists). Site published; applied ALONE
  (another session's uncommitted 20261119287000 left out; it does not touch these tables).
- Chosen default, not asked: 2nd Chance may still add OTHER people to an organization that has its own admin (visible now). A stricter
  rule (only the first admin) is a one-line change if Stephen wants it.

### 11/13/2026 — Phase 2 fix 3 of 15 DONE (commit ca6c8f4, migration 20261119267000)
- Read on live first. Since fix 1 an invited person's answers were already closed; three gaps remained and are closed:
  1. mirror_person_status let a coordinator set ANY link to active (skipping the yes). Now active only for people with no email;
     invited only for people with an email.
  2. mirror_people showed an existing Mirror's own name, legal name, birth year and safety flag to an organization that had only
     invited them (or that they declined), which also revealed the email had a Mirror. Now, until the person accepts (audit
     invitation_accept) or unless the organization created the record (mirror.known_to_org), only the typed name
     (organization_individuals.invited_name) and the email show.
  3. mirror_person_add kept the typed name and answers the same whether the email had a Mirror or not.
- Check p2-fix03 (rolled back) 6/6; p2-fix01 4/4, t25 6/6, p2-fix02 5/5 still pass. No page change needed (People page already handles
  an empty legal name; the person page opens only active people).
- Applied ALONE: another session's uncommitted 20261119280000 and 20261119281000 were left out (they do not touch these functions).

### 11/13/2026 — Phase 2 fix 2 of 15 DONE (commit a69df77, migration 20261119265000)
- Built by an earlier session (idle since 00:34); taken over and finished by this one at Stephen's request.
- Read against live first: consents columns and checks, mirror.coordinates / my_role / me / audit exist; the live mirror_my_settings body was
  unchanged by later migrations, so the new body is the old one plus `sharing_detail`. Check p2-fix02 (rolled back) 5/5.
- Gap closed before shipping: the migration promised Settings would show "recorded by ..., on paper" but no page displayed it.
  /mirror/my-mirror/settings/ now shows "Recorded for you by <name>, on paper / out loud, on <date>. You can change it here."
- Live: consents.method + note, mirror_consent_record, mirror_consents_recorded, new settings body; 0 consents rows (nothing recorded yet);
  /mirror/workspace/person/ 200 and noindex, People list "Open their Mirror", Settings text present. Inline scripts pass node --check.
- Not done: a signed-in browser run of the coordinator page (needs Stephen's sign-in and authenticator).

### 11/13/2026 — Phase 2 fix 14 of 15 DONE (migration 20261119266000)
- Checked first (read-only): TRUNCATE on mirror.audit_logs was held by postgres (owner) and service_role; anon/authenticated hold nothing.
  The append-only trigger covered UPDATE/DELETE only. Fix: revoke TRUNCATE from service_role + statement trigger `audit_logs_no_truncate`
  refuses TRUNCATE for everyone. Check p2-fix14 (rolled back) 4/4. Live after apply: service_role ACL has no D, trigger present, 0 rows touched.
- Applied ALONE from a temporary copy of the migrations folder (.claude-tools/push-one-migration.sh) so fix 2's unfinished, uncommitted
  20261119265000_mirror_recorded_consent.sql was NOT pushed. A plain `db push --include-all` would push it: watch for that.
- Open: fixes 3-13, 15 (fix 2 since done, see above).

### 11/13/2026 — Phase 1 examination and fixes
- Examined Phase 1 against the roadmap (read-only): contrast 68 of 68 pairs pass; 9 Mirror modules pass `node --input-type=module --check`,
  all carry `// @ts-check`; 14 pages and 6 assets answer 200 live, every page noindex; outside hosts: Google Fonts, Cloudflare Turnstile on sign-in, and supabase-js from cdn.jsdelivr.net via the shared portal.js (the first check searched site/mirror only and missed the last two); no main-site link to /mirror/.
- Fixed: daily-number-page.js imported assessment-engine.js?v=20261113i while every other page used j (two copies of the engine, the older
  one possibly cached); now j, and daily-number-page.js bumped to ?v=20261113f on its 9 pages. The office email on /mirror/privacy/ and
  /mirror/accessibility/ was rewritten by Cloudflare email protection into /cdn-cgi/l/email-protection (404 without JavaScript); wrapped in
  `<!--email_off-->` so it stays a plain mailto link. Status header above brought up to date. T1.4 written: CONVENTIONS.md.
- Still open in Phase 1: T1.5 checks on Android, iPhone, Firefox, Edge; screen-reader pass; HTML validator; a real code sign-in (switch off);
  T1.6 saving. Noted, not changed: 19 signed-in pages start their module with a short inline `<script type="module">`. That is fine under
  today's CSP (frame-ancestors only) but must move to files before any `script-src` rule is added.
- Re-verified the same day (.claude-tools/mirror-p1-verify.sh, read-only): contrast 68/68; 9/9 modules pass syntax and carry @ts-check;
  all 49 committed Mirror pages answer 200 live with noindex and match HEAD (privacy/accessibility differ only because Cloudflare strips
  the email_off comments; mailto present, no /cdn-cgi/ link); all 10 versioned asset URLs serve HEAD's file; live link walk all 200; 0 main-site
  links to /mirror/; mirror_signin_enabled off; mirror_whoami and signin_email_on_file are security definer. /mirror/workspace/person/ 404 is
  another session's uncommitted page (nothing committed links to it). Found: supabase-js loads from cdn.jsdelivr.net with a floating `@2`
  version in the shared portal.js (not a Mirror file; left as is, noted in CONVENTIONS.md).

### 11/13/2026 — Phase 3 analysis fixes 7 and 8 (commit f26b344, migrations 20261119280000 + 20261119281000, applied)
- Fix 7: `mirror_answer_save` returned answered/question counts that included private questions a coordinator may not see (only the
  count, never the answer). Counts now cover only categories the caller may view (quiet `mirror.may` probe, as `mirror_sets`); the
  answering screen counts on its own, so nothing on screen changes. Check p3-fix07 (rolled back) 5/5.
- Fix 8: service_role lost TRUNCATE on mirror.assessment_responses; statement trigger `assessment_responses_no_truncate` refuses
  TRUNCATE for everyone, directly or by cascade from mirror.assessments. Whole-Mirror DELETE still cascades. Check p3-fix08 (rolled back) 4/4.
- Live after apply: save function carries the fix, grants unchanged (authenticated, service_role); table ACL service_role=arwdxtm (no D);
  trigger present; 14 answers untouched.
- Found: refused attempts' log rows are undone with the error (P3-11 in KNOWN_ISSUES.md). The first run of the fix 7 check expected that
  row; the expectation was corrected to measure the successful save only.
- Applied with a plain `db push` after the dry run listed only these two files (another session's 20261119267000 was already applied).
- Browser pass, same day (Chrome, signed in as Stephen, read-only; Tab presses only):
  - Width: all 49 committed pages at 320 and 390 px (98 frames): 0 with sideways scroll. The only elements past the edge are table headers
    and screen-reader labels clipped to 1 px on purpose (People page checked).
  - Keyboard: real Tab presses on 17 pages (8 public, daily-number, demo/conversation, styleguide, my-mirror, today, settings,
    workspace, people, admin): skip link first on every page, every visible control reached, every one shows a focus ring and
    :focus-visible. Enter on the skip link moves focus to main; the next Tab lands inside main.
  - Structure (stand-in for a screen reader, not one): all 49 pages have lang en, a title, one h1, one main, images with alt.
    Fixed: /mirror/life-dimensions/ went h1 > h3 (screen-reader-only h2 "The fifteen areas" added). Found, outside Phase 1, not changed:
    /mirror/admin/ two role selects have no label (Phase 2); /mirror/my-mirror/daily-number/income/ repeats ids inKind, inLabel, inAmt,
    inFreq, inTimesWrap (Phase 4); h1 > h3 on /mirror/my-mirror/life/ (Phase 3) and /mirror/my-mirror/daily-number/reflect/ (Phase 4).
  - Firefox (headless, real Gecko engine): the 9 public pages + styleguide at 320 and 390 px render with no cut-off text; demo/conversation
    did not finish (headless hung). Edge headless screenshots are not valid (window not narrowed to 320); Edge uses Chrome's engine,
    whose check passed, but Edge itself is not verified.
  - Still not done: HTML validator (none installed; needs a download or sending pages to the W3C service), a real screen reader,
    Speak/Read aloud on phones, Firefox and Edge, a real code sign-in (switch off), the signed-out sign-in page (this browser is signed in).

### 11/13/2026 — Phase 3 analysis fix 6: question versions (commit e12a0bc, migration 20261119282000, live)
- Rewording a question would have changed the meaning of answers already given (answers pointed at the question, not the wording).
- Built: `reflection_questions.version`; `mirror.question_versions` (every wording: prompt, help, answer type, choices, topic; append-only,
  no TRUNCATE, service_role only); a change to any of those raises the version by trigger and records it (sort-only changes and hand-set
  versions do not); `assessment_responses.question_version` set on insert from the current version, foreign key to the wording; the
  append-only rule now also keeps question_version and answered_by_role; `mirror_answers_history` returns version, question then,
  answer type and choices then, `reworded`; `mirror_my_export` gives each answer the wording it was given to (+ question_version).
- Checks (rolled back): p3-fix06 6/6 (first run's step 5 tried to "change" the version to the value it already had; check corrected).
  Re-run on top: p3-fix07 5/5, p3-fix08 4/4, t31 9/9, t36 5/5.
- Applied 11/13 by session lease-ec's push together with its 20261119287000 (the file as committed here). Live: 268 wording rows, 268
  questions and 14 answers on version 1, 5 triggers, the foreign key, both functions updated, service_role without TRUNCATE.
- Rewording a question from now on: an UPDATE migration on reflection_questions (the generators insert with `on conflict do nothing`);
  the version and wording history follow by themselves.
- Not done (P3-06b): the answering screen does not use the new history fields yet.

### 11/13/2026 — Phase 3 analysis fix 5 (email choices) and fix 10 (sitemap) (commit 6a1ef82, migration 20261119283000, live)
- Fix 5: T3.6 promised notification choices; none existed. Settings now has "Emails from the Mirror": referral updates, appointment
  reminders, reminders about your plan (on/off, default on, D-25); sign-in codes and security notices always sent; safety mode stops all
  three. The page says the Mirror sends no emails yet. Functions mirror_my_notifications / mirror_my_notifications_set (own Mirror only,
  mirror.me(), logged as 'notifications'); choices stored in mirror.profiles.notification_prefs (row made on first save).
  mirror.notification_ok(email, kind) (service_role only) is the one check Phase 9 must ask before queueing any Mirror email to a person.
- Fix 10: SITEMAP.md section B now lists life/ and the 15 built area routes, maps the prompt's personal-development names to them
  (health = physical-health + mental-health; education and employment = work; daily-living = life-skills), and the settings row says what is there.
- Check p3-fix05 (rolled back, fresh sessions via mirror-rollback-check-sessions.sh) 6/6. Settings page module passes a syntax check.
- Applied alone with .claude-tools/push-except.sh (left out the Phase 5 session's uncommitted 20261119301000 and 302000). Live: both
  person functions callable by authenticated + service_role, notification_ok and the defaults by service_role only. Site deployed from
  HEAD; /mirror/my-mirror/settings/ answers 200 with the new section.
- Not done: the signed-in Settings page was not drawn with real data (needs a sign-in); the new section has not been seen on a screen.
- HTML validator, same day (Stephen's go): html-validate 11.21.1 (npm, installed in a scratch folder with --ignore-scripts, not in the repo),
  rules html-validate:standard + html-validate:a11y, over all 54 committed Mirror pages (.claude-tools/mirror-html-validate.sh).
  First run: 2 errors, both wcag/h32 "form must have a submit button": the public Daily Number example (/mirror/daily-number/) and the
  styleguide's sample question. Neither form submits anything: in Chrome, Enter in the example left the page and address unchanged,
  and its 10 fields have no name. Both marked as intended exceptions with the reason in the page source. Second run: 0 errors.
  Limit: it checks the HTML as written; content that scripts build after load was covered only by the structure sweep above.

### 11/13/2026 — Phase 5 functional and housing assessment (commit c89e16e; migrations 20261119300000, 301000, 302000; session range 300000-309999)
- Stephen: "Execute phase 5 with precision now." Source: MASTER_ROADMAP T5.1/T5.2, DATABASE_DESIGN (functional + housing tables), SITEMAP.
  The prompt's own Part 5 text is not in the repo; the list of the "11 other areas" is therefore a DEFAULT (D-26), for Stephen to confirm.
- T5.1: `mirror.functional_assessments` (one check-in, by the person or by a helper with the person; one open check-in each; finished
  check-ins never change, trigger), `adl_assessments` (6 activities) and `iadl_assessments` (8), each with level, the person's own
  preference beside it, and a note. 11 functional areas = question sets of kind `functional` (reflection `function`), 5 questions each
  (55), topics health / mental_health / general as listed in D-26. Pages: /mirror/my-mirror/abilities/activities/ and
  /mirror/my-mirror/abilities/areas/ (?a=<area>), linked from /mirror/my-mirror/abilities/ and the dashboard. Everything says it is not a diagnosis.
- T5.2: `housing_options` (7, seeded from site/mirror/assets/living-options.js), `housing_profiles` (where I live now, options I want to
  learn about, barriers, accessibility needs), `housing_history`. Legal parts (jail, eviction, criminal record) and health parts (care
  setting, hospital, accessibility needs, "fits my needs") are left out for a helper without that topic and kept unchanged by their saves.
  A person can mark any history line private by topic. Pages: /mirror/my-mirror/living/ and public /mirror/living-options/ (no database).
- "Professional review needed": set only by a helper (organization member with edit on that topic), never by the person, never automatic;
  the person sees it with what it means. Nothing recommends a setting. The coordinator page /mirror/workspace/person/ has both parts and the 11 areas.
- Functions (all security definer, fixed search_path, authenticated + service_role, not anon): mirror_fa_get/save/finish/review,
  mirror_housing_get/save/history_save/history_delete/review, mirror_my_export_living. Tables: service_role only, row security on.
- One source of truth: site/mirror/assets/functional-data.js and living-options.js feed the pages and tools/mirror-checks/phase5-seed.mjs
  (generates 301000; edit the data files, never the SQL).
- 300000 went live early: another session (Phase 2 fix 5) pushed it while it was still uncommitted, before three review fixes. The file is
  kept exactly as applied; 302000 carries the two real fixes (a helper's page load logged a "refused" row for every topic never shared,
  now a quiet probe first; the download kept internal option ids). The third edit was a variable rename with no effect.
- Check tools/mirror-checks/t5-functional-housing-check.sql, run with mirror-rollback-check-sessions.sh: 8/8 on seed+fix, and 8/8 again
  against live after apply. Step 4 fails without 302000 (confirmed), so it guards the fix. Live after apply: 11 sets, 55 questions with
  55 version rows, 7 options, both fixes present, 0 Phase 5 rows. Site deployed from HEAD: 7 pages 200, 4 assets match HEAD, noindex;
  public page draws 7 cards in Chrome, no sideways scroll.
- Follow-up 11/13/2026 (Stephen: "your 11 areas are confirmed, remove the overlap, leave real walk-through for now"): D-26 DECIDED.
  Migration 20261119303000 retires 9 Function reflection questions that Everyday activities asks in full (meals, shopping, medicine,
  bills, getting around, housekeeping, laundry, phone/computer, bathing and dressing); kept: paperwork, appointments, the open question.
  Retired = active false, so the version history stays; no one had answered them. Set intro reworded. t33 check now saves paperwork.
  P5-01 deferred; it is now the Guided Tour (deferred, D-28).
- 11/13/2026: t5 step 6 flipped to f on live (reported by the Phase 2 session). Cause: mirror_fa_get / mirror_fa_review picked "the latest
  check-in" by started_at alone; check-ins started in one transaction tie, so the review mark and the page could read different rows.
  Migration 20261119304000 orders newest first, then id, in both. No effect on real use (two check-ins never start in one transaction).
  t5 8/8 against live after apply.
- Not done (KNOWN_ISSUES P5-01 to P5-04): no signed-in page was drawn with real data (switch off); Settings' full download and printable
  copy do not yet include Phase 5 (own download button on the two pages instead; the Settings page was being edited by the Phase 3 session).

### 11/13/2026 — Phase 6 T6.2 strengths inventory (migration 20261119330000; session range 330000-339999)
- Stephen: "Another session is doing T6.1 so go for T6.2 now." Card: a list beside the needs (skills, talents, experience, credentials,
  languages, interests, relationships) that builds on the "What do I have within me?" reflection.
- Migration 330000: mirror.strengths (kind, title <= 120, details <= 1000, optional area of life; privacy topic from the area, no area =
  everyday; added by self or coordinator) and mirror.strength_dismissals; grants service_role only, row security on, no bulk emptying.
  Functions: mirror_strengths, mirror_strength_suggestions, mirror_strength_save, mirror_strength_delete, mirror_strength_dismiss,
  mirror_my_export_strengths (mirror_my_export unchanged). Every read and write passes the one gate (mirror.allowed / mirror.may).
- Suggestions come from answers already given (reflection_assets, reflection_history, reflection_contribution): chosen skills by label,
  languages split, finished schooling as a credential, written answers split at line breaks, commas and semicolons. Nothing is added by
  itself; "Not mine" hides one for good; a saved or same-title strength removes its suggestion.
- Page /mirror/my-mirror/my-strengths/ (list by kind, add/change/remove, "From your answers" panel) + link on the My Mirror dashboard.
- Checks: t62 6/6 on live, rolled back (uses real fictional sign-in rows, since fix 5 is live). Page driven headless in Chrome with a
  stubbed client: load, add suggestion, "Not mine", change-then-add, add by hand (kind required), edit, remove; no script errors.
- Not done: Settings' full download and printable copy do not yet call mirror_my_export_strengths (Settings has another session's
  uncommitted edits); the coordinator's person page does not show strengths yet (with the full workspace, Phase 8).

### 11/13/2026 — P3-11: refused attempts are now kept in the log (migrations 20261119284000 + 285000, commits 990d1e6, 7af9088, live)
- Problem: mirror.allowed() logged 'refused', then the caller's error undid that row; "Who looked" could never show a refusal that ended
  in an error (18 functions across Phases 3-5). Stephen chose "Separate write".
- Built: login role `mirror_refusal_writer` (no inherit, connection limit 3, statement timeout 3 s; password made inside the database and
  stored only in Vault as `mirror_refusal_writer_password`); `mirror.audit_refusal_write()` (only 'refused', only for a person who exists,
  only reasons view_as / no_authenticator / no_consent) is all it can do; `mirror.audit_refused()` writes through dblink and falls back to
  the in-transaction log; mirror.allowed's three refusal log calls use it (rest of the live body unchanged).
- 284000 was applied early by another session's push. Live it did not work: localhost lets connections in without a password, which
  dblink refuses for a non-superuser, so every refusal took the fallback (same as before). Also its dblink functions stayed executable
  by PUBLIC (they belong to the Supabase superuser). 285000 fixes both: the connection goes through the Supabase pooler (transaction
  mode, TLS required; 40 ms in a rolled-back try), and dblink was reinstalled in private schema `mirror_link` (no USAGE for anon,
  authenticated, service_role).
- Checks (rolled back): p3-fix11 5/5 (first run: check 1 false on the PUBLIC dblink grants, fixed by 285000), p3-fix11b 4/4 over the real
  pooler (asks only things that cannot add a row; writer refused reading the log and the people); re-run on top: p3-fix07 5/5,
  t31 9/9, t36 5/5. Live: dblink in mirror_link, no USAGE for anon/authenticated, `mirror.refusal_channel_ok()` = ok, gate uses it.
- Not checked end to end: a real refusal against a real person (it would leave a permanent "tried to open" row on that person's Mirror).
  Each refusal now costs one pooler connection (~40 ms). Bug-check segment 7 now checks the channel.
- Step A, same day (.claude-tools/mirror-edge-check.mjs: real headless Edge 157, fresh signed-out profile, driven over DevTools, screen set
  to 320 and 390 px; read-only, nothing submitted): the 12 Phase 1 pages (8 public, sign-in, styleguide, demo/conversation, plus the
  My Mirror and Workspace landings) = 24 checks, 0 with sideways scroll, 0 script errors. Signed out, /mirror/my-mirror/ and /mirror/workspace/
  go to /mirror/sign-in/?next=... . Sign-in page signed out: labelled email field ("Your email address", autocomplete email), "Remember my
  email on this device", one button "Email me a code", invite-only wording and office phone; Turnstile loads only when the button is
  pressed (turnstileToken() in mirror-client.js), by design. A gap before the full stop after the phone link in the Edge 320 px
  screenshot is not in the page (live HTML has none); left as is. Edge at phone width is now verified.
- D-28 (Stephen 11/13/2026): the Guided Tour (real signed-in walk-through on devices, voice, screen reader, real code sign-in) waits until
  all phases are built. Phase 1 is therefore "built and live, Guided Tour pending"; its only build item left is T1.6 saving.

### 11/13/2026 — T6.1 examined; Phase 6 T6.3 goals, steps, milestones (migration 20261119331000)
- Stephen: "Before you start T6.3 examine and report on T6.1. After the report begin T6.3."
- T6.1 report (read-only + t61 rolled back on live, 9/9): database live (320000, applied by Stephen's db push, which also put the uncommitted
  269500 and 345000 live; their owners were told). Page committed (e802344) but not yet deployed when examined. Findings for Stephen:
  (1) coordinators get a count of hidden private needs (also in T6.2 strengths); (2) a need can never be removed, only "no longer needed";
  (3) no suggestions from answers already given; (4) D-27 waits; (5) a coordinator's word changes are not in the need's history;
  (6) /needs/ vs /my-needs/ names; (7) bug check did not cover Phase 6 (now added to segment 12).
- T6.3 migration 331000: mirror.goals (area, stage 1-6 label or none, optional hope-by date, status active/paused/achieved/let_go),
  mirror.action_items (for one goal, one need or neither; me or a named helper; to do/done/not doing; takes the goal's or need's topic),
  mirror.milestones (reaching a goal adds one; organizations may confirm; editing words/date removes the confirmation). Service_role only,
  row security on, no bulk emptying, same-person triggers. Functions: mirror_plan, mirror_goal_save, mirror_action_save,
  mirror_milestone_save, mirror_milestone_confirm, mirror_plan_delete (person only), mirror_my_export_plan. Decisions in D-29 (confirmed by Stephen 11/13).
- Pages /mirror/my-mirror/plan/ (goals by stage with their steps), actions/ (mine / others doing for me / done / not doing), milestones/;
  one module site/mirror/assets/plan-page.js. My Mirror link. Settings download and printable copy now include strengths (T6.2 open item)
  and goals, steps and milestones.
- Checks: t63 6/6 on live, rolled back. The three pages driven headless in Chrome with a stubbed client (add, refuse empty, step for a goal,
  mark done, reached, edit, remove; steps with a helper and for a need; milestones add/edit/remove): no script errors, no duplicate ids.

### 11/13/2026 — P3-06b: the answering screen shows the wording each answer was given to (commit 9e19aa9, migration 20261119286000, live)
- Database: mirror.current_answers gains question_version (added last; the other 10 columns unchanged); mirror_set_get (live body)
  returns each question's version and each answer's version + reworded.
- Engine (assessment-engine.js): when the question was reworded after the answer, the question screen shows a note ("worded differently
  when you answered it") and the list says "(answered to an earlier wording)"; Earlier answers shows each answer using the answer type
  and choices of its own wording, plus "The question then: ..." when it differs.
- Versions (Stephen: "only push your work"): engine ?v=20261113k in reflection-page.js, and reflection-page.js ?v=20261113k in its 25
  Phase 3 pages (none loads another engine user, none had other sessions' edits). Not bumped: daily-number-page.js (Phase 4),
  functional-page.js (Phase 5), workspace/person (Phase 2) still import ?v=20261113j; Pages serves the new file at that URL too, so they
  get it once the 4-hour browser cache expires or at their owners' next bump.
- Check p3-fix06b (rolled back) 4/4; re-run on top: p3-fix06 6/6 (323 questions now, all versioned), p3-fix07 5/5, t31 9/9. Engine and
  reflection-page.js pass a module syntax check. Live: both assets served at ?v=20261113k, pages load them, life/housing 200.
- 286000 was applied by another session's push before mine (the file was not edited after it was built; live has the view column and
  the new function). On screen with real data: Guided Tour (deferred, D-28).
- Phase 3 list from the 11/13 analysis is now closed except the Guided Tour (deferred, D-28).
- 11/13 later: Stephen confirmed D-29 (all five points). Point 5 applied to strengths too: migration 20261119332000 drops the 'hidden'
  count from mirror_strengths (t62 updated, 6/6 rolled back). lease-9b asked to do the same for needs (mirror_needs_list, t61 part 2).
- 11/13 later: Stephen decided T6.1 finding 2 (D-30): people can remove their own needs. Migration 20261119333000 (mirror_need_delete, person only;
  needs_no_delete lets through only that function's own removal or a whole-Mirror delete). Remove link with an "are you sure" on
  /mirror/my-mirror/my-needs/. Checks: t61c 3/3 and t61 9/9 rolled back with it; page driven headless (confirm, keep, remove), no errors.
  Stephen also confirmed D-27 ("confirmed D-27 = go").
- Update (later 11/13): commit f8fe27e (another session) moved every engine user to ?v=20261113p; that engine carries P3-06b (checked live: daily-number-page.js and reflection-page.js both import it).

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
- Not done: Guided Tour (D-28). D-31 CONFIRMED by Stephen 11/13/2026 ("confirm D-31"); the built defaults stand unchanged.
- 11/13 later (lease-bc, Stephen: "you do it now"): migration 20261119360000 was committed (46fad0b) but NOT applied and the pages not
  deployed (the session's apply step was blocked). t16 re-run 9/9 rolled back on live, then applied with push-committed.sh --yes 20261119360000
  (dry run listed only it); site deployed after the migration.

### 11/13/2026 — Phase 2 finding E DONE: platform admins are an explicit list (migration 20261119269700)
- Built and held by the Phase 2 session until Stephen's OK; released 11/13 by lease-bc (Stephen: "(b) OK"). Page and checks rebuilt from the
  current files (make-seq-E-page.mjs, make-seq-E-checks.mjs) before copying.
- mirror.platform_admins (row security on, service_role only), first list = everyone who had the power under the old rule; mirror.is_platform_admin()
  now needs the list AND an active 2nd Chance membership AND the authenticator; only the main admin (portal_admins) adds or removes, every change
  audited, list never empty. /mirror/admin/ shows "2nd Chance platform admins".
- Checks rolled back with E: p2-e 7/7, t25 6/6, p2-fix04 5/5, t16 9/9, t5 8/8; every other Mirror check gives the same counts with and without E.

### 11/13/2026 — Phase 6 finish: T6.4 progress page and P5-02 (Stephen: "You will do 'PHASE 6 FINISH'")
- Migration 20261119365000_mirror_progress.sql: `public.mirror_progress(p_individual)` (security definer, fixed search_path, authenticated only).
  Counts per area of life (needs working on / got / confirmed, goals working toward / reached, steps done / to do, milestones, strengths), a
  "not tied to one area" row, and 12 months of history (needs noted / got / confirmed, steps done, goals reached, milestones). D-09: counts
  only, no score, percent or rank. An area whose topic the viewer may not see comes back "not shared" with no counts (no hidden count).
  No new tables. Looks at a topic that holds records are logged (table_name 'progress').
- Page /mirror/my-mirror/progress/ (progress-page.js ?v=20261113a; `progressBox(el, individual)` is ready for the coordinator's overview, T8.2);
  link on the My Mirror home.
- P5-02: Settings' "Download a file" adds `living` (mirror_my_export_living); the printable copy adds "Everyday activities and where I live"
  (latest sitting, where I live, where I have lived); the "Download everything" sentence names them.
- Checks: t64 5/5 rolled back on live (counts per area, coordinator sees 5 private areas "not shared" without counts, health shared and
  confirmed by the coordinator, no-authenticator refused, person B isolated, a reopened step no longer counts, closed to anon, looks logged).
  Module syntax ok on the 3 touched pages; html-validate: only the house-style lowercase doctype note.
- Step 3: Stephen answered YES (11/13/2026); built the same day, see the next entry. Guided Tour (D-28).

### 11/13/2026 — Phase 6 finish step 3: goal suggestions from the Vision reflection (Stephen: "YES")
- Migration 20261119366000_mirror_goal_suggestions.sql: goals.from_key; mirror.goal_suggestion_dismissals (row security, service_role only);
  mirror.vision_dimension (question -> area), mirror.goal_suggestions_for; public mirror_goal_suggestions, mirror_goal_add_suggested(key, title,
  area), mirror_goal_suggestion_dismiss; mirror_my_export_plan now marks `from_your_answers` and lists `goals_set_aside`.
- Rules: current, answered, non-empty Vision answers only, one idea per question (vision:<question>); title = the person's words (cut at 200
  with "…"; the whole answer kept as details), money -> "Earn about $N a month"; health and money answers always land in their private area;
  "A year from now" and "own one day" have no area (the person picks); no stage suggested; person only; added or "Not now" ideas never return.
- Page: "Ideas from your answers" on /mirror/my-mirror/plan/ (labeled Suggested; words editable before adding); plan-page.js ?v=20261113q on
  plan/, actions/, milestones/.
- Checks rolled back with the migration: t63b 4/4 (new), t63 6/6, t64 5/5. plan-page.js syntax ok.

### 11/13/2026 — Phase 8 T8.1: workspace dashboard and people list, with P2-07 (Stephen: "Now you work ONLY on phase 8 - go")
- Migration 20261119500000_mirror_workspace_dashboard.sql (functions only, no new tables): mirror.org_sees (the topics one organization may see
  for a person, quiet probe), mirror.log_private_looks; public mirror_workspace_dashboard(org) (urgent open needs, open steps with a hope-by
  date this week or passed, "I'd like help with this" answers, people counts), mirror_people_counts(org) (open/urgent needs, steps to do,
  goals per active known person), mirror_org_audit(org, before, person) (P2-07: org admins; names never emails; unknown people unnamed;
  reading is logged; 100 per page).
- Rules: coordinators and org admins with the authenticator; only active people the organization knows; every item through the gate for THAT
  organization; private topics only where shared, each private look logged for the person; no hidden counts; "hope-by", never "late".
- Pages: /mirror/workspace/ (dashboard, organization picker), /mirror/workspace/people/ (search, show filter incl. "with an urgent need",
  counts columns), /mirror/workspace/audit/ (new; organization admins).
- Checks: t81 6/6 rolled back on live. Module syntax ok on the 3 pages; html-validate: only the house-style doctype note.
- Not yet: appointments on the dashboard (T8.5); P2-06 safety banner and the one-person overview (T8.2); platform view of every
  organization's log (P2-08).

### 11/13/2026 — Phase 8 T8.2: one-person overview, with P2-06 and T6.1 findings 5 and 6 (Stephen: "go")
- Migration 20261119510000_mirror_person_overview.sql: mirror_need_save writes a need_events line (status kept) when someone other than the
  person changes a need's words, details, area or urgency, naming what changed and what the words were (finding 5); the Needs and Assets
  reflection intros say where the lists are (finding 6). No new tables.
- Page /mirror/workspace/person/ (workspace-person.js ?v=20261113a): safety note when the person has safety mode on (P2-06), Needs (history,
  change where it stands with a note, change the words, "Confirm it's met"), Plan (goals with steps, other steps, milestones with Confirm /
  Take back), Strengths (read only), Progress (progressBox; the own-page links now show only to the person, progress-page.js ?v=20261113b).
  People list: "Safety mode" tag. Person side: "My needs list" / "My strengths list" with links to the questions; history shows "changed";
  Settings says coordinators now see the safety note.
- Checks: t82 5/5 rolled back on live; with the migration t61, t61b, t61c, t63, t64, t81, t16 all still pass (0 failed parts).
  Module syntax ok; html-validate on 7 touched pages: only the house-style doctype note.
- Not yet: coordinators adding goals/steps from the overview (they can on the person's pages only through the person); reports leaving out
  safety-mode records (T8.8).

### 11/13/2026 — Phase 8 T8.3: assessments with the person (Stephen: "go to the next task in building the mirror")
- Going over questions with the person already worked (one-person overview, "Their Mirror": mirror_answer_save with p_individual, the
  person sees "by your coordinator"). T8.3 adds the review. Migration 20261119530000_mirror_assessments_with_person.sql:
  public.mirror_assessments_review(org, individual) (coordinators with the authenticator; active, known people only): per person or per
  question set, counts and dates only: answers, asked for help, saved with you (still their answer), last time together, days together,
  changed or added by them since. Never answer words, never earlier answers (person only, 20261119271000); topics they keep private are
  not counted (a set only says some questions are private); private topics counted are logged as looks ('workspace_assessments'). No new tables.
- Pages: new https://2ndchinc.org/mirror/workspace/assessments/ ("Questions together", linked from the dashboard); on
  /mirror/workspace/person/ each question-set card shows last together / changed since / asked for help, with a how-to line.
- Checks: t83 6/6 rolled back on live. html-validate and module syntax ok on the 3 touched pages.
- Not yet: a set marked "finished" together (assessments.completed_at is never set; one assessment row per person and set).

### 11/13/2026 — Phase 8 T8.4: services and enrollments (Stephen: "go")
- Migration 20261119540000_mirror_services.sql: tables mirror.services, service_enrollments, service_enrollment_events (row security on,
  service_role only, no TRUNCATE); functions mirror_services, mirror_service_save (organization admins), mirror_enrollments (the person: all
  theirs; a coordinator: their organization's in shared topics, plus services they may enroll in), mirror_enrollment_save (coordinator with
  "see and change" for the topic; the person may only say they stopped), mirror_my_export_services. D-34 decided 11/13 (Stephen accepted it as built).
- Pages: new https://2ndchinc.org/mirror/workspace/services/ ("Our services", from the dashboard), new https://2ndchinc.org/mirror/my-mirror/services/
  ("My services", from My Mirror); a Services section on /mirror/workspace/person/ (workspace-person.js ?v=20261113b: enroll, change where it
  stands, history); Settings' download and printable copy include services (the download sentence now also names resources, referrals, documents).
- Checks: t84 6/6 rolled back on live. html-validate and module syntax ok on the 6 touched pages and workspace-person.js.

### 11/13/2026 — Phase 8 T8.5: appointments and contact notes (Stephen: "go")
- Migration 20261119550000_mirror_appointments_notes.sql: tables mirror.appointments, appointment_events, interactions (row security on,
  service_role only, no TRUNCATE; interactions append-only by trigger, removed only with the whole Mirror). Functions mirror_appointments,
  mirror_appointment_save, mirror_workspace_appointments (dashboard, today + 7 days), mirror_interactions, mirror_interaction_add (corrections
  link to the note), mirror_my_export_appointments. D-35 decided 11/13 (Stephen accepted it as built; no secret notes; the person's own appointments are theirs).
- Pages: Appointments and Contact notes sections on /mirror/workspace/person/ (workspace-person.js ?v=20261113c); the dashboard lists
  appointments today and this week; new https://2ndchinc.org/mirror/my-mirror/appointments/ (add my own; "I can't make it" / "It happened")
  and https://2ndchinc.org/mirror/my-mirror/notes/ (Notes about me), linked from My Mirror; Settings' download and printable copy include both.
- Checks: t85 7/7 rolled back on live (incl. whole-Mirror deletion removes appointments and notes). html-validate and module syntax ok.
- Not yet: reminder emails (Phase 9, T9.2).

### 11/13/2026 — Phase 8 T8.6: benefits applications (Stephen: "go")
- Built on the existing mirror.benefit_records (Phase 4: program, status, applied/approved/renewal/appeal-by/end dates; the person already
  sees renewal and appeal warnings). Migration 20261119560000_mirror_benefit_applications.sql: public.mirror_benefits (one person, topic
  Money shared with the organization, logged, who changed it last) and public.mirror_benefit_dates (dashboard: renewals due in 30 days or
  passed, appeal deadlines in 30 days, people who share Money only). Saving goes through mirror_dn_save; the form passes the person's Daily
  Number links back so they are kept. No new tables. D-37 decided 11/13 (Stephen accepted it as built).
- Pages: Benefits and applications section on /mirror/workspace/person/ (workspace-person.js ?v=20261113d; Wisconsin program suggestions,
  renewal and appeal warnings, no remove); dashboard section "Benefit renewals and appeal deadlines".
- Checks: t86 6/6 rolled back on live (incl. the Daily Number link kept after a coordinator's change). html-validate and module syntax ok.

### 11/13/2026 — Phase 8 T8.7: inventory of donated goods (Stephen: "let us move on")
- Migration 20261119570000_mirror_inventory.sql: tables mirror.inventory_items, inventory_given (row security on, service_role only, no
  TRUNCATE). Functions mirror_inventory, mirror_inventory_save, mirror_inventory_give (locks the row; never below 0; a Mirror person needs
  everyday "see and change"; outside the Mirror no name), mirror_inventory_return (recorded by mistake), mirror_received, mirror_my_export_received.
- Pages: new https://2ndchinc.org/mirror/workspace/inventory/ ("Donated goods", from the dashboard: find, kind, season, fits, on hand / all /
  retired; add, change, give); "Things given" section on /mirror/workspace/person/ (workspace-person.js ?v=20261113e); "Things I received" on
  https://2ndchinc.org/mirror/my-mirror/services/; Settings' download and printable copy include it. D-38 decided 11/13 (Stephen accepted it as built).
- Checks: t87 5/5 rolled back on live. html-validate and module syntax ok on the 5 touched pages and workspace-person.js.

### 11/13/2026 — Phase 8 T8.8: outcomes and reports (Stephen: "go"); Phase 8 built
- Migration 20261119580000_mirror_org_reports.sql: public.mirror_org_report(org, from, to): people, needs (noted, met, confirmed by you,
  open, by area), goals reached, steps done, milestones (confirmed by you), services, appointments, contacts (corrections not counted),
  referrals, benefits (Money shared only), questions gone over together, donated goods (to people, outside the Mirror, by kind). Counts only;
  safety-mode people left out and counted as left out (P2-06); private topics only where shared; each run in the organization's audit log.
  No new tables. D-39 decided 11/13 (Stephen accepted it as built).
- Page: new https://2ndchinc.org/mirror/workspace/reports/ ("Outcomes and reports", from the dashboard): periods (this month, last month,
  this year, last year, last 12 months, chosen dates), "For sharing" (1-4 shown as "fewer than 5"), Print, CSV download.
- Checks: t88 5/5 rolled back on live (incl. no names or words in the report). html-validate and module syntax ok.
- Phase 8 is built (T8.1-T8.8). Open: P2-08 admin pages (teams, roles, consent, email, data, platform audit view); Guided Tour (deferred, D-28).

### 11/13/2026 — P2-08: the platform admin pages (Stephen: "then go"); D-38 and D-39 decided
- Why it was still open: the site map lists ten /mirror/admin/ sections; Phase 2 (T2.5) built organizations, members and platform admins;
  the deep-dive put the rest last because they report on things built later (sharing records, the organization audit view in T8.1, email).
- Migration 20261119595000_mirror_platform_admin_pages.sql: public.mirror_platform_overview (users, members by role and authenticator,
  organizations, role rules, sharing counts, email choices and Mirror outbox, Mirror settings, deletion requests by code and date) and
  public.mirror_platform_audit (every organization's log, members by name, a person only by a code; P2-07 platform half). Platform admins
  only; counts and rules only; each read logged. No new tables. D-40 (decided 11/13).
- Page: new https://2ndchinc.org/mirror/admin/platform/ ("Platform overview", linked from https://2ndchinc.org/mirror/admin/ for platform admins).
- Checks: p208 4/4 rolled back on live (no name, no email in either result; refused without the authenticator, for a 2nd Chance admin
  not on the list and for another organization). html-validate and module syntax ok. Phase 8 has no open items left but the Guided Tour.

### 11/13/2026 — Phase 10 step 29: P2-13 one place for the access rules (Stephen: "go to phase 10"; Phase 9 is lease-30's)
- Migration 20261119596000_mirror_one_place_for_rules.sql: role_permissions gets 'workspace' (view) and 'confirm' (edit) for organization
  admins and coordinators; mirror.role_can / mirror.i_can; 12 live function bodies changed only in their role checks (coordinates,
  can_manage_members, platform_outside, authenticator_reset_refusal, conv_member, mirror_admin_orgs, mirror_need_status,
  mirror_milestone_confirm, mirror_org_audit, mirror_services, mirror_service_save, mirror_admin_authenticator_reset). D-41.
- Check p213 4/4 (no function decides by naming a role; same powers per role; removing a table row takes a power away, adding one
  gives it). All 60 Mirror checks run with and without the migration: identical results
  (56 report; t71 1 failed part, lrd and t72 setup errors, and t91 waiting for Phase 9 are the same without it). The platform page names the two new capabilities.

### 11/13/2026 — Phase 10 step 30: P2-15 rate limits (Stephen: "go")
- Migration 20261119597000_mirror_rate_limits.sql: table mirror.rate_counts (per sign-in, bucket, minute; row security on, service_role
  only), mirror.rate_limit / rate_ok / rate_require / rate_message / rate_refused (no new index on the audit log: creating one
  in the same transaction as a check deadlocked with the refusal writer's second connection; the lookup only runs when over a limit). The gate (mirror.allowed, live
  body) counts changes and members' non-probe looks; mirror_person_add, mirror_referral_send, mirror_org_report and the two platform
  functions have their own limits (live bodies, one line added each). No read-only (STABLE) function reaches a counted path (checked). D-43.
- Check p215 5/5 (limits; a look counted, probes not; refusals with the plain message for a member's look, the person's change, adding
  people; the refusal logged once; old counts expire). All Mirror checks run with and without the migration (results below).

### 11/13/2026 — Phase 10 step 32: accessibility, phone, page weight, error handling (Stephen: "go")
- Browser pass (headless Chrome, signed out, live site): all 83 Mirror pages at phone width (390 px, touch) and desktop, 166 loads:
  axe-core WCAG 2.2 AA 0 violations; no page scrolls sideways on the phone; 0 script errors; keyboard focus visible on every stop
  tested (up to 30 Tab stops a page). 70 pages are signed-in pages and show the sign-in page when signed out, so for those the
  browser checks cover the sign-in page; their own markup is covered by the rules below, the real signed-in walk is the Guided Tour (D-28).
- Page weight: first visit about 126 KB with the fonts; later pages 7-41 KB. Calls: signed-in pages load up to 55 small files
  (the page and its modules; HTTP/2, cached 4 hours, K-05) before sign-in is checked; acceptable, noted for later.
- html-validate with the recommended and accessibility rules on every page: fixed 10 phone numbers that could break across lines
  (accessibility, forgot-password, privacy, sign-in) and 3 inputs without a type (daily-number, styleguide); now 0 problems.
- Error handling: all 202 database calls in the Mirror's page code are in a try block or check the returned error; none unhandled.
- Open: the signed-in screens in a real browser, Android, iPhone, Speak / Read aloud and Narrator stay the Guided Tour (D-28).
- Went live with lease-30's TN.3 deploy (4dce75e); t88 on live then failed 2 parts in the evening: P8-01, the UTC date. Fixed by migration
  20261119590000_mirror_local_dates.sql (20 Mirror functions run on America/Chicago). With it: t88, t87, t86, t85, t84, t83, t82, t81, t64,
  t63 (its milestone now dated with Milwaukee's day), t63b, t61, t25, t36, p2-fix01, p2-fix02, tn2 all pass (0 failed parts).

### 11/13/2026 — Phase N step 17, P2-11: authenticator reset (Stephen: "go to the next in your build")
- Migration 20261119600000_mirror_authenticator_reset.sql: mirror.authenticator_reset_refusal (who may reset whom), mirror_admin_authenticators
  (each member: authenticator set up or not, may this admin reset it, last reset), mirror_admin_authenticator_reset (removes the person's
  authenticator factors and signs them out on every device; identity confirmed by phone or in person + reason required; 5 a day per admin;
  organization audit log action authenticator_reset). No email is sent. No new table.
- Rules: an organization's admin may reset only a plain Mirror sign-in of their own members (not 2nd Chance admin, office or field staff, leasing
  agents, Housing Navigators, 2nd Chance members or platform admins, nor someone in another organization); a 2nd Chance platform admin may reset
  anyone except a portal admin; nobody resets their own.
- Page: https://2ndchinc.org/mirror/admin/ members table has an Authenticator column with Reset (form: why + "I confirmed it is really them").
- Checks: p211 6/6 rolled back on live; all 32 Mirror checks pass with the migration (0 failed).

### 11/13/2026 — Phase N step 18, TN.1: sharing beyond housing for Navigator people (Stephen: "GO")
- Migration 20261119610000_nav_whole_person_consent.sql: table public.nav_whole_consents (row security, service_role only); functions
  nav_whole_consent (what the screen shows), nav_whole_consent_save (the person's choice per private topic + typed full name, exact words kept,
  logged in the person's history), trigger: withdrawing the housing consent ends it; mirror.nav_whole_consent_to_mirror (for TN.2: copies into
  mirror.consents for the Navigator's own organization). The housing consent (nav_consent_text, nav-consent-2026-11) is unchanged. D-36 DEFAULT.
- Page: "Sharing beyond housing" on the person's file in https://2ndchinc.org/navigator/ and https://2ndchinc.org/staff/navigators/
  (nav-common.js ?v=20261113a), shown once the housing consent is signed.
- Checks: tn1 6/6 rolled back on live; all 32 Mirror checks pass with the migration (0 failed). 0 real Navigator people today (4 samples).

### 11/13/2026 — Phase N step 19, TN.2: Navigator person = Mirror individual (Stephen: "go and D-36 (please make the best choice for our system)")
- D-36 DECIDED: Stephen's defaults kept, plus (h): once the person has their own Mirror sign-in they change sharing in their Mirror Settings and
  the Navigator screen only shows it; withdrawing the housing consent revokes the Navigator organization's sharing and ends its work.
- Migration 20261119620000_nav_person_mirror.sql: nav_referrals.mirror_individual_id; mirror.navigator_org (finds or makes the Navigator business's
  organization, the Navigator its admin); nav_mirror_start (their Navigator or the office; after the housing consent; never samples; the person's
  yes ticked; with email = invitation, without = active and filled in together; an existing Mirror by the same email is linked, never
  overwritten; sharing beyond housing copied); nav_whole_consent / nav_whole_consent_save / the withdraw trigger updated for D-36 (h). No email.
- Page: on the person's file in https://2ndchinc.org/navigator/ and https://2ndchinc.org/staff/navigators/ (nav-common.js ?v=20261113b):
  "Start their Mirror", then the Mirror's status and "Open their Mirror" (https://2ndchinc.org/mirror/workspace/person/).
- Checks: tn2 6/6 and tn1 6/6 rolled back with the migration; all 32 Mirror checks pass (0 failed). 0 real Navigator people today.

### 11/13/2026 — Phase N step 20, TN.3: the directory by life area + non-housing programs (Stephen: "go")
- Migration 20261119630000_chpms_life_areas.sql: chpms_life_areas (the 15 areas and each program's areas, same access as the directory),
  chpms_program_areas_save (office staff tag a program; areas from its help types stay). chpms_directory unchanged.
- Migration 20261119631000_chpms_non_housing_programs.sql: researched 11/13/2026 from each program's own official page (sources TN3-S01..S10):
  new organizations DMV, Hunger Task Force, Progressive Community Health Centers, Lifeline (USAC), Milwaukee Public Library, Employ Milwaukee,
  Literacy Services of Wisconsin, Job Center of Wisconsin; programs: Wisconsin ID card (free for voting), certified birth certificate and FoodShare
  (at Wisconsin DHS, already listed), free food map and Senior Stockbox, sliding-fee health care, Lifeline discount, library computers and card,
  job and training programs, free adult education, job search. 9 Verified – Current, 1 Verified – Limited (Job Center: no phone, no operator named).
  Not added: the Milwaukee County Register of Deeds and City vital records pages refused automated reading (403), so they are only a note.
  Legal help was already in the directory with the legal life area.
- Page: Find help on https://2ndchinc.org/staff/resources/ and the Navigator Resources tab (chpms.js ?v=20261113a): Life area filter, "Life areas"
  on each program, "Change life areas" for office staff, Show > "Added 11/13 beyond housing".
- Checks: tn3 5/5 rolled back with both migrations (a food need in the Mirror is matched to 2 of the new programs); all 32 Mirror checks and t73 pass.

### 11/13/2026 — Phase N step 21, TN.4: own-room disclosure (Stephen: "go")
- Migration 20261119640000_nav_own_room_disclosure.sql: table nav_own_room_confirms (row security, service_role only); nav_own_room (matched to a
  home the file's own Navigator runs), nav_own_room_state / nav_own_room_confirm (the person types their full name to the exact sentence: they
  know their Navigator runs the home, were told about other places, choose this one, can say no without losing help), trigger
  nav_referrals_own_room_guard (no placement, status approved, without the confirmation for that unit and room), nav_own_room_matches (office list).
  nav_referral_step unchanged. Only sample files are matched to a Navigator-run home today. No email.
- Pages: "A room you run" on the file in https://2ndchinc.org/navigator/ and https://2ndchinc.org/staff/navigators/ (nav-common.js ?v=20261113c);
  "Matches to rooms a Navigator runs" on the office's Navigators dashboard.
- Checks: tn4 6/6 rolled back; all 32 Mirror checks and tn2 pass with the migration.

### 11/13/2026 — Phase N step 22, TN.5: check-ins from the first meeting (Stephen: "go"). Phase N is built.
- Migration 20261119650000_nav_checkins_first_meeting.sql: nav_checkin_schedule works on any open file with a signed housing consent (was moved
  in only); trigger: recording a check-in before move-in schedules the next; trigger: closing before move-in clears the open check-in;
  nav_followups.mirror_need_id; mirror_nav_checkins / mirror_nav_checkin_link (Mirror gate: authenticator, the Navigator's own organization,
  needs in shared topics, "see and change" to link). nav_followup_save (retention pay) and nav_followup_reminders (emails) are unchanged.
- Pages: the file in https://2ndchinc.org/navigator/ and https://2ndchinc.org/staff/navigators/ (nav-common.js ?v=20261113d): "Start check-ins"
  before housing, check-ins recorded before housing (no rent box), "linked to a need in their Mirror"; new https://2ndchinc.org/mirror/workspace/checkins/.
- Open for Stephen: reminder emails for check-ins before move-in (new sends of the existing check-in reminder) wait for his OK.
- Checks: tn5 6/6 rolled back; all 32 Mirror checks, tn2 and tn4 pass with the migration.

### 11/13/2026 — Phase 9 step 23, T9.1: email templates and the hold (Stephen: "you take phase 9 now")
- Migration 20261119660000_mirror_email_templates.sql: table mirror.notifications (service_role only); mirror.email_kinds, mirror.email_html (words for
  the 6 kinds; no health, legal, money or safety detail; safety mode neutral), mirror.email_queue (the one way to queue; notification_ok for the 3
  choice kinds; 12-hour repeat guard; held unless the kind is in portal_settings.mirror_email_kinds_enabled, which starts empty),
  mirror_admin_email_kinds / mirror_admin_email_kind_set (platform admins see; only portal_admins switch; logged). D-42 DEFAULT.
- Pages: new https://2ndchinc.org/mirror/admin/email/ (exact words in sandboxed previews, on/off, 30-day counts), linked from the platform page's
  Email section. site/_redirects: /account/ -> /mirror/sign-in/ (neutral link for safety mode).
- Nothing calls email_queue yet, and every kind is off: no email is sent. Next: T2.6 second half (the invitation), then T9.2 reminders.
- Checks: t91 5/5 rolled back; all 32 Mirror checks pass with the migration.

### 11/13/2026 — Phase 9 step 24, T2.6 second half: the invitation email and /mirror/register/ (Stephen: "D-42 yes", wording "perfect")
- Migration 20261119670000_mirror_invitation_email.sql: triggers on mirror.organization_individuals (status becomes invited, with an email) and
  mirror.organization_members (new or reactivated member) queue mirror_invite / mirror_staff_invite through mirror.email_queue; mirror_invitation_resend
  and mirror_member_invite_resend ("Send the invitation again"). mirror_person_add, mirror_admin_member_save and nav_mirror_start are not changed.
  Fix in mirror.email_queue: the 12-hour repeat guard counts only queued emails, not held ones. D-42 DECIDED.
- Pages: new https://2ndchinc.org/mirror/register/; "Send the invitation again" on https://2ndchinc.org/mirror/workspace/people/ (people waiting to
  accept) and https://2ndchinc.org/mirror/admin/ (members). Every kind is still off: nothing is sent until Stephen turns it on.
- Checks: t26b 5/5 and t91 5/5 rolled back with the migration; all Mirror checks pass (the landlord-database and p215 checks error the same way
  without it: another session's work in progress).

### 11/13/2026 — Phase 9 step 25, T9.2: reminders (Stephen: "go")
- Migration 20261119680000_mirror_reminders.sql: mirror.send_reminders (the day before: scheduled appointments starting tomorrow, open plan steps due
  tomorrow; people with their own sign-in email; date and time only; the reference includes the date, so a moved item gets a new reminder and none is
  sent twice) and job mirror-reminders (daily 13:30 UTC; calls outbox-flush with x-cycle-secret only when something was queued). No new table.
- Both kinds (appointment reminders, reminders about the plan) are still off: reminders are recorded as held and not sent until Stephen turns them on.
- Check fixes (stale expectations, not system faults): t72 item 1 now expects a health match (TN.3 added a health center) and the truncate test accepts
  the referrals foreign key (T7.3); t72 6/6 on live.
- Checks: t92 4/4 rolled back; all Mirror checks pass with the migration (the landlord-database check errors the same way without it).

### 11/14/2026 — Phase 9 step 26, P2-12: end dates for sharing, with a reminder (Stephen: "go")
- Migration 20261119690000_mirror_consent_end_dates.sql: mirror_my_consent_until (person), mirror_consent_record_until (coordinator, person without
  a sign-in), the end date carried over by mirror_my_consent_set and mirror_consent_record, shown by mirror_my_settings ('sharing_until') and
  mirror_consents_recorded ('until'); email kind mirror_sharing (7th kind, off until Stephen turns it on; neutral in safety mode) sent 7 days before
  by mirror.send_reminders (the mirror-reminders job, unchanged). Dates: tomorrow up to 5 years. mirror.allowed already stops a share after its date.
- Pages: Settings (https://2ndchinc.org/mirror/my-mirror/settings/) "Shared until" per topic with Save end date / No end date; the coordinator's
  "What they share" shows "until"; the record form takes an optional end date. /mirror/register/ phone number kept on one line (lease-6f's a11y pass).
- Checks: p212 5/5 rolled back; t91 updated for 7 kinds (5/5); t92 4/4; all Mirror checks pass with the migration (landlord-database check errors
  the same way without it).

