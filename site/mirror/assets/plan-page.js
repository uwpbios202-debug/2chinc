// @ts-check
// The Human Mirror T6.3: My plan (goals by stage), My steps (action items), My milestones. One module for the three pages
// /mirror/my-mirror/plan/, /actions/, /milestones/ (body data-plan = plan | actions | milestones).
// Stages are Mirror1's six journey stages, shown as labels only: nothing is ever late and several can run at once.
import { requireArea, rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice, toast } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { voiceAll } from "/mirror/assets/mirror-voice.js?v=20261113c";
import { DIMENSIONS } from "/mirror/assets/dimensions.js?v=20261113a";

/** Mirror1 Part 3, Stephen's names, with a plain line each. */
export const STAGES = [
  [1, "Immediate stabilization", "Safe, fed, clean, a phone"],
  [2, "Establishing a foundation", "ID, benefits, health coverage, a bank account"],
  [3, "Establishing a home", "A place to live and the things that make it home"],
  [4, "Building earning capacity", "Skills, training, work"],
  [5, "Developing independence", "Steady income, savings, less need for emergency help"],
  [6, "Flourishing and contributing", "Growing, leading, giving back"],
];
const STAGE = Object.fromEntries(STAGES.map(([n, l]) => [String(n), l]));
const GOAL_STATUS = { active: "Working toward it", paused: "On hold", achieved: "Reached", let_go: "Let go" };
const STEP_STATUS = { open: "To do", done: "Done", dropped: "Not doing" };
const PRIVATE_AREAS = { physical_health: 1, mental_health: 1, identity_legal: 1, finances: 1, safety: 1 };
const day = (d) => new Date(String(d).length === 10 ? d + "T12:00:00" : d).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
const msg = (e) => (e instanceof Error ? e.message : String(e));
const today = () => { const d = new Date(); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); };
const areaOptions = (sel, blank) => `<option value="">${esc(blank)}</option>` + DIMENSIONS.map((d) =>
  `<option value="${d.key}"${d.key === sel ? " selected" : ""}>${esc(d.title)}${PRIVATE_AREAS[d.key] ? " (private)" : ""}</option>`).join("");
const tag = (t, cls = "") => `<span class="mm-tag${cls ? " " + cls : ""}">${esc(t)}</span>`;
const link = (attr, label) => `<button class="mm-btn mm-btn-quiet mm-small" type="button" ${attr} style="min-height:auto;padding:0">${esc(label)}</button>`;
const who = (role) => (role === "self" ? "" : ' <span class="mm-muted mm-small">(added by your coordinator)</span>');

/** @type {{ self: boolean, goals: any[], actions: any[], milestones: any[], needs: any[] }} */
let P = { self: true, goals: [], actions: [], milestones: [], needs: [] };
/** Goal ideas from the Vision reflection ("Who do I want to become?"). @type {any[]} */
let SUG = [];
let box = /** @type {HTMLElement} */ (document.body);
let kind = "plan";

export async function planPage() {
  kind = document.body.dataset.plan || "plan";
  box = /** @type {HTMLElement} */ (document.getElementById("mmBox"));
  await requireArea("my");
  load();
}

async function load(note = "") {
  try { P = await rpc("mirror_plan"); }
  catch (e) { box.innerHTML = notice("urgent", `<p>${esc(msg(e))}</p>`); return; }
  // ideas from the person's own Vision answers (person only; optional: the plan still works without them)
  SUG = [];
  if (kind === "plan" && P.self) { try { SUG = await rpc("mirror_goal_suggestions"); } catch { SUG = []; } }
  box.innerHTML = note + (kind === "actions" ? actionsView() : kind === "milestones" ? milestonesView() : planView());
  voiceAll(box);
  wire();
}

const NAV = `<p class="mm-small mm-row" style="gap:var(--mm-space-3)"><a href="/mirror/my-mirror/plan/">My plan</a>
  <a href="/mirror/my-mirror/actions/">My steps</a><a href="/mirror/my-mirror/milestones/">My milestones</a>
  <a href="/mirror/my-mirror/my-needs/">My needs</a><a href="/mirror/my-mirror/my-strengths/">My strengths</a></p>`;
