// @ts-check
// The Human Mirror Phase 8, T8.2: the one-person overview for coordinators (/mirror/workspace/person/?id=&org=).
// Sections: safety note (P2-06), needs (status, confirm, change the words: recorded in the need's own history), strengths, plan
// (goals, steps, milestones with the confirm button), progress (counts, never a score); T8.4 services; T8.5 appointments and contact notes; T8.6 benefits; T8.7 donated goods given. Every read and write goes through the same
// gated functions the person's own pages use; each section shows only what the person shares; private looks are logged for them.
import { rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice, toast } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { progressBox } from "/mirror/assets/progress-page.js?v=20261113b";
import { DIMENSIONS } from "/mirror/assets/dimensions.js?v=20261113a";

const NEED = { identified: "Noted", planning: "Planning", in_progress: "Working on it", obtained: "Got it", verified: "Confirmed met", no_longer_needed: "No longer needed" };
const OPEN = ["identified", "planning", "in_progress", "obtained", "no_longer_needed"];
const URG = { urgent: "Urgent", soon: "Soon", later: "Later" };
const KIND = { skill: "Skills", talent: "Talents", experience: "Experience", credential: "Papers and training", language: "Languages", interest: "Interests", relationship: "People in their corner" };
const STAGE = { 1: "Immediate stabilization", 2: "Establishing a foundation", 3: "Establishing a home", 4: "Building earning capacity", 5: "Developing independence", 6: "Flourishing and contributing" };
const GOAL = { active: "Working toward it", paused: "On hold", achieved: "Reached", let_go: "Let go" };
const STEP = { open: "To do", done: "Done", dropped: "Not doing" };
const ENR = { active: "Getting it", paused: "On hold", completed: "Finished", ended: "Stopped" };
const day = (/** @type {string} */ d) => new Date(String(d).length === 10 ? d + "T12:00:00" : d).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
const msg = (/** @type {unknown} */ e) => (e instanceof Error ? e.message : String(e));
const tag = (/** @type {string} */ t, cls = "") => `<span class="mm-tag${cls ? " " + cls : ""}">${esc(t)}</span>`;
const priv = (/** @type {any} */ x) => (x.private ? " " + tag("Private, shared with you", "mm-tag-info") : "");
const by = (/** @type {string} */ r) => (r === "self" ? "them" : r === "coordinator" || r === "org_admin" ? "a coordinator" : r || "someone");

/** P2-06: the safety note. Shown whenever the person turned on safety mode. @param {string} name */
export function safetyBanner(name) {
  return notice("urgent", `<p><strong>Safety note: ${esc(name)} turned on safety mode.</strong> Someone in their life may be watching their phone,
    email or mail. Ask ${esc(name)} how and when it is safe to reach them. Don't leave messages that mention the Mirror, this organization or any
    details, and don't send papers home unless they say it's safe. Their private questions are never read aloud on their device.</p>
    <p class="mm-small">In danger now: 911. National Domestic Violence Hotline: 1-800-799-7233, or text START to 88788.</p>`);
}

