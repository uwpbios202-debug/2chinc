import { requireArea, rpc } from "/mirror/assets/mirror-client.js?v=20261113d";
import { esc, notice, toast } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { voiceSettings } from "/mirror/assets/mirror-voice.js?v=20261113c";
import { planEffect, takeHome, openOpportunities } from "/mirror/assets/daily-number.js?v=20261113e";

const TOPICS = [
  ["general", "Your answers in general", "Everything that isn't private: who you are, your strengths, your vision, your plans."],
  ["health", "Physical health", null], ["mental_health", "How you feel inside", null], ["safety", "Your safety", null],
  ["legal", "ID, papers and legal matters", null], ["immigration", "Immigration", null], ["financial", "Money", "Income, costs and your Daily Number."],
  ["documents", "Documents you upload", null],
];
/** Topics with nothing behind them yet (no questions, no uploads): no choice is offered, so nobody thinks it does something.
 *  A choice made earlier still shows, so it can be withdrawn. Remove a key here once its questions or uploads exist. */
const NOT_YET = {
  immigration: "No questions ask about this yet. When they do, you'll choose here who can see your answers.",
  documents: "You can't upload documents yet. When you can, you'll choose here who can see them.",
};
const ACTION = { view: "looked at", edit: "changed", refused: "tried to open (not allowed)" };
const TOPIC_NAME = Object.fromEntries(TOPICS.map(([k, l]) => [k, l]));
const when = (d) => new Date(d).toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });

await requireArea("my");
const box = document.getElementById("mmSet");
let S, N;
/** Email choices (Phase 3 fix 5). The Mirror sends none of these yet (Phase 9); the choice is kept for then. */
const EMAILS = [
  ["referral", "Updates on referrals", "When a referral made with you or for you changes."],
  ["appointment", "Appointment reminders", "Before an appointment you have with an organization."],
  ["action", "Reminders about your plan", "When a step in your plan is coming up."],
];

async function load(note = "") {
  try { [S, N] = await Promise.all([rpc("mirror_my_settings"), rpc("mirror_my_notifications")]); }
  catch (e) { box.innerHTML = notice("urgent", `<p>${esc(e.message)}</p>`); return; }
  draw(note);
}

function sharingSelect(org, key) {
  const cur = org.sharing[key] || "none";
  const opts = key === "general"
    ? [["none", "Can see while you work together"], ["edit", "Can see and change your answers"]]
    : [["none", "Can't see"], ["view", "Can see"], ["edit", "Can see and change"]];
  return `<select class="mm-select" data-org="${esc(org.id)}" data-topic="${key}" aria-label="${esc(TOPIC_NAME[key])}: ${esc(org.name)}">
    ${opts.map(([v, l]) => `<option value="${v}"${(cur === v || (key === "general" && v === "none" && cur === "view")) ? " selected" : ""}>${esc(l)}</option>`).join("")}</select>`;
}

// Phase 2 fix 2: a choice a coordinator recorded for you (on paper or out loud) says so, with their name; you can change it above.
const HOW = { paper: "on paper", spoken: "out loud" };
function recordedNote(org, key) {
  const d = org.sharing_detail && org.sharing_detail[key];
  if (!d) return "";
  return `<p class="mm-muted mm-small" style="margin:var(--mm-space-1) 0 0">Recorded for you by ${esc(d.by)}, ${esc(HOW[d.method] || d.method)}, on ${esc(new Date(d.at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }))}. You can change it here.</p>`;
}