const PRIVACY = `<p>Organizations you work with see goals, steps and milestones in everyday parts of life; private parts of life (health,
  how you feel, ID and legal, money, safety) only if you share that topic in <a href="/mirror/my-mirror/settings/">Settings</a>.
  Only you can remove something.</p>`;

// ---------------------------------------------------------------- forms
function goalForm(g) {
  const v = g || { dimension: "", title: "", detail: "", stage: null, hope_by: "", status: "active" };
  const id = g ? g.id : "new";
  return `<form class="mm-card" data-goal-form="${esc(id)}" novalidate style="margin-bottom:var(--mm-space-4)">
    <div class="mm-field"><label for="gt-${id}">Your goal</label>
      <span class="mm-hint" id="gth-${id}">In your words, for example "a place of my own" or "get my CDL".</span>
      <input class="mm-input" id="gt-${id}" maxlength="200" value="${esc(v.title)}" aria-describedby="gth-${id}"></div>
    <div class="mm-field"><label for="gd-${id}">Which part of life is it about?</label>
      <select class="mm-select" id="gd-${id}">${areaOptions(v.dimension, "Choose one")}</select></div>
    <fieldset class="mm-choices"><legend class="mm-legend">Which stage does it feel like? <span class="mm-muted">(a label, not a deadline)</span></legend>
      <label class="mm-choice"><input type="radio" name="gs-${id}" value=""${!v.stage ? " checked" : ""}> Not sure</label>
      ${STAGES.map(([n, l, h]) => `<label class="mm-choice"><input type="radio" name="gs-${id}" value="${n}"${Number(v.stage) === n ? " checked" : ""}> ${esc(l)} <span class="mm-muted mm-small">${esc(h)}</span></label>`).join("")}</fieldset>
    <div class="mm-field"><label for="gh-${id}">I hope to get there by <span class="mm-muted">(optional)</span></label>
      <span class="mm-hint" id="ghh-${id}">Only a hope. Nothing is ever late here.</span>
      <input class="mm-input" type="date" id="gh-${id}" value="${esc(v.hope_by || "")}" aria-describedby="ghh-${id}" style="max-width:14rem"></div>
    <div class="mm-field"><label for="ge-${id}">More about it <span class="mm-muted">(optional)</span></label>
      <textarea class="mm-textarea" id="ge-${id}" rows="3" maxlength="2000">${esc(v.detail || "")}</textarea></div>
    ${g ? `<div class="mm-field"><label for="gu-${id}">Where it stands</label><select class="mm-select" id="gu-${id}">
      ${Object.entries(GOAL_STATUS).map(([k, l]) => `<option value="${k}"${k === v.status ? " selected" : ""}>${esc(l)}</option>`).join("")}</select></div>` : ""}
    <div data-err aria-live="assertive"></div>
    <div class="mm-row"><button class="mm-btn" type="submit">${g ? "Save changes" : "Add this goal"}</button>
      ${g ? '<button class="mm-btn mm-btn-quiet" type="button" data-cancel>Cancel</button>' : ""}</div>
  </form>`;
}