/** Needs, with status changes, "confirm met" and word changes. @param {HTMLElement} el @param {string} id @param {string} name */
export async function needsBox(el, id, name) {
  /** @type {any} */ let N;
  try { N = await rpc("mirror_needs_list", { p_individual: id }); }
  catch (e) { el.innerHTML = notice("caution", `<p>${esc(msg(e))}</p>`); return; }
  const canEdit = (/** @type {any} */ n) => N.can_add.includes(n.category);
  const card = (/** @type {any} */ n) => `<li class="mm-card" style="list-style:none;margin-bottom:var(--mm-space-3)" data-need="${esc(n.id)}">
    <p class="mm-muted mm-small" style="margin:0">${esc(n.dimension_title)} · ${tag(URG[n.urgency] || n.urgency, n.urgency === "urgent" ? "mm-tag-urgent" : "")}${priv(n)}</p>
    <strong>${esc(n.title)}</strong> <span class="mm-small">· ${esc(NEED[n.status] || n.status)}</span>
    ${n.detail ? `<p class="mm-small" style="margin:var(--mm-space-1) 0">${esc(n.detail)}</p>` : ""}
    <p class="mm-small mm-muted" style="margin:var(--mm-space-1) 0">Noted by ${esc(by(n.identified_by_role))} on ${esc(day(n.created_at))}${n.verified_at ? `; confirmed met on ${esc(day(n.verified_at))}` : ""}.</p>
    <p class="mm-small" style="margin:0">
      <button class="mm-btn mm-btn-quiet mm-small" type="button" data-hist style="min-height:auto;padding:0">History</button>
      ${canEdit(n) ? ` · <button class="mm-btn mm-btn-quiet mm-small" type="button" data-move style="min-height:auto;padding:0">Change where it stands</button>
        · <button class="mm-btn mm-btn-quiet mm-small" type="button" data-words style="min-height:auto;padding:0">Change the words</button>` : ""}
      ${canEdit(n) && n.status === "obtained" ? ` · <button class="mm-btn mm-btn-secondary mm-small" type="button" data-verify>Confirm it's met</button>` : ""}</p>
    <div data-more></div></li>`;
  const open = N.needs.filter((/** @type {any} */ n) => ["identified", "planning", "in_progress"].includes(n.status));
  const rest = N.needs.filter((/** @type {any} */ n) => !open.includes(n));
  el.innerHTML = N.needs.length
    ? `${open.length ? `<h3>Open (${open.length})</h3><ul style="padding:0">${open.map(card).join("")}</ul>` : ""}
       ${rest.length ? `<h3>Met or closed (${rest.length})</h3><ul style="padding:0">${rest.map(card).join("")}</ul>` : ""}
       <p class="mm-small mm-muted">Anything you change is written into the need's own history, which ${esc(name)} sees. Only ${esc(name)} removes a need.</p>`
    : `<p class="mm-muted">No needs shared with you yet.</p>`;
  el.querySelectorAll("[data-need]").forEach((li) => {
    const n = N.needs.find((/** @type {any} */ x) => x.id === /** @type {HTMLElement} */ (li).dataset.need);
    const more = /** @type {HTMLElement} */ (li.querySelector("[data-more]"));
    li.querySelector("[data-hist]")?.addEventListener("click", async () => {
      try {
        const h = await rpc("mirror_need_history", { p_id: n.id });
        more.innerHTML = `<ul class="mm-small">${h.map((/** @type {any} */ x) => `<li>${esc(day(x.at))}: ${x.from && x.from === x.to ? "changed"
          : (x.from ? esc(NEED[x.from] || x.from) + " → " : "") + esc(NEED[x.to] || x.to)}, by ${esc(by(x.by_role))}${x.note ? ": " + esc(x.note) : ""}</li>`).join("")}</ul>`;
      } catch (e) { more.innerHTML = notice("caution", `<p>${esc(msg(e))}</p>`); }
    });
    li.querySelector("[data-move]")?.addEventListener("click", () => {
      more.innerHTML = `<form class="mm-row" style="align-items:flex-end;gap:var(--mm-space-3);margin-top:var(--mm-space-2)" novalidate>
        <div class="mm-field" style="margin:0"><label for="ns-${n.id}">Where it stands</label><select class="mm-select" id="ns-${n.id}">
          ${OPEN.map((s) => `<option value="${s}"${s === n.status ? " selected" : ""}>${esc(NEED[s])}</option>`).join("")}</select></div>
        <div class="mm-field" style="margin:0;min-width:14rem"><label for="nn-${n.id}">Note <span class="mm-muted">(${esc(name)} sees it)</span></label>
          <input class="mm-input" id="nn-${n.id}" maxlength="1000"></div>
        <button class="mm-btn" type="submit">Save</button></form>`;
      const f = /** @type {HTMLFormElement} */ (more.querySelector("form"));
      f.addEventListener("submit", async (e) => {
        e.preventDefault();
        const st = /** @type {HTMLSelectElement} */ (f.querySelector("select")).value, nt = /** @type {HTMLInputElement} */ (f.querySelector("input")).value;
        if (st === n.status) { toast("Nothing changed."); return; }
        try { await rpc("mirror_need_status", { p_id: n.id, p_status: st, p_note: nt }); toast("Saved. It's in the need's history."); needsBox(el, id, name); }
        catch (err) { toast(msg(err)); }
      });
    });
    li.querySelector("[data-words]")?.addEventListener("click", () => {
      more.innerHTML = `<form style="margin-top:var(--mm-space-2)" novalidate>
        <div class="mm-field"><label for="nt-${n.id}">The need, in their words</label><input class="mm-input" id="nt-${n.id}" maxlength="200" value="${esc(n.title)}"></div>
        <div class="mm-field"><label for="nd-${n.id}">Details</label><textarea class="mm-textarea" id="nd-${n.id}" rows="2" maxlength="2000">${esc(n.detail || "")}</textarea></div>
        <div class="mm-field" style="max-width:14rem"><label for="nu-${n.id}">How soon</label><select class="mm-select" id="nu-${n.id}">
          ${Object.entries(URG).map(([k, l]) => `<option value="${k}"${k === n.urgency ? " selected" : ""}>${esc(l)}</option>`).join("")}</select></div>
        <p class="mm-hint">Change it only together with ${esc(name)}. The old words are kept in the need's history.</p>
        <button class="mm-btn" type="submit">Save</button></form>`;
      const f = /** @type {HTMLFormElement} */ (more.querySelector("form"));
      f.addEventListener("submit", async (e) => {
        e.preventDefault();
        const v = (/** @type {string} */ k) => /** @type {HTMLInputElement} */ (f.querySelector("#" + k + "-" + n.id)).value;
        try { await rpc("mirror_need_save", { p_id: n.id, p_dimension: n.dimension, p_title: v("nt"), p_detail: v("nd"), p_urgency: v("nu"), p_individual: id });
          toast("Saved. It's in the need's history."); needsBox(el, id, name); }
        catch (err) { toast(msg(err)); }
      });
    });
    li.querySelector("[data-verify]")?.addEventListener("click", async (e) => {
      /** @type {HTMLButtonElement} */ (e.currentTarget).disabled = true;
      try { await rpc("mirror_need_status", { p_id: n.id, p_status: "verified", p_note: null }); toast("Confirmed. They see that you confirmed it."); needsBox(el, id, name); }
      catch (err) { toast(msg(err)); /** @type {HTMLButtonElement} */ (e.currentTarget).disabled = false; }
    });
  });
}

/** Strengths, read only (the person writes their strengths). @param {HTMLElement} el @param {string} id */
export async function strengthsBox(el, id) {
  /** @type {any} */ let S;
  try { S = await rpc("mirror_strengths", { p_individual: id }); }
  catch (e) { el.innerHTML = notice("caution", `<p>${esc(msg(e))}</p>`); return; }
  const groups = Object.keys(KIND).map((k) => [k, S.strengths.filter((/** @type {any} */ s) => s.kind === k)]).filter(([, xs]) => xs.length);
  el.innerHTML = groups.length ? groups.map(([k, xs]) => `<h3>${esc(KIND[k])}</h3><ul>${xs.map((/** @type {any} */ s) =>
      `<li>${esc(s.title)}${s.dimension_title ? ` <span class="mm-muted mm-small">(${esc(s.dimension_title)})</span>` : ""}${priv(s)}${s.detail ? `<br><span class="mm-small">${esc(s.detail)}</span>` : ""}</li>`).join("")}</ul>`).join("")
    : `<p class="mm-muted">No strengths shared with you yet.</p>`;
}