function draw(note) {
  const p = S.person;
  const open = S.organizations.filter((o) => o.status !== "ended"), ended = S.organizations.filter((o) => o.status === "ended");
  box.innerHTML = `${note}
  <section class="mm-read" aria-labelledby="hShare">
    <h2 id="hShare">Who can see what</h2>
    ${open.length ? open.map((o) => `<div class="mm-card" style="margin-bottom:var(--mm-space-4)">
      <h3 style="margin-top:0">${esc(o.name)}</h3>
      <p class="mm-muted mm-small">${o.coordinator ? "Your coordinator: " + esc(o.coordinator) + ". " : ""}Private topics stay closed unless you open them. Changes take effect right away.</p>
      ${TOPICS.map(([k, l, hint]) => `<div class="mm-field" style="margin-bottom:var(--mm-space-3)">
        <label>${esc(l)}</label>${NOT_YET[k] && (o.sharing[k] || "none") === "none"
          ? `<p class="mm-muted mm-small" style="margin:0">${esc(NOT_YET[k])} Nobody else can see anything here.</p>`
          : `${hint ? `<span class="mm-hint">${esc(hint)}</span>` : ""}${sharingSelect(o, k)}`}${recordedNote(o, k)}</div>`).join("")}
      <button class="mm-btn mm-btn-quiet" type="button" data-end="${esc(o.id)}" data-name="${esc(o.name)}">Stop working with ${esc(o.name)}</button>
    </div>`).join("") : notice("info", "<p>You aren't working with any organization right now, so nobody else can see your Mirror.</p>")}
    ${ended.length ? `<p class="mm-muted mm-small">Ended: ${ended.map((o) => esc(o.name)).join(", ")}. They can't see your Mirror any more.</p>` : ""}
  </section>

  <section class="mm-read" aria-labelledby="hWho">
    <h2 id="hWho">Who looked at your Mirror</h2>
    <p class="mm-muted">Every time someone else opens a private topic or changes an answer, it is written down here. Nobody can erase this list.</p>
    <div id="mmWho"><p role="status">Loading…</p></div>
  </section>

  <section class="mm-read" aria-labelledby="hName">
    <h2 id="hName">Your name</h2>
    <form class="mm-card" id="mmName" novalidate>
      <div class="mm-field"><label for="nPref">The name you go by</label><input class="mm-input" id="nPref" value="${esc(p.preferred_name)}"></div>
      <div class="mm-field"><label for="nLegal">Legal name <span class="mm-muted">(optional)</span></label><input class="mm-input" id="nLegal" value="${esc(p.legal_name || "")}"></div>
      <div class="mm-field" style="max-width:12rem"><label for="nYear">Birth year <span class="mm-muted">(optional)</span></label><input class="mm-input" id="nYear" inputmode="numeric" maxlength="4" data-mm-no-voice value="${esc(p.birth_year || "")}"></div>
      <p class="mm-muted mm-small">Sign-in email: ${esc(p.email || "none")}. To change it, ask your coordinator or call (262) 236-5443; we confirm it's you first.</p>
      <div id="nMsg" aria-live="assertive"></div>
      <button class="mm-btn" type="submit">Save</button>
    </form>
  </section>

  <section class="mm-read" aria-labelledby="hSafe">
    <h2 id="hSafe">Safety mode</h2>
    <div class="mm-card">
      <p>Turn this on if someone in your life might be watching your phone, email or mail. Only you can turn it off.</p>
      <p><strong>What it does now:</strong> private questions are never read out loud (no Read aloud, and hands-free stays quiet on them),
        and the Mirror checks with you before it saves or prints a copy of your Mirror on this device.</p>
      <p><strong>Coming later:</strong> your coordinators will see a safety note on your record, and the Mirror will leave you out of anything
        sent or reported about you. The Mirror sends you no emails today except your sign-in codes.</p>
      <p class="mm-muted mm-small">Tip: the Mirror does not keep your answers on this device, but your browser's history shows the pages you visited.
        A private or incognito window leaves no history.</p>
      <label class="mm-choice"><input type="checkbox" id="mmSafe" ${p.safety_sensitive ? "checked" : ""}> Safety mode is ${p.safety_sensitive ? "on" : "off"}</label>
      <p class="mm-muted mm-small">In danger now? Call 911. National Domestic Violence Hotline: 1-800-799-7233, or text START to 88788.
        Thinking about hurting yourself? Call or text 988 (Suicide and Crisis Lifeline), any time, free.</p>
    </div>
  </section>

  <section class="mm-read" aria-labelledby="hMail">
    <h2 id="hMail">Emails from the Mirror</h2>
    <div class="mm-card">
      <p><strong>The Mirror sends you no emails yet</strong>, except your sign-in codes. Choose now what you'd like once it does; you can change it any time.</p>
      <p class="mm-muted mm-small">These emails will never contain health, legal or money details. They only say something is waiting, and you sign in to see it.</p>
      ${N.safety_mode ? notice("caution", "<p>Safety mode is on, so none of these will be sent, whatever you choose here.</p>") : ""}
      <fieldset class="mm-field" style="border:0;padding:0;margin:0">
        <legend class="mm-sr">Emails you'd like</legend>
        ${EMAILS.map(([k, l, hint]) => `<label class="mm-choice"><input type="checkbox" data-mail="${k}" ${N.choices[k] ? "checked" : ""}> ${esc(l)}<span class="mm-hint" style="display:block">${esc(hint)}</span></label>`).join("")}
      </fieldset>
      <p class="mm-muted mm-small">Always sent, so you can get in and know about changes to your sign-in: your sign-in codes and security notices.</p>
    </div>
  </section>

  <section class="mm-read" aria-labelledby="hVoice">
    <h2 id="hVoice">Speaking your answers</h2>
    <div data-mm-voice></div>
  </section>

  <section class="mm-read" aria-labelledby="hTake">
    <h2 id="hTake">Take your Mirror with you</h2>
    <div class="mm-card">
      <p>Download everything: your answers, your earlier answers, your Daily Number, your needs, your strengths, your goals, steps and milestones, who you shared with, and who looked.</p>
      ${p.safety_sensitive ? notice("caution", "<p>Safety mode is on. A file or a printed copy stays on this device or on paper, where someone else could find it. You'll be asked to press twice.</p>") : ""}
      <p class="mm-row"><button class="mm-btn mm-btn-secondary" type="button" id="mmJson">Download a file</button>
        <button class="mm-btn mm-btn-secondary" type="button" id="mmPrint">Printable copy</button></p>
    </div>
  </section>

  <section class="mm-read" aria-labelledby="hDel">
    <h2 id="hDel">Delete your Mirror</h2>
    <div class="mm-card">
      ${p.deletion_requested_at
        ? `<p><strong>You asked to delete your Mirror.</strong> It will be deleted on or after ${esc(new Date(p.deletion_on + "T12:00:00").toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }))}. Until then you can change your mind.</p>
           <button class="mm-btn" type="button" id="mmKeep">Keep my Mirror</button>`
        : `<p>If you ask, we wait 30 days in case you change your mind, then delete everything. A note that a deletion happened is kept, without any of your information. You may want to download it first.</p>
           <button class="mm-btn mm-btn-secondary" type="button" id="mmDel">Ask to delete my Mirror</button>`}
    </div>
  </section>`;
  wire();
  who();
}

async function who() {
  const el = document.getElementById("mmWho");
  try {
    const rows = await rpc("mirror_who_looked");
    const shown = rows.filter((r) => r.action in ACTION);
    el.innerHTML = shown.length ? `<div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Who looked at your Mirror</caption>
      <thead><tr><th scope="col">When</th><th scope="col">Who</th><th scope="col">What</th><th scope="col">Topic</th></tr></thead>
      <tbody>${shown.slice(0, 100).map((r) => `<tr><td data-label="When">${esc(when(r.at))}</td><td data-label="Who">${esc(r.who)}${r.organization ? `<br><span class="mm-muted mm-small">${esc(r.organization)}</span>` : ""}</td>
        <td data-label="What">${esc(ACTION[r.action])}</td><td data-label="Topic">${esc(TOPIC_NAME[r.category] || r.category || "")}</td></tr>`).join("")}</tbody></table></div>`
      : notice("ok", "<p>Nobody else has opened a private topic or changed your answers.</p>");
  } catch (e) { el.innerHTML = notice("caution", `<p>${esc(e.message)}</p>`); }
}

/** Two presses instead of a pop-up. */
function twice(b, label) {
  if (b.dataset.sure) return true;
  b.dataset.sure = "1"; const old = b.textContent; b.textContent = label;
  setTimeout(() => { if (b.isConnected) { delete b.dataset.sure; b.textContent = old; } }, 6000);
  return false;
}

function wire() {
  box.querySelectorAll("select[data-topic]").forEach((s) => s.addEventListener("change", async () => {
    s.disabled = true;
    try { await rpc("mirror_my_consent_set", { p_org: s.dataset.org, p_category: s.dataset.topic, p_access: s.value }); toast("Saved. It takes effect right away."); await load(); }
    catch (e) { s.disabled = false; toast(e.message); }
  }));
  box.querySelectorAll("[data-end]").forEach((b) => b.addEventListener("click", async () => {
    if (!twice(b, `Press again to stop working with ${b.dataset.name}`)) return;
    try { await rpc("mirror_my_org_end", { p_org: b.dataset.end }); load(notice("ok", `<p>${esc(b.dataset.name)} can no longer see your Mirror.</p>`)); }
    catch (e) { toast(e.message); }
  }));
  box.querySelector("#mmName").addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await rpc("mirror_my_profile_save", { p: { preferred_name: document.getElementById("nPref").value, legal_name: document.getElementById("nLegal").value, birth_year: document.getElementById("nYear").value } });
      toast("Saved.");
    } catch (err) { document.getElementById("nMsg").innerHTML = notice("urgent", `<p>${esc(err.message)}</p>`); }
  });
  box.querySelector("#mmSafe").addEventListener("change", async (e) => {
    try { await rpc("mirror_my_safety", { p_on: e.target.checked }); load(notice(e.target.checked ? "caution" : "info", `<p>Safety mode is ${e.target.checked ? "on" : "off"}.</p>`)); }
    catch (err) { toast(err.message); }
  });
  box.querySelectorAll("input[data-mail]").forEach((c) => c.addEventListener("change", async () => {
    c.disabled = true;
    try { N = await rpc("mirror_my_notifications_set", { p: { [c.dataset.mail]: c.checked } }); toast("Saved."); }
    catch (err) { c.checked = !c.checked; toast(err.message); }
    c.disabled = false;
  }));
  voiceSettings(box.querySelector("[data-mm-voice]"));
  const safeAsk = (b) => !S.person.safety_sensitive || twice(b, "Safe to save on this device? Press again");
  box.querySelector("#mmJson").addEventListener("click", async (e) => {
    if (!safeAsk(e.currentTarget)) return;
    try {
      const data = await rpc("mirror_my_export");
      data.needs = await rpc("mirror_my_export_needs");   // T6.1: needs and their history are part of "everything"
      data.strengths = await rpc("mirror_my_export_strengths");   // T6.2
      data.plan = await rpc("mirror_my_export_plan");             // T6.3: goals, steps, milestones
      const a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }));
      a.download = "my-human-mirror-" + new Date().toISOString().slice(0, 10) + ".json";
      document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 5000);
    } catch (e) { toast(e.message); }
  });
  box.querySelector("#mmPrint").addEventListener("click", (e) => { if (safeAsk(e.currentTarget)) printable(); });
  box.querySelector("#mmDel")?.addEventListener("click", async (e) => {
    if (!twice(e.target, "Press again to ask for deletion")) return;
    try { await rpc("mirror_my_deletion", { p_request: true }); load(); } catch (err) { toast(err.message); }
  });
  box.querySelector("#mmKeep")?.addEventListener("click", async () => {
    try { await rpc("mirror_my_deletion", { p_request: false }); load(notice("ok", "<p>Your Mirror stays. The deletion request is cancelled.</p>")); } catch (err) { toast(err.message); }
  });
}

/** The Daily Number part of the printable copy (with household, benefits and the plan: K-10). */
function dailyNumberPrint(dn) {
  const P = (dn && dn.plan) || { members: [], benefits: [], opportunities: [] };
  if (!dn || !dn.inputs || (!dn.inputs.expenses.length && !dn.inputs.income.length && !P.members.length && !P.benefits.length && !P.opportunities.length)) return "";
  const m = (n) => (Number(n) || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
  const L = dn.results.levels, NAME = { current: "Today", survival: "Survival", stability: "Stability", aspirational: "The life I want" };
  const who = Object.fromEntries(P.members.map((x) => [x.id, x.label]));
  const by = (x) => x.paid_by === "household" ? " (paid by " + esc(who[x.household_member_id] || "someone in my household") + ")"
    : x.household_member_id && who[x.household_member_id] ? " (from " + esc(who[x.household_member_id]) + ")" : "";
  const line = (x) => esc(x.label) + ": " + m(x.amount) + " " + esc(String(x.frequency).replace("_", " ")) + (x.start_on ? " from " + esc(x.start_on) : "") + (x.end_on ? " until " + esc(x.end_on) : "") + by(x);
  const REL = { partner: "partner or spouse", child: "child", parent: "parent", sibling: "brother or sister", other_family: "other family", friend: "friend", roommate: "roommate", other: "other" };
  const BST = { considering: "thinking about applying", applied: "applied, waiting", active: "getting it now", denied: "denied", appealing: "appealing", ended: "ended" };
  const OST = { idea: "an idea", working_on: "working on it", started: "started", dropped: "not going ahead" };
  const dates = (b) => [["applied", b.applied_on], ["approved", b.approved_on], ["renewal due", b.renewal_on], ["appeal by", b.appeal_by], ["ends", b.ends_on]]
    .filter((d) => d[1]).map((d) => d[0] + " " + esc(d[1])).join(", ");
  const tax = Number(dn.inputs.tax_rate_pct) || 0;
  const opp = (o) => esc(o.label) + ": " + m(o.amount) + " " + esc(String(o.frequency).replace("_", " ")) + (o.amount_is_gross !== false && takeHome(o, tax) !== Number(o.amount) ? " before taxes (" + m(takeHome(o, tax)) + " take-home)" : "")
    + " · " + esc(OST[o.status] || o.status) + (o.expected_on ? " · could start " + esc(o.expected_on) : "") + (o.next_step ? " · next step: " + esc(o.next_step) : "");
  const eff = openOpportunities(P.opportunities).length ? planEffect(dn.inputs, P.opportunities) : null;
  const planHtml = (P.members.length ? "<h3>My household</h3><ul>" + P.members.map((x) => "<li>" + esc(x.label) + " (" + esc(REL[x.relationship] || x.relationship) + (x.lives_with ? ", lives with me" : ", doesn't live with me") + ")" + (x.note ? ": " + esc(x.note) : "") + "</li>").join("") + "</ul>" : "")
    + (P.benefits.length ? "<h3>My benefits</h3><ul>" + P.benefits.map((b) => "<li>" + esc(b.program) + (b.agency ? " (" + esc(b.agency) + ")" : "") + ": " + esc(BST[b.status] || b.status) + (dates(b) ? "; " + dates(b) : "") + (b.note ? ". " + esc(b.note) : "") + "</li>").join("") + "</ul>" : "")
    + (P.opportunities.length ? "<h3>My plan: how I will generate my Daily Number</h3><ul>" + P.opportunities.map((o) => "<li>" + opp(o) + "</li>").join("") + "</ul>" : "")
    + (eff ? "<p>If the plan items that are ideas or being worked on came true, the monthly gap would be: " + Object.keys(NAME).map((k) => NAME[k] + " " + m(eff[k].gap_now) + " now, " + m(eff[k].gap_plan) + " then").join("; ") + ".</p>" : "");
  return `<h2>My Daily Number</h2>
    <p>${Object.keys(NAME).map((k) => NAME[k] + ": " + m(L[k].cost.daily) + " a day (" + m(L[k].cost.monthly) + " a month)").join("<br>")}</p>
    <p>Cash income: ${m(dn.results.income.monthly)} a month. Help that isn't cash: ${m(dn.results.noncash.monthly)} a month. Daily gap today: ${m(L.current.shortfall.daily)}.</p>
    ${Object.keys(NAME).map((k) => { const xs = dn.inputs.expenses.filter((x) => x.level === k); return xs.length ? "<h3>" + NAME[k] + "</h3><ul>" + xs.map((x) => "<li>" + line(x) + "</li>").join("") + "</ul>" : ""; }).join("")}
    ${dn.inputs.income.length ? "<h3>Cash income</h3><ul>" + dn.inputs.income.map((x) => "<li>" + line(x) + "</li>").join("") + "</ul>" : ""}
    ${dn.inputs.noncash.length ? "<h3>Help that isn't cash</h3><ul>" + dn.inputs.noncash.map((x) => "<li>" + line(x) + "</li>").join("") + "</ul>" : ""}
    ${dn.inputs.goals.length ? "<h3>Savings goals</h3><ul>" + dn.inputs.goals.map((g) => "<li>" + esc(g.label) + ": " + m(g.current_amount) + " of " + m(g.target_amount) + (g.target_date ? " by " + esc(g.target_date) : "") + "</li>").join("") + "</ul>" : ""}
    ${planHtml}`;
}

/** A readable copy for printing: current answers grouped by reflection and area, then sharing. */
async function printable() {
  let d;
  try { d = await rpc("mirror_my_export"); d.needs = await rpc("mirror_my_export_needs");
    d.strengths = await rpc("mirror_my_export_strengths"); d.plan = await rpc("mirror_my_export_plan"); } catch (e) { toast(e.message); return; }
  const NEED_STATUS = { identified: "Noted", planning: "Planning", in_progress: "Working on it", obtained: "Got it", verified: "Confirmed", no_longer_needed: "No longer needed" };
  const STRENGTH_KIND = { skill: "Skill", talent: "Talent", experience: "Experience", credential: "Papers and training", language: "Language", interest: "Interest", relationship: "Person in my corner" };
  const STAGE_NAME = { 1: "Immediate stabilization", 2: "Establishing a foundation", 3: "Establishing a home", 4: "Building earning capacity", 5: "Developing independence", 6: "Flourishing and contributing" };
  const GOAL_STATUS = { active: "Working toward it", paused: "On hold", achieved: "Reached", let_go: "Let go" };
  const STEP_STATUS = { open: "To do", done: "Done", dropped: "Not doing" };
  const STATE = { unknown: "I don't know", not_applicable: "Doesn't apply", prefer_not: "Prefer not to say", needs_help: "I'd like help with this" };
  const val = (a) => a.state !== "answered" ? STATE[a.state] : Array.isArray(a.answer) ? a.answer.join(", ") : a.answer === true ? "Yes" : a.answer === false ? "No" : String(a.answer);
  const groups = {};
  d.answers.filter((a) => a.current).forEach((a) => { (groups[a.set] = groups[a.set] || []).push(a); });
  const w = window.open("", "_blank");
  if (!w) { toast("Allow pop-ups for this page to open the printable copy."); return; }
  w.document.write(`<!doctype html><html lang="en"><head><meta charset="utf-8"><title>My Human Mirror</title>
    <style>body{font:16px/1.5 Georgia,serif;max-width:46rem;margin:2rem auto;padding:0 1rem;color:#111}h1{font-size:1.8rem}h2{margin-top:2rem;border-bottom:1px solid #999}dt{font-weight:bold;margin-top:.8rem}dd{margin:0 0 0 1rem}</style></head><body>
    <h1>My Human Mirror</h1><p>${esc(d.me.preferred_name)} · printed ${esc(new Date().toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }))}</p>
    ${Object.entries(groups).map(([g, list]) => `<h2>${esc(g)}</h2><dl>${list.map((a) => `<dt>${esc(a.question)}</dt><dd>${esc(val(a))}${a.note ? " (" + esc(a.note) + ")" : ""}</dd>`).join("")}</dl>`).join("") || "<p>No answers yet.</p>"}
    ${dailyNumberPrint(d.daily_number)}
    ${d.needs.length ? `<h2>My needs</h2><ul>${d.needs.map((n) => `<li>${esc(n.need)} (${esc(n.area)}): ${esc(NEED_STATUS[n.status] || n.status)}${n.details ? ". " + esc(n.details) : ""}</li>`).join("")}</ul>` : ""}
    ${d.strengths.length ? `<h2>My strengths</h2><ul>${d.strengths.map((s) => `<li>${esc(STRENGTH_KIND[s.kind] || s.kind)}: ${esc(s.strength)}${s.details ? ". " + esc(s.details) : ""}</li>`).join("")}</ul>` : ""}
    ${d.plan.goals.length ? `<h2>My goals</h2><ul>${d.plan.goals.map((g) => `<li>${esc(g.goal)} (${esc(g.area)}${g.stage ? ", " + esc(STAGE_NAME[g.stage]) : ""}): ${esc(GOAL_STATUS[g.status] || g.status)}${g.details ? ". " + esc(g.details) : ""}</li>`).join("")}</ul>` : ""}
    ${d.plan.steps.length ? `<h2>My steps</h2><ul>${d.plan.steps.map((s) => `<li>${esc(s.step)}${s.for_goal ? " (goal: " + esc(s.for_goal) + ")" : s.for_need ? " (need: " + esc(s.for_need) + ")" : ""}: ${esc(STEP_STATUS[s.status] || s.status)}${s.who !== "me" ? ", " + esc(s.who) + " is doing it" : ""}</li>`).join("")}</ul>` : ""}
    ${d.plan.milestones.length ? `<h2>My milestones</h2><ul>${d.plan.milestones.map((m) => `<li>${esc(new Date(m.achieved_on + "T12:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }))}: ${esc(m.milestone)}${m.confirmed_at ? " (confirmed)" : ""}</li>`).join("")}</ul>` : ""}
    <h2>Who I share with</h2><ul>${d.organizations.map((o) => `<li>${esc(o.name)} (${esc(o.status)}): ${Object.entries(o.sharing).map(([k, v]) => esc(TOPIC_NAME[k] || k) + " " + esc(v)).join(", ") || "nothing private"}</li>`).join("") || "<li>Nobody</li>"}</ul>
    <script>window.onload=()=>window.print()<\/script></body></html>`);
  w.document.close();
}

load();