/** @param {any} s existing step or null @param {string} fid form id @param {any} pre { goal_id, need_id } */
function stepForm(s, fid, pre) {
  const v = s || { title: "", goal_id: pre && pre.goal_id || "", need_id: pre && pre.need_id || "", who: "me", helper: "", due_on: "", status: "open" };
  const forVal = v.goal_id ? "g:" + v.goal_id : v.need_id ? "n:" + v.need_id : "";
  const goals = P.goals.filter((g) => g.status === "active" || g.status === "paused" || g.id === v.goal_id);
  const fixed = pre && (pre.goal_id || pre.need_id);
  return `<form class="mm-card" data-step-form="${esc(fid)}" novalidate style="margin:var(--mm-space-3) 0">
    <div class="mm-field"><label for="st-${fid}">The step</label>
      <span class="mm-hint" id="sth-${fid}">One thing to do, for example "call the DMV" or "ask for a fee waiver".</span>
      <input class="mm-input" id="st-${fid}" maxlength="200" value="${esc(v.title)}" aria-describedby="sth-${fid}"></div>
    ${fixed ? `<input type="hidden" id="sf-${fid}" value="${esc(forVal)}">` : `<div class="mm-field"><label for="sf-${fid}">It's a step toward <span class="mm-muted">(optional)</span></label>
      <select class="mm-select" id="sf-${fid}"><option value="">Nothing in particular</option>
        ${goals.length ? `<optgroup label="My goals">${goals.map((g) => `<option value="g:${esc(g.id)}"${forVal === "g:" + g.id ? " selected" : ""}>${esc(g.title)}</option>`).join("")}</optgroup>` : ""}
        ${P.needs.length ? `<optgroup label="My needs">${P.needs.map((n) => `<option value="n:${esc(n.id)}"${forVal === "n:" + n.id ? " selected" : ""}>${esc(n.title)}</option>`).join("")}</optgroup>` : ""}
      </select></div>`}
    <fieldset class="mm-choices"><legend class="mm-legend">Who does it?</legend>
      <label class="mm-choice"><input type="radio" name="sw-${fid}" value="me"${v.who === "me" ? " checked" : ""}> Me</label>
      <label class="mm-choice"><input type="radio" name="sw-${fid}" value="helper"${v.who === "helper" ? " checked" : ""}> Someone helping me</label></fieldset>
    <div class="mm-field"><label for="sh-${fid}">Who is helping? <span class="mm-muted">(if someone is)</span></label>
      <input class="mm-input" id="sh-${fid}" maxlength="120" value="${esc(v.helper || "")}" placeholder="For example: my coordinator, my sister"></div>
    <div class="mm-field"><label for="sd-${fid}">Hope to do it by <span class="mm-muted">(optional)</span></label>
      <input class="mm-input" type="date" id="sd-${fid}" value="${esc(v.due_on || "")}" style="max-width:14rem"></div>
    <div data-err aria-live="assertive"></div>
    <div class="mm-row"><button class="mm-btn" type="submit">${s ? "Save changes" : "Add this step"}</button>
      ${s || fixed ? '<button class="mm-btn mm-btn-quiet" type="button" data-cancel>Cancel</button>' : ""}</div>
  </form>`;
}

function milestoneForm(m, fid) {
  const v = m || { title: "", detail: "", achieved_on: today(), goal_id: "", dimension: "" };
  const goals = P.goals;
  return `<form class="mm-card" data-ms-form="${esc(fid)}" novalidate style="margin-bottom:var(--mm-space-4)">
    <div class="mm-field"><label for="mt-${fid}">What did you do?</label>
      <span class="mm-hint" id="mth-${fid}">Big or small: "got my state ID", "first week at the new job", "cooked for my family".</span>
      <input class="mm-input" id="mt-${fid}" maxlength="200" value="${esc(v.title)}" aria-describedby="mth-${fid}"></div>
    <div class="mm-field"><label for="mo-${fid}">When?</label>
      <input class="mm-input" type="date" id="mo-${fid}" value="${esc(v.achieved_on)}" max="${today()}" style="max-width:14rem"></div>
    <div class="mm-field"><label for="mg-${fid}">Part of a goal? <span class="mm-muted">(optional)</span></label>
      <select class="mm-select" id="mg-${fid}"><option value="">No</option>${goals.map((g) => `<option value="${esc(g.id)}"${g.id === v.goal_id ? " selected" : ""}>${esc(g.title)}</option>`).join("")}</select></div>
    <div class="mm-field"><label for="md-${fid}">Part of life <span class="mm-muted">(optional; a goal brings its own)</span></label>
      <select class="mm-select" id="md-${fid}">${areaOptions(v.dimension || "", "All of life")}</select></div>
    <div class="mm-field"><label for="me-${fid}">More about it <span class="mm-muted">(optional)</span></label>
      <textarea class="mm-textarea" id="me-${fid}" rows="3" maxlength="2000">${esc(v.detail || "")}</textarea></div>
    <div data-err aria-live="assertive"></div>
    <div class="mm-row"><button class="mm-btn" type="submit">${m ? "Save changes" : "Add this milestone"}</button>
      ${m ? '<button class="mm-btn mm-btn-quiet" type="button" data-cancel>Cancel</button>' : ""}</div>
  </form>`;
}