/** Plan: goals with their steps, other steps, milestones with the confirm button. @param {HTMLElement} el @param {string} id */
export async function planBox(el, id) {
  /** @type {any} */ let P;
  try { P = await rpc("mirror_plan", { p_individual: id }); }
  catch (e) { el.innerHTML = notice("caution", `<p>${esc(msg(e))}</p>`); return; }
  const step = (/** @type {any} */ s) => `<li>${s.status === "done" ? "✓ " : ""}${esc(s.title)} <span class="mm-muted mm-small">· ${esc(STEP[s.status] || s.status)}${s.who === "helper" ? ", " + esc(s.helper) + " is doing it" : ""}${s.due_on && s.status === "open" ? ", hope by " + esc(day(s.due_on)) : ""}${s.need_title ? ", for the need: " + esc(s.need_title) : ""}</span>${priv(s)}</li>`;
  const goals = P.goals.map((/** @type {any} */ g) => {
    const steps = P.actions.filter((/** @type {any} */ s) => s.goal_id === g.id);
    return `<div class="mm-card" style="margin-bottom:var(--mm-space-3)">
      <p class="mm-muted mm-small" style="margin:0">${esc(g.dimension_title)}${g.stage ? " · " + tag(STAGE[g.stage]) : ""}${priv(g)}</p>
      <strong>${esc(g.title)}</strong> <span class="mm-small">· ${esc(GOAL[g.status] || g.status)}${g.hope_by && g.status === "active" ? ", hope by " + esc(day(g.hope_by)) : ""}</span>
      ${steps.length ? `<ul class="mm-small">${steps.map(step).join("")}</ul>` : ""}</div>`;
  }).join("");
  const loose = P.actions.filter((/** @type {any} */ s) => !s.goal_id);
  const ms = P.milestones.map((/** @type {any} */ m) => `<li data-ms="${esc(m.id)}" style="margin-bottom:var(--mm-space-2)">${esc(day(m.achieved_on))}: <strong>${esc(m.title)}</strong>${priv(m)}
      ${m.verified ? " " + tag("Confirmed", "mm-tag-ok") + ` <button class="mm-btn mm-btn-quiet mm-small" type="button" data-unconfirm style="min-height:auto;padding:0">Take back</button>`
        : ` <button class="mm-btn mm-btn-secondary mm-small" type="button" data-confirm>Confirm it</button>`}</li>`).join("");
  el.innerHTML = `<h3>Goals (${P.goals.length})</h3>${goals || '<p class="mm-muted">No goals shared with you yet.</p>'}
    ${loose.length ? `<h3>Other steps (${loose.length})</h3><ul class="mm-small">${loose.map(step).join("")}</ul>` : ""}
    <h3>Milestones (${P.milestones.length})</h3>
    ${ms ? `<ul style="padding-left:1.2rem">${ms}</ul><p class="mm-small mm-muted">Confirm a milestone when you have seen it happen (for example the new ID card). They see that your organization confirmed it.
      You need their "see and change" for that topic.</p>` : '<p class="mm-muted">No milestones shared with you yet.</p>'}`;
  el.querySelectorAll("[data-ms]").forEach((li) => {
    const mid = /** @type {HTMLElement} */ (li).dataset.ms;
    const go = async (/** @type {boolean} */ yes) => {
      try { await rpc("mirror_milestone_confirm", { p_id: mid, p_confirm: yes }); toast(yes ? "Confirmed." : "Confirmation taken back."); planBox(el, id); }
      catch (err) { toast(msg(err)); }
    };
    li.querySelector("[data-confirm]")?.addEventListener("click", () => go(true));
    li.querySelector("[data-unconfirm]")?.addEventListener("click", () => go(false));
  });
}

/** T8.4: what the person gets from THIS organization (services and enrollments, D-34).
 * @param {HTMLElement} el @param {string} id @param {string} org @param {string} name */