// ---------------------------------------------------------------- items
function stepLine(s) {
  const forWhat = !s.goal_id && s.need_id && s.need_title ? ` <span class="mm-muted mm-small">for the need: ${esc(s.need_title)}</span>` : "";
  const goal = kind === "actions" && s.goal_id ? P.goals.find((g) => g.id === s.goal_id) : null;
  return `<li data-step="${esc(s.id)}" style="padding:var(--mm-space-2) 0;border-top:1px solid var(--mm-border);list-style:none">
    ${s.status === "done" ? "✓ " : ""}<span${s.status !== "open" ? ' class="mm-muted"' : ""}>${esc(s.title)}</span>
    ${s.who === "helper" ? tag(s.helper) : ""}${s.private ? " " + tag("Private", "mm-tag-info") : ""}
    ${goal ? ` <span class="mm-muted mm-small">for the goal: ${esc(goal.title)}</span>` : ""}${forWhat}
    ${s.due_on && s.status === "open" ? ` <span class="mm-muted mm-small">hope by ${esc(day(s.due_on))}</span>` : ""}${who(s.added_by_role)}
    <span class="mm-small" style="display:block">
      ${s.status !== "done" ? link("data-step-done", "Mark done") + " · " : link("data-step-open", "Not done yet") + " · "}
      ${s.status === "open" ? link("data-step-drop", "Not doing it") + " · " : ""}${s.status === "dropped" ? link("data-step-open", "Back to do") + " · " : ""}
      ${link("data-step-edit", "Change")}${P.self ? " · " + link("data-step-del", "Remove") : ""}</span>
    <div data-more></div></li>`;
}

function goalCard(g) {
  const steps = P.actions.filter((s) => s.goal_id === g.id);
  const open = steps.filter((s) => s.status === "open").length;
  return `<div class="mm-card" style="margin-bottom:var(--mm-space-4)" data-goal="${esc(g.id)}">
    <p class="mm-muted mm-small" style="margin:0">${esc(g.dimension_title)}${g.stage ? " · " + tag(STAGE[String(g.stage)]) : ""}${g.private ? " · " + tag("Private", "mm-tag-info") : ""}</p>
    <h3 style="margin:var(--mm-space-2) 0">${esc(g.title)}</h3>
    ${g.detail ? `<p>${esc(g.detail)}</p>` : ""}
    <p class="mm-small"><strong>${esc(GOAL_STATUS[g.status])}</strong>${g.status === "achieved" ? " on " + esc(day(g.achieved_on)) : ""}${g.hope_by && g.status === "active" ? `. Hope to get there by ${esc(day(g.hope_by))}` : ""}.${who(g.set_by_role)}</p>
    ${steps.length ? `<p class="mm-small" style="margin-bottom:0">Steps (${open} to do):</p><ul style="padding:0;margin:0">${steps.map(stepLine).join("")}</ul>` : ""}
    <p class="mm-small" style="margin-top:var(--mm-space-3)">${g.status === "active" || g.status === "paused" ? link("data-goal-step", "Add a step") + " · " : ""}
      ${g.status !== "achieved" ? link("data-goal-reached", "I reached it") + " · " : ""}${link("data-goal-edit", "Change")}${P.self ? " · " + link("data-goal-del", "Remove") : ""}</p>
    <div data-more></div>
  </div>`;
}