export async function servicesBox(el, id, org, name) {
  /** @type {any} */ let E;
  try { E = await rpc("mirror_enrollments", { p_individual: id, p_org: org }); }
  catch (e) { el.innerHTML = notice("caution", `<p>${esc(msg(e))}</p>`); return; }
  const canEdit = (/** @type {any} */ x) => (E.can_edit || []).includes(x.category);
  const card = (/** @type {any} */ x) => `<li class="mm-card" style="list-style:none;margin-bottom:var(--mm-space-3)" data-enr="${esc(x.id)}">
    <p class="mm-muted mm-small" style="margin:0">${x.area ? esc(x.area) : "Everyday"}${priv(x)}</p>
    <strong>${esc(x.service)}</strong> <span class="mm-small">· ${esc(ENR[x.status] || x.status)}</span>
    <p class="mm-small mm-muted" style="margin:var(--mm-space-1) 0">Since ${esc(day(x.started_on))}${x.ended_on ? `, until ${esc(day(x.ended_on))}` : ""}.${x.note ? " " + esc(x.note) : ""}</p>
    <p class="mm-small" style="margin:0"><button class="mm-btn mm-btn-quiet mm-small" type="button" data-hist style="min-height:auto;padding:0">History</button>
      ${canEdit(x) ? ` · <button class="mm-btn mm-btn-quiet mm-small" type="button" data-move style="min-height:auto;padding:0">Change where it stands</button>` : ""}</p>
    <div data-more></div></li>`;
  const open = E.enrollments.filter((/** @type {any} */ x) => x.status === "active" || x.status === "paused");
  const rest = E.enrollments.filter((/** @type {any} */ x) => !open.includes(x));
  el.innerHTML = `${open.length ? `<h3>Getting now (${open.length})</h3><ul style="padding:0">${open.map(card).join("")}</ul>` : `<p class="mm-muted">They aren't getting any of your organization's services yet.</p>`}
    ${rest.length ? `<h3>Finished or stopped (${rest.length})</h3><ul style="padding:0">${rest.map(card).join("")}</ul>` : ""}
    ${E.services.length ? `<form class="mm-card mm-read" data-add novalidate style="margin-top:var(--mm-space-4)">
      <h3 style="margin-top:0">Enroll ${esc(name)}</h3>
      <div class="mm-field"><label for="sv-${esc(id)}">Service</label><select class="mm-select" id="sv-${esc(id)}">
        ${E.services.map((/** @type {any} */ s) => `<option value="${esc(s.id)}">${esc(s.name)}${s.area ? " (" + esc(s.area) + ")" : ""}${s.private ? ", private" : ""}</option>`).join("")}</select></div>
      <div class="mm-field" style="max-width:14rem"><label for="sd-${esc(id)}">Starting</label><input class="mm-input" type="date" id="sd-${esc(id)}" value="${new Date().toLocaleDateString("en-CA")}" data-mm-no-voice></div>
      <div class="mm-field"><label for="sn-${esc(id)}">Note <span class="mm-muted">(${esc(name)} sees it)</span></label><input class="mm-input" id="sn-${esc(id)}" maxlength="1000"></div>
      <p class="mm-hint">Enroll them only after they said yes to it. A service in a private part of life is listed only if they share that part with you.</p>
      <button class="mm-btn" type="submit">Enroll</button></form>` : ""}
    <p class="mm-small mm-muted">${esc(name)} sees every service they get on their own My Mirror, with its history, and can say they stopped getting one.
      Your organization's list of services: <a href="/mirror/workspace/services/?org=${encodeURIComponent(org)}">Services</a>.</p>`;
  el.querySelector("[data-add]")?.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const v = (/** @type {string} */ k) => /** @type {HTMLInputElement} */ (el.querySelector("#" + k + "-" + id)).value;
    try { await rpc("mirror_enrollment_save", { p: { service_id: v("sv"), individual_id: id, started_on: v("sd"), note: v("sn") } });
      toast("Enrolled. They see it on their My Mirror."); servicesBox(el, id, org, name); }
    catch (err) { toast(msg(err)); }
  });
  el.querySelectorAll("[data-enr]").forEach((li) => {
    const x = E.enrollments.find((/** @type {any} */ y) => y.id === /** @type {HTMLElement} */ (li).dataset.enr);
    const more = /** @type {HTMLElement} */ (li.querySelector("[data-more]"));
    li.querySelector("[data-hist]")?.addEventListener("click", () => {
      more.innerHTML = `<ul class="mm-small">${x.history.map((/** @type {any} */ h) => `<li>${esc(day(h.at))}: ${h.from && h.from !== h.to ? esc(ENR[h.from] || h.from) + " → " : ""}${esc(ENR[h.to] || h.to)}${h.from ? "" : " (enrolled)"}, by ${esc(by(h.by_role))}${h.note ? ": " + esc(h.note) : ""}</li>`).join("")}</ul>`;
    });
    li.querySelector("[data-move]")?.addEventListener("click", () => {
      more.innerHTML = `<form class="mm-row" style="align-items:flex-end;gap:var(--mm-space-3);margin-top:var(--mm-space-2)" novalidate>
        <div class="mm-field" style="margin:0"><label for="es-${x.id}">Where it stands</label><select class="mm-select" id="es-${x.id}">
          ${Object.entries(ENR).map(([k, l]) => `<option value="${k}"${k === x.status ? " selected" : ""}>${esc(l)}</option>`).join("")}</select></div>
        <div class="mm-field" style="margin:0"><label for="ee-${x.id}">End date <span class="mm-muted">(finished or stopped)</span></label>
          <input class="mm-input" type="date" id="ee-${x.id}" value="${esc(x.ended_on || "")}" data-mm-no-voice></div>
        <div class="mm-field" style="margin:0;min-width:14rem"><label for="en-${x.id}">Note <span class="mm-muted">(${esc(name)} sees it)</span></label>
          <input class="mm-input" id="en-${x.id}" maxlength="1000"></div>
        <button class="mm-btn" type="submit">Save</button></form>`;
      const f = /** @type {HTMLFormElement} */ (more.querySelector("form"));
      f.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const g = (/** @type {string} */ k) => /** @type {HTMLInputElement} */ (f.querySelector("#" + k + "-" + x.id)).value;
        try { await rpc("mirror_enrollment_save", { p: { id: x.id, status: g("es"), ended_on: g("ee"), note: g("en") } });
          toast("Saved. It's in the history they see."); servicesBox(el, id, org, name); }
        catch (err) { toast(msg(err)); }
      });
    });
  });
}

export { progressBox };