function msCard(m) {
  return `<li class="mm-card" style="list-style:none;margin-bottom:var(--mm-space-3)" data-ms="${esc(m.id)}">
    <p class="mm-muted mm-small" style="margin:0">${esc(day(m.achieved_on))}${m.dimension_title ? " · " + esc(m.dimension_title) : ""}${m.private ? " · " + tag("Private", "mm-tag-info") : ""}</p>
    <strong>${esc(m.title)}</strong>${m.automatic ? ` <span class="mm-muted mm-small">(a goal you reached)</span>` : ""}
    ${m.verified ? " " + tag("Confirmed by an organization you work with", "mm-tag-ok") : ""}
    ${m.detail ? `<p style="margin:var(--mm-space-2) 0 0">${esc(m.detail)}</p>` : ""}
    <p class="mm-small" style="margin:var(--mm-space-2) 0 0">${link("data-ms-edit", "Change")}${P.self ? " · " + link("data-ms-del", "Remove") : ""}</p>
    <div data-more></div></li>`;
}

/** One idea from a Vision answer: the person may change the words, pick the area if there is none, then "Add as a goal" or "Not now". */
function suggestionCard(s, i) {
  return `<div class="mm-card" style="margin-bottom:var(--mm-space-3)" data-gsug="${i}">
    <p class="mm-muted mm-small" style="margin:0">${tag("Suggested", "mm-tag-suggested")} · ${s.dimension_title ? esc(s.dimension_title) : "Area of life: you choose"}${s.private ? " · " + tag("Private", "mm-tag-info") : ""}</p>
    <p class="mm-muted mm-small">From your answer to: ${esc(s.source)}</p>
    <div class="mm-field"><label for="gst-${i}">Your goal, in your words</label>
      <span class="mm-hint" id="gsth-${i}">Change the words if you like.${s.detail && s.detail !== s.title ? " Your whole answer is kept in the details." : ""}</span>
      <input class="mm-input" id="gst-${i}" maxlength="200" value="${esc(s.title)}" aria-describedby="gsth-${i}"></div>
    ${s.dimension ? "" : `<div class="mm-field"><label for="gsd-${i}">Which part of life is it about?</label>
      <select class="mm-select" id="gsd-${i}">${areaOptions("", "Choose one")}</select></div>`}
    <div class="mm-row"><button class="mm-btn mm-btn-secondary" type="button" data-gtake>Add as a goal</button>
      <button class="mm-btn mm-btn-quiet" type="button" data-gskip>Not now</button></div>
  </div>`;
}

// ---------------------------------------------------------------- the three views
function planView() {
  const live = P.goals.filter((g) => g.status === "active" || g.status === "paused");
  const reached = P.goals.filter((g) => g.status === "achieved");
  const letGo = P.goals.filter((g) => g.status === "let_go");
  const byStage = STAGES.map(([n, l, h]) => [l, h, live.filter((g) => g.stage === n)]).concat([["No stage chosen", "", live.filter((g) => !g.stage)]])
    .filter(([, , xs]) => xs.length);
  return `<div class="mm-read">${NAV}
    ${notice("info", `<p>The six stages come from the journey many people walk, from the first days to flourishing. They are labels, not deadlines:
      you can work on several at once, in any order, and nothing here is ever late.</p>${PRIVACY}`)}
    ${SUG.length ? `<h2>Ideas from your answers (${SUG.length})</h2>
      <p class="mm-small">From what you said in <a href="/mirror/my-mirror/vision/">Who do I want to become?</a> Nothing is added unless you choose it.</p>
      ${SUG.map(suggestionCard).join("")}` : ""}
    <h2>Add a goal</h2>${goalForm(null)}
    <h2>Working toward (${live.length})</h2>
    ${byStage.length ? byStage.map(([l, h, xs]) => `<h3>${esc(l)}${h ? ` <span class="mm-muted mm-small">${esc(h)}</span>` : ""}</h3>${xs.map(goalCard).join("")}`).join("")
      : '<p class="mm-muted">No goals yet. Your answers to <a href="/mirror/my-mirror/vision/">Who do I want to become?</a> may give you ideas.</p>'}
    ${reached.length ? `<h2>Reached (${reached.length})</h2>${reached.map(goalCard).join("")}` : ""}
    ${letGo.length ? `<h2>Let go (${letGo.length})</h2>${letGo.map(goalCard).join("")}` : ""}
  </div>`;
}

function actionsView() {
  const open = P.actions.filter((s) => s.status === "open");
  const mine = open.filter((s) => s.who === "me"), others = open.filter((s) => s.who === "helper");
  const done = P.actions.filter((s) => s.status === "done"), dropped = P.actions.filter((s) => s.status === "dropped");
  const list = (xs) => `<ul style="padding:0;margin:0">${xs.map(stepLine).join("")}</ul>`;
  return `<div class="mm-read">${NAV}
    ${notice("info", `<p>Things to do, one at a time: yours, and what others are doing for you. A step can belong to a goal or a need.</p>${PRIVACY}`)}
    <h2>Add a step</h2>${stepForm(null, "new", null)}
    <h2>I'm doing (${mine.length})</h2>${mine.length ? list(mine) : '<p class="mm-muted">Nothing here yet.</p>'}
    <h2>Others are doing for me (${others.length})</h2>${others.length ? list(others) : '<p class="mm-muted">Nothing here yet.</p>'}
    ${done.length ? `<h2>Done (${done.length})</h2>${list(done)}` : ""}
    ${dropped.length ? `<h2>Not doing (${dropped.length})</h2>${list(dropped)}` : ""}
  </div>`;
}

function milestonesView() {
  return `<div class="mm-read">${NAV}
    ${notice("info", `<p>Everything you have done counts, big or small. Reaching a goal adds a milestone here by itself.
      An organization you work with can confirm a milestone if you'd like proof of it.</p>${PRIVACY}`)}
    <h2>Add a milestone</h2>${milestoneForm(null, "new")}
    <h2>What I've done (${P.milestones.length})</h2>
    ${P.milestones.length ? `<ul style="padding:0">${P.milestones.map(msCard).join("")}</ul>` : '<p class="mm-muted">Nothing here yet.</p>'}
  </div>`;
}

// ---------------------------------------------------------------- saving
const q = (f, sel) => /** @type {HTMLInputElement} */ (f.querySelector(sel));
const radio = (f, name) => { const r = /** @type {HTMLInputElement|null} */ (f.querySelector(`input[name="${name}"]:checked`)); return r ? r.value : ""; };

async function save(f, fn, id, payload, done = "Saved.") {
  const err = /** @type {HTMLElement} */ (f.querySelector("[data-err]"));
  try { await rpc(fn, { p_id: id, p: payload }); toast(done); load(); }
  catch (e) { err.innerHTML = notice("urgent", `<p>${esc(msg(e))}</p>`); }
}

function goalPayload(f, id, status) {
  return { dimension: q(f, "#gd-" + id).value, title: q(f, "#gt-" + id).value, detail: q(f, "#ge-" + id).value,
    stage: radio(f, "gs-" + id), hope_by: q(f, "#gh-" + id).value, status: status || (q(f, "#gu-" + id) ? q(f, "#gu-" + id).value : "active") };
}

function wireGoalForm(f, g) {
  const id = g ? g.id : "new";
  f.addEventListener("submit", (e) => {
    e.preventDefault();
    const p = goalPayload(f, id, null);
    const err = /** @type {HTMLElement} */ (f.querySelector("[data-err]"));
    if (!p.title.trim()) { err.innerHTML = notice("caution", "<p>Say your goal in a few words.</p>"); return; }
    if (!p.dimension) { err.innerHTML = notice("caution", "<p>Choose which part of life it is about.</p>"); return; }
    save(f, "mirror_goal_save", g ? g.id : null, p, g ? "Saved." : "Added.");
  });
}

function wireStepForm(f, s, fid) {
  f.addEventListener("submit", (e) => {
    e.preventDefault();
    const err = /** @type {HTMLElement} */ (f.querySelector("[data-err]"));
    const fv = q(f, "#sf-" + fid).value;
    const p = { title: q(f, "#st-" + fid).value, goal_id: fv.startsWith("g:") ? fv.slice(2) : "", need_id: fv.startsWith("n:") ? fv.slice(2) : "",
      who: radio(f, "sw-" + fid) || "me", helper: q(f, "#sh-" + fid).value, due_on: q(f, "#sd-" + fid).value, status: s ? s.status : "open" };
    if (!p.title.trim()) { err.innerHTML = notice("caution", "<p>Say the step in a few words.</p>"); return; }
    if (p.who === "helper" && !p.helper.trim()) { err.innerHTML = notice("caution", "<p>Say who is helping with this step.</p>"); return; }
    save(f, "mirror_action_save", s ? s.id : null, p, s ? "Saved." : "Added.");
  });
}

function wireMsForm(f, m, fid) {
  f.addEventListener("submit", (e) => {
    e.preventDefault();
    const err = /** @type {HTMLElement} */ (f.querySelector("[data-err]"));
    const p = { title: q(f, "#mt-" + fid).value, achieved_on: q(f, "#mo-" + fid).value, goal_id: q(f, "#mg-" + fid).value,
      dimension: q(f, "#md-" + fid).value, detail: q(f, "#me-" + fid).value };
    if (!p.title.trim()) { err.innerHTML = notice("caution", "<p>Say what you did in a few words.</p>"); return; }
    save(f, "mirror_milestone_save", m ? m.id : null, p, m ? "Saved." : "Added.");
  });
}

/** open a form in an item's "more" area */
function openIn(more, html, wireFn) {
  more.innerHTML = html;
  const f = /** @type {HTMLFormElement} */ (more.querySelector("form"));
  voiceAll(f);
  wireFn(f);
  f.querySelector("[data-cancel]")?.addEventListener("click", () => { more.innerHTML = ""; });
  /** @type {HTMLElement} */ (f.querySelector("input:not([type=hidden])")).focus();
}

function confirmRemove(more, what, kindKey, id) {
  more.innerHTML = `<p class="mm-small" style="margin-top:var(--mm-space-2)">Remove "${esc(what)}"?${kindKey === "goal" ? " Its steps go too; its milestones stay." : ""}
    <button class="mm-btn mm-btn-secondary" type="button" data-yes>Yes, remove</button> <button class="mm-btn mm-btn-quiet" type="button" data-no>Keep it</button></p>`;
  more.querySelector("[data-no]")?.addEventListener("click", () => { more.innerHTML = ""; });
  more.querySelector("[data-yes]")?.addEventListener("click", async () => {
    try { await rpc("mirror_plan_delete", { p_kind: kindKey, p_id: id }); toast("Removed."); load(); } catch (e) { toast(msg(e)); }
  });
}

async function stepStatus(s, status) {
  try {
    await rpc("mirror_action_save", { p_id: s.id, p: { title: s.title, goal_id: s.goal_id || "", need_id: s.need_id || "", who: s.who, helper: s.helper || "", due_on: s.due_on || "", status } });
    toast(status === "done" ? "Done. Well done." : "Saved."); load();
  } catch (e) { toast(msg(e)); }
}

function wire() {
  const gNew = /** @type {HTMLFormElement|null} */ (box.querySelector('[data-goal-form="new"]'));
  if (gNew) wireGoalForm(gNew, null);
  const sNew = /** @type {HTMLFormElement|null} */ (box.querySelector('[data-step-form="new"]'));
  if (sNew) wireStepForm(sNew, null, "new");
  const mNew = /** @type {HTMLFormElement|null} */ (box.querySelector('[data-ms-form="new"]'));
  if (mNew) wireMsForm(mNew, null, "new");

  box.querySelectorAll("[data-gsug]").forEach((el) => {
    const i = Number(/** @type {HTMLElement} */ (el).dataset.gsug), s = SUG[i];
    el.querySelector("[data-gtake]")?.addEventListener("click", async (e) => {
      const b = /** @type {HTMLButtonElement} */ (e.currentTarget);
      const t = /** @type {HTMLInputElement} */ (el.querySelector("#gst-" + i));
      const pick = /** @type {HTMLSelectElement|null} */ (el.querySelector("#gsd-" + i));
      if (!t.value.trim()) { toast("Say your goal in a few words."); t.focus(); return; }
      if (pick && !pick.value) { toast("Choose which part of life it is about."); pick.focus(); return; }
      b.disabled = true;
      try { await rpc("mirror_goal_add_suggested", { p_key: s.key, p_title: t.value, p_dimension: pick ? pick.value : null }); toast("Added to your goals."); load(); }
      catch (err) { b.disabled = false; toast(msg(err)); }
    });
    el.querySelector("[data-gskip]")?.addEventListener("click", async (e) => {
      /** @type {HTMLButtonElement} */ (e.currentTarget).disabled = true;
      try { await rpc("mirror_goal_suggestion_dismiss", { p_key: s.key }); load(); }
      catch (err) { toast(msg(err)); }
    });
  });

  box.querySelectorAll("[data-goal]").forEach((el) => {
    const g = P.goals.find((x) => x.id === /** @type {HTMLElement} */ (el).dataset.goal);
    const more = /** @type {HTMLElement} */ (el.querySelector(":scope > [data-more]"));
    el.querySelector("[data-goal-edit]")?.addEventListener("click", () => openIn(more, goalForm(g), (f) => wireGoalForm(f, g)));
    el.querySelector("[data-goal-step]")?.addEventListener("click", () => openIn(more, stepForm(null, "g" + g.id, { goal_id: g.id }), (f) => wireStepForm(f, null, "g" + g.id)));
    el.querySelector("[data-goal-del]")?.addEventListener("click", () => confirmRemove(more, g.title, "goal", g.id));
    el.querySelector("[data-goal-reached]")?.addEventListener("click", async () => {
      try {
        await rpc("mirror_goal_save", { p_id: g.id, p: { dimension: g.dimension, title: g.title, detail: g.detail || "", stage: g.stage ? String(g.stage) : "", hope_by: g.hope_by || "", status: "achieved" } });
        toast("Reached! It's on your milestones too."); load();
      } catch (e) { toast(msg(e)); }
    });
  });

  box.querySelectorAll("[data-step]").forEach((el) => {
    const s = P.actions.find((x) => x.id === /** @type {HTMLElement} */ (el).dataset.step);
    const more = /** @type {HTMLElement} */ (el.querySelector("[data-more]"));
    el.querySelector("[data-step-done]")?.addEventListener("click", () => stepStatus(s, "done"));
    el.querySelector("[data-step-open]")?.addEventListener("click", () => stepStatus(s, "open"));
    el.querySelector("[data-step-drop]")?.addEventListener("click", () => stepStatus(s, "dropped"));
    el.querySelector("[data-step-edit]")?.addEventListener("click", () => openIn(more, stepForm(s, "s" + s.id, null), (f) => wireStepForm(f, s, "s" + s.id)));
    el.querySelector("[data-step-del]")?.addEventListener("click", () => confirmRemove(more, s.title, "action", s.id));
  });

  box.querySelectorAll("[data-ms]").forEach((el) => {
    const m = P.milestones.find((x) => x.id === /** @type {HTMLElement} */ (el).dataset.ms);
    const more = /** @type {HTMLElement} */ (el.querySelector("[data-more]"));
    el.querySelector("[data-ms-edit]")?.addEventListener("click", () => openIn(more, milestoneForm(m, "m" + m.id), (f) => wireMsForm(f, m, "m" + m.id)));
    el.querySelector("[data-ms-del]")?.addEventListener("click", () => confirmRemove(more, m.title, "milestone", m.id));
  });
}