// ---------------------------------------------------------------- T8.5 appointments and contact notes (D-35)
const APPT = { scheduled: "Coming up", done: "Happened", cancelled: "Cancelled", not_happened: "Didn't happen" };
const KINDS = { visit: "Visit", call: "Call", message: "Message", meeting: "Meeting", other: "Other" };
const TOPIC = { general: "Everyday", health: "Physical health", mental_health: "How they feel inside", safety: "Safety", legal: "ID, papers and legal", financial: "Money" };
/** @type {Record<string, string>} */
const DIM_TOPIC = { physical_health: "health", mental_health: "mental_health", identity_legal: "legal", finances: "financial", safety: "safety" };
const when = (/** @type {string} */ t) => new Date(t).toLocaleString("en-US", { weekday: "short", month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
const localInput = (/** @type {string|null} */ t) => { if (!t) return ""; const d = new Date(t); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };
const iso = (/** @type {string} */ v) => (v ? new Date(v).toISOString() : "");

/** Appointments with THIS organization. @param {HTMLElement} el @param {string} id @param {string} org @param {string} name */
export async function appointmentsBox(el, id, org, name) {
  /** @type {any} */ let A;
  try { A = await rpc("mirror_appointments", { p_individual: id, p_org: org }); }
  catch (e) { el.innerHTML = notice("caution", `<p>${esc(msg(e))}</p>`); return; }
  /** @type {string[]} */ const edit = A.can_edit || [];
  const areas = DIMENSIONS.filter((d) => edit.includes(DIM_TOPIC[d.key] || "general"));
  const card = (/** @type {any} */ a) => `<li class="mm-card" style="list-style:none;margin-bottom:var(--mm-space-3)" data-appt="${esc(a.id)}">
    <p class="mm-muted mm-small" style="margin:0">${esc(when(a.starts_at))}${a.area ? " · " + esc(a.area) : ""}${priv(a)}</p>
    <strong>${esc(a.title)}</strong> <span class="mm-small">· ${esc(APPT[a.status] || a.status)}</span>
    ${a.place || a.with_whom ? `<p class="mm-small" style="margin:var(--mm-space-1) 0">${a.place ? "Where: " + esc(a.place) : ""}${a.place && a.with_whom ? " · " : ""}${a.with_whom ? "With: " + esc(a.with_whom) : ""}</p>` : ""}
    ${a.detail ? `<p class="mm-small" style="margin:var(--mm-space-1) 0">${esc(a.detail)}</p>` : ""}
    <p class="mm-small" style="margin:0"><button class="mm-btn mm-btn-quiet mm-small" type="button" data-hist style="min-height:auto;padding:0">History</button>
      ${edit.includes(a.category) ? ` · <button class="mm-btn mm-btn-quiet mm-small" type="button" data-change style="min-height:auto;padding:0">Change</button>` : ""}</p>
    <div data-more></div></li>`;
  const now = Date.now();
  const coming = A.appointments.filter((/** @type {any} */ a) => a.status === "scheduled" && new Date(a.starts_at).getTime() >= now - 3600e3).reverse();
  const past = A.appointments.filter((/** @type {any} */ a) => !coming.includes(a));
  const form = (/** @type {any} */ a) => `<form class="mm-card mm-read" novalidate style="margin-top:var(--mm-space-3)">
      ${a ? "" : `<h3 style="margin-top:0">Add an appointment with ${esc(name)}</h3>`}
      <div class="mm-field"><label for="at-${esc(id)}">What it's for</label><input class="mm-input" id="at-${esc(id)}" maxlength="200" value="${esc(a ? a.title : "")}"></div>
      <div class="mm-row" style="gap:var(--mm-space-3)">
        <div class="mm-field"><label for="as-${esc(id)}">Starts</label><input class="mm-input" type="datetime-local" id="as-${esc(id)}" value="${esc(localInput(a ? a.starts_at : null))}" data-mm-no-voice></div>
        <div class="mm-field"><label for="ae-${esc(id)}">Ends <span class="mm-muted">(optional)</span></label><input class="mm-input" type="datetime-local" id="ae-${esc(id)}" value="${esc(localInput(a ? a.ends_at : null))}" data-mm-no-voice></div></div>
      <div class="mm-field"><label for="ap-${esc(id)}">Where <span class="mm-muted">(optional)</span></label><input class="mm-input" id="ap-${esc(id)}" maxlength="300" value="${esc((a && a.place) || "")}"></div>
      <div class="mm-field"><label for="aw-${esc(id)}">With whom <span class="mm-muted">(optional)</span></label><input class="mm-input" id="aw-${esc(id)}" maxlength="200" value="${esc((a && a.with_whom) || "")}"></div>
      <div class="mm-field"><label for="ad-${esc(id)}">Details <span class="mm-muted">(optional; ${esc(name)} sees them)</span></label><textarea class="mm-textarea" id="ad-${esc(id)}" rows="2" maxlength="1000">${esc((a && a.detail) || "")}</textarea></div>
      ${a ? `<div class="mm-field" style="max-width:16rem"><label for="ax-${esc(id)}">Where it stands</label><select class="mm-select" id="ax-${esc(id)}">
          ${Object.entries(APPT).map(([k, l]) => `<option value="${k}"${k === a.status ? " selected" : ""}>${esc(l)}</option>`).join("")}</select></div>`
        : `<div class="mm-field" style="max-width:24rem"><label for="ak-${esc(id)}">Part of life</label><span class="mm-hint" id="akh-${esc(id)}">Private parts of life are listed only if they share them with you.</span>
          <select class="mm-select" id="ak-${esc(id)}" aria-describedby="akh-${esc(id)}">
          <option value="">Everyday (no one area)</option>${areas.map((d) => `<option value="${esc(d.key)}">${esc(d.title)}${DIM_TOPIC[d.key] ? " (private)" : ""}</option>`).join("")}</select></div>`}
      <div class="mm-field"><label for="an-${esc(id)}">Note for the history <span class="mm-muted">(optional)</span></label><input class="mm-input" id="an-${esc(id)}" maxlength="1000"></div>
      <button class="mm-btn" type="submit">${a ? "Save" : "Add appointment"}</button></form>`;
  el.innerHTML = `${coming.length ? `<h3>Coming up (${coming.length})</h3><ul style="padding:0">${coming.map(card).join("")}</ul>` : `<p class="mm-muted">No appointments coming up with your organization.</p>`}
    ${past.length ? `<details><summary>Earlier or cancelled (${past.length})</summary><ul style="padding:0;margin-top:var(--mm-space-3)">${past.map(card).join("")}</ul></details>` : ""}
    ${edit.length ? `<div data-new>${form(null)}</div>` : ""}
    <p class="mm-small mm-muted">${esc(name)} sees these on their My appointments page and can say they can't make it. Their own appointments stay theirs. No reminder is emailed yet.</p>`;
  /** @param {HTMLFormElement} f @param {any} a */
  const wireForm = (f, a) => f.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const v = (/** @type {string} */ k) => { const x = /** @type {HTMLInputElement|null} */ (f.querySelector("#" + k + "-" + id)); return x ? x.value : ""; };
    const p = { title: v("at"), starts_at: iso(v("as")), ends_at: iso(v("ae")), place: v("ap"), with_whom: v("aw"), detail: v("ad"), note: v("an") };
    try {
      await rpc("mirror_appointment_save", { p: a ? { ...p, id: a.id, status: v("ax") } : { ...p, individual_id: id, organization_id: org, dimension_key: v("ak") } });
      toast(a ? "Saved. It's in the history they see." : "Added. They see it on My appointments."); appointmentsBox(el, id, org, name);
    } catch (err) { toast(msg(err)); }
  });
  const nf = /** @type {HTMLFormElement|null} */ (el.querySelector("[data-new] form"));
  if (nf) wireForm(nf, null);
  el.querySelectorAll("[data-appt]").forEach((li) => {
    const a = A.appointments.find((/** @type {any} */ x) => x.id === /** @type {HTMLElement} */ (li).dataset.appt);
    const more = /** @type {HTMLElement} */ (li.querySelector("[data-more]"));
    li.querySelector("[data-hist]")?.addEventListener("click", () => {
      more.innerHTML = `<ul class="mm-small">${a.history.map((/** @type {any} */ h) => `<li>${esc(day(h.at))}: ${h.from && h.from !== h.to ? esc(APPT[h.from] || h.from) + " → " : ""}${esc(APPT[h.to] || h.to)}${h.from ? "" : " (added)"}, by ${esc(by(h.by_role))}${h.note ? ": " + esc(h.note) : ""}</li>`).join("")}</ul>`;
    });
    li.querySelector("[data-change]")?.addEventListener("click", () => {
      const nw = el.querySelector("[data-new]"); if (nw) nw.innerHTML = "";
      more.innerHTML = form(a);
      wireForm(/** @type {HTMLFormElement} */ (more.querySelector("form")), a);
    });
  });
}

/** Contact notes (visit, call, message ...). The person sees every note. @param {HTMLElement} el @param {string} id @param {string} org @param {string} name */
export async function notesBox(el, id, org, name) {
  /** @type {any} */ let N;
  try { N = await rpc("mirror_interactions", { p_individual: id, p_org: org }); }
  catch (e) { el.innerHTML = notice("caution", `<p>${esc(msg(e))}</p>`); return; }
  /** @type {string[]} */ const edit = N.can_edit || [];
  const item = (/** @type {any} */ x) => `<li class="mm-card" style="list-style:none;margin-bottom:var(--mm-space-3)" data-note="${esc(x.id)}">
    <p class="mm-muted mm-small" style="margin:0">${esc(when(x.at))} · ${esc(KINDS[x.kind] || x.kind)} · ${esc(x.by)}${priv(x)}${x.corrected ? " " + tag("Corrected") : ""}</p>
    ${x.corrects ? `<p class="mm-small mm-muted" style="margin:0">Correction of an earlier note</p>` : ""}
    <p style="margin:var(--mm-space-1) 0;white-space:pre-wrap">${esc(x.summary)}</p>
    ${edit.includes(x.category) && !x.corrects ? `<button class="mm-btn mm-btn-quiet mm-small" type="button" data-correct style="min-height:auto;padding:0">Add a correction</button>` : ""}
    <div data-more></div></li>`;
  const topics = Object.keys(TOPIC).filter((k) => edit.includes(k));
  el.innerHTML = `${edit.length ? `<form class="mm-card mm-read" data-add novalidate>
      <h3 style="margin-top:0">Add a note</h3>
      <div class="mm-row" style="gap:var(--mm-space-3)">
        <div class="mm-field"><label for="nk-${esc(id)}">Kind</label><select class="mm-select" id="nk-${esc(id)}">${Object.entries(KINDS).map(([k, l]) => `<option value="${k}">${esc(l)}</option>`).join("")}</select></div>
        <div class="mm-field"><label for="na-${esc(id)}">When</label><input class="mm-input" type="datetime-local" id="na-${esc(id)}" value="${esc(localInput(new Date().toISOString()))}" data-mm-no-voice></div>
        <div class="mm-field"><label for="nc-${esc(id)}">Topic</label><select class="mm-select" id="nc-${esc(id)}">${topics.map((k) => `<option value="${k}">${esc(TOPIC[/** @type {keyof typeof TOPIC} */ (k)])}${k === "general" ? "" : " (private)"}</option>`).join("")}</select></div></div>
      <div class="mm-field"><label for="ns-${esc(id)}">What happened</label><span class="mm-hint" id="nsh-${esc(id)}">${esc(name)} sees every note, with your name. Write it as you would say it to them. A note can't be changed later; you can add a correction.</span>
        <textarea class="mm-textarea" id="ns-${esc(id)}" rows="3" maxlength="4000" aria-describedby="nsh-${esc(id)}"></textarea></div>
      <button class="mm-btn" type="submit">Save the note</button></form>` : `<p class="mm-muted">To add notes you need their "see and change" for at least one topic.</p>`}
    ${N.notes.length ? `<ul style="padding:0;margin-top:var(--mm-space-4)">${N.notes.map(item).join("")}</ul>` : `<p class="mm-muted">No notes from your organization yet.</p>`}`;
  el.querySelector("[data-add]")?.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const v = (/** @type {string} */ k) => /** @type {HTMLInputElement} */ (el.querySelector("#" + k + "-" + id)).value;
    try { await rpc("mirror_interaction_add", { p: { individual_id: id, organization_id: org, kind: v("nk"), at: iso(v("na")), category: v("nc"), summary: v("ns") } });
      toast("Saved. They see it."); notesBox(el, id, org, name); }
    catch (err) { toast(msg(err)); }
  });
  el.querySelectorAll("[data-note]").forEach((li) => li.querySelector("[data-correct]")?.addEventListener("click", () => {
    const nid = /** @type {HTMLElement} */ (li).dataset.note || "";
    const more = /** @type {HTMLElement} */ (li.querySelector("[data-more]"));
    more.innerHTML = `<form novalidate style="margin-top:var(--mm-space-2)"><div class="mm-field"><label for="cr-${esc(nid)}">The correction</label>
      <textarea class="mm-textarea" id="cr-${esc(nid)}" rows="2" maxlength="4000"></textarea></div><button class="mm-btn" type="submit">Save the correction</button></form>`;
    more.querySelector("form")?.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      try { await rpc("mirror_interaction_add", { p: { individual_id: id, organization_id: org, corrects: nid,
          summary: /** @type {HTMLTextAreaElement} */ (more.querySelector("textarea")).value } });
        toast("Correction saved."); notesBox(el, id, org, name); }
      catch (err) { toast(msg(err)); }
    });
  }));
}

// ---------------------------------------------------------------- T8.6 benefits applications (D-37)
const BEN = { considering: "Thinking about applying", applied: "Applied, waiting", active: "Getting it now", denied: "Denied", appealing: "Appealing", ended: "Ended" };
const BEN_KIND = { food: "Food", cash: "Cash", health: "Health care", housing: "Housing", childcare: "Child care", energy: "Heat and energy", phone: "Phone", other: "Other" };
// common Wisconsin programs, offered as suggestions (any name may be typed)
const PROGRAMS = ["FoodShare (SNAP)", "BadgerCare Plus (Medicaid)", "Medicare Savings Program", "SSI", "SSDI", "Social Security retirement", "W-2 (Wisconsin Works)",
  "Wisconsin Shares (child care)", "WIC", "Housing Choice Voucher (Section 8)", "Public housing", "WHEAP (energy assistance)", "Lifeline (phone)",
  "Unemployment Insurance", "Veterans benefits", "Emergency Assistance"];
const daysTo = (/** @type {string} */ d, /** @type {string} */ today) => Math.round((new Date(d + "T12:00:00").getTime() - new Date(today + "T12:00:00").getTime()) / 864e5);

/** Benefits (topic Money): applications, renewal and appeal dates. @param {HTMLElement} el @param {string} id @param {string} org @param {string} name */
export async function benefitsBox(el, id, org, name) {
  /** @type {any} */ let B;
  try { B = await rpc("mirror_benefits", { p_individual: id, p_org: org }); }
  catch (e) { el.innerHTML = notice("info", `<p>${esc(name)} doesn't share Money with you, so their benefits aren't shown. They decide in their Settings.</p>`); return; }
  const warn = (/** @type {any} */ b) => {
    const out = [];
    if (b.renewal_on && ["active", "appealing"].includes(b.status)) {
      const d = daysTo(b.renewal_on, B.today);
      if (d < 0) out.push(tag(`Renewal date passed (${day(b.renewal_on)})`, "mm-tag-urgent"));
      else if (d <= 60) out.push(tag(`Renewal due in ${d} ${d === 1 ? "day" : "days"}`, d <= 14 ? "mm-tag-urgent" : ""));
    }
    if (b.appeal_by && ["denied", "appealing", "active"].includes(b.status)) {
      const d = daysTo(b.appeal_by, B.today);
      if (d >= 0 && d <= 30) out.push(tag(`Last day to appeal in ${d} ${d === 1 ? "day" : "days"}`, "mm-tag-urgent"));
    }
    return out.join(" ");
  };
  const dates = (/** @type {any} */ b) => [["applied_on", "Applied"], ["approved_on", "Approved"], ["renewal_on", "Renewal due"], ["appeal_by", "Appeal by"], ["ends_on", "Ends"]]
    .filter(([k]) => b[k]).map(([k, l]) => `${l} ${esc(day(b[k]))}`).join(" · ");
  const card = (/** @type {any} */ b) => `<li class="mm-card" style="list-style:none;margin-bottom:var(--mm-space-3)" data-ben="${esc(b.id)}">
    <p class="mm-muted mm-small" style="margin:0">${esc(BEN_KIND[b.kind] || b.kind)}${b.agency ? " · " + esc(b.agency) : ""} ${tag("Private, shared with you", "mm-tag-info")}</p>
    <strong>${esc(b.program)}</strong> <span class="mm-small">· ${esc(BEN[b.status] || b.status)}</span> ${warn(b)}
    ${dates(b) ? `<p class="mm-small" style="margin:var(--mm-space-1) 0">${dates(b)}</p>` : ""}
    ${b.note ? `<p class="mm-small" style="margin:var(--mm-space-1) 0">${esc(b.note)}</p>` : ""}
    <p class="mm-small mm-muted" style="margin:0">Last changed ${esc(day(b.updated_at))}${b.last_by ? " by " + esc(by(b.last_by)) : ""}.
      ${B.can_edit ? ` <button class="mm-btn mm-btn-quiet mm-small" type="button" data-change style="min-height:auto;padding:0">Change</button>` : ""}</p>
    <div data-more></div></li>`;
  const k = "b-" + id;
  const form = (/** @type {any} */ b) => `<form class="mm-card mm-read" novalidate style="margin-top:var(--mm-space-3)">
      ${b ? "" : `<h3 style="margin-top:0">Add a benefit or application for ${esc(name)}</h3>`}
      <div class="mm-field"><label for="${k}-p">Program</label><input class="mm-input" id="${k}-p" maxlength="120" list="${k}-list" value="${esc(b ? b.program : "")}"></div>
      <datalist id="${k}-list">${PROGRAMS.map((p) => `<option value="${esc(p)}"></option>`).join("")}</datalist>
      <div class="mm-row" style="gap:var(--mm-space-3)">
        <div class="mm-field"><label for="${k}-k">Kind</label><select class="mm-select" id="${k}-k">${Object.entries(BEN_KIND).map(([v, l]) => `<option value="${v}"${b && b.kind === v ? " selected" : ""}>${esc(l)}</option>`).join("")}</select></div>
        <div class="mm-field"><label for="${k}-s">Where it stands</label><select class="mm-select" id="${k}-s">${Object.entries(BEN).map(([v, l]) => `<option value="${v}"${(b ? b.status : "applied") === v ? " selected" : ""}>${esc(l)}</option>`).join("")}</select></div></div>
      <div class="mm-field"><label for="${k}-g">Agency <span class="mm-muted">(optional)</span></label><input class="mm-input" id="${k}-g" maxlength="120" value="${esc((b && b.agency) || "")}"></div>
      <div class="mm-row" style="gap:var(--mm-space-3)">
        ${[["applied_on", "Applied"], ["approved_on", "Approved"], ["renewal_on", "Renewal due"], ["appeal_by", "Appeal by"], ["ends_on", "Ends"]].map(([f, l]) => `<div class="mm-field">
          <label for="${k}-${f}">${l}</label><input class="mm-input" type="date" id="${k}-${f}" value="${esc((b && b[f]) || "")}" data-mm-no-voice></div>`).join("")}</div>
      <div class="mm-field"><label for="${k}-n">Note <span class="mm-muted">(optional; ${esc(name)} sees it)</span></label><input class="mm-input" id="${k}-n" maxlength="500" value="${esc((b && b.note) || "")}"></div>
      <p class="mm-hint">Appeal by: the last day to appeal a denial or a cut, from the agency's letter. ${esc(name)} sees these dates and warnings on their own benefits page.</p>
      <button class="mm-btn" type="submit">${b ? "Save" : "Add"}</button></form>`;
  el.innerHTML = `${B.benefits.length ? `<ul style="padding:0">${B.benefits.map(card).join("")}</ul>` : `<p class="mm-muted">No benefits or applications noted yet.</p>`}
    ${B.can_edit ? `<div data-new>${form(null)}</div>` : `<p class="mm-small mm-muted">They share Money with you as "see". To add or change, they choose "see and change" in Settings.</p>`}
    <p class="mm-small mm-muted">These are ${esc(name)}'s own records (their Daily Number's benefits page). Only ${esc(name)} removes one. Every change is in their record of what changed.</p>`;
  /** @param {HTMLFormElement} f @param {any} b */
  const wire = (f, b) => f.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const v = (/** @type {string} */ s) => /** @type {HTMLInputElement} */ (f.querySelector("#" + k + "-" + s)).value;
    const p = { program: v("p"), kind: v("k"), status: v("s"), agency: v("g"), applied_on: v("applied_on"), approved_on: v("approved_on"),
      renewal_on: v("renewal_on"), appeal_by: v("appeal_by"), ends_on: v("ends_on"), note: v("n") };
    // keep the person's own links to their Daily Number lines (the save writes every field)
    const keep = b ? { id: b.id, income_source_id: b.income_source_id || "", noncash_id: b.noncash_id || "", expense_id: b.expense_id || "" } : {};
    try { await rpc("mirror_dn_save", { p_kind: "benefit", p: { ...p, ...keep }, p_individual: id }); toast(b ? "Saved. They see the change." : "Added. They see it."); benefitsBox(el, id, org, name); }
    catch (err) { toast(msg(err)); }
  });
  const nf = /** @type {HTMLFormElement|null} */ (el.querySelector("[data-new] form"));
  if (nf) wire(nf, null);
  el.querySelectorAll("[data-ben]").forEach((li) => li.querySelector("[data-change]")?.addEventListener("click", () => {
    const b = B.benefits.find((/** @type {any} */ x) => x.id === /** @type {HTMLElement} */ (li).dataset.ben);
    const nw = el.querySelector("[data-new]"); if (nw) nw.innerHTML = "";
    const more = /** @type {HTMLElement} */ (li.querySelector("[data-more]"));
    more.innerHTML = form(b);
    wire(/** @type {HTMLFormElement} */ (more.querySelector("form")), b);
  }));
}

// ---------------------------------------------------------------- T8.7 donated goods given to the person (D-38)
/** What your organization gave them, and giving from your inventory. @param {HTMLElement} el @param {string} id @param {string} org @param {string} name */
export async function receivedBox(el, id, org, name) {
  /** @type {any} */ let R; /** @type {any[]} */ let stock = [];
  try { R = await rpc("mirror_received", { p_individual: id, p_org: org }); }
  catch (e) { el.innerHTML = notice("caution", `<p>${esc(msg(e))}</p>`); return; }
  if (R.can_give) { try { stock = ((await rpc("mirror_inventory", { p_org: org })).items || []).filter((/** @type {any} */ i) => i.active && i.quantity > 0); } catch { stock = []; } }
  const k = "g-" + id;
  el.innerHTML = `${R.received.length ? `<ul class="mm-small" style="padding-left:1.2rem">${R.received.map((/** @type {any} */ g) => `<li style="margin-bottom:var(--mm-space-2)" data-gift="${esc(g.id)}">
      ${esc(day(g.given_on))}: ${g.quantity} × ${esc(g.item)}${g.size ? " (" + esc(g.size) + ")" : ""}${g.note ? ": " + esc(g.note) : ""}
      ${g.returned ? " " + tag("Returned") + (g.returned_note ? " " + esc(g.returned_note) : "") : R.can_give ? ` <button class="mm-btn mm-btn-quiet mm-small" type="button" data-return style="min-height:auto;padding:0">Recorded by mistake</button>` : ""}</li>`).join("")}</ul>`
      : `<p class="mm-muted">Nothing given yet.</p>`}
    ${R.can_give ? (stock.length ? `<form class="mm-row" data-give novalidate style="align-items:flex-end;gap:var(--mm-space-3);margin-top:var(--mm-space-3)">
        <div class="mm-field" style="margin:0;min-width:16rem"><label for="${k}-i">Give from your donated goods</label><select class="mm-select" id="${k}-i">
          ${stock.map((/** @type {any} */ i) => `<option value="${esc(i.id)}">${esc(i.item)}${i.size ? ", " + esc(i.size) : ""} (${i.quantity} on hand)</option>`).join("")}</select></div>
        <div class="mm-field" style="margin:0;max-width:7rem"><label for="${k}-q">How many</label><input class="mm-input" id="${k}-q" inputmode="numeric" value="1" data-mm-no-voice></div>
        <div class="mm-field" style="margin:0;min-width:12rem"><label for="${k}-n">Note <span class="mm-muted">(${esc(name)} sees it)</span></label><input class="mm-input" id="${k}-n" maxlength="500"></div>
        <button class="mm-btn" type="submit">Give</button></form>`
      : `<p class="mm-small mm-muted">Nothing on hand to give. Add items on <a href="/mirror/workspace/inventory/?org=${encodeURIComponent(org)}">Donated goods</a>.</p>`)
      : `<p class="mm-small mm-muted">To give from your donated goods you need their "see and change" for everyday things.</p>`}
    <p class="mm-small mm-muted">${esc(name)} sees what they received on their My services page.</p>`;
  el.querySelector("[data-give]")?.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const v = (/** @type {string} */ s) => /** @type {HTMLInputElement} */ (el.querySelector("#" + k + "-" + s)).value;
    try { await rpc("mirror_inventory_give", { p: { item_id: v("i"), quantity: v("q"), individual_id: id, note: v("n") } }); toast("Recorded. They see it."); receivedBox(el, id, org, name); }
    catch (err) { toast(msg(err)); }
  });
  el.querySelectorAll("[data-gift]").forEach((li) => li.querySelector("[data-return]")?.addEventListener("click", async (ev) => {
    const b = /** @type {HTMLButtonElement} */ (ev.currentTarget);
    if (!b.dataset.sure) { b.dataset.sure = "1"; b.textContent = "Press again: put it back on the shelf"; return; }
    b.disabled = true;
    try { await rpc("mirror_inventory_return", { p_given: /** @type {HTMLElement} */ (li).dataset.gift, p_note: "Recorded by mistake" }); toast("Marked returned. The count is back."); receivedBox(el, id, org, name); }
    catch (err) { b.disabled = false; toast(msg(err)); }
  }));
}
