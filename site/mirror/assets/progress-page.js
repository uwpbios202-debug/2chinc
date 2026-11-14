// @ts-check
// The Human Mirror T6.4: My progress (/mirror/my-mirror/progress/). Plain counts per area of life and per month, from
// mirror_progress. D-09: no score of a person anywhere. Every number is a count of things done or noted, labeled for what it is;
// no percent, no rank, no "readiness". An area the viewer may not see shows "Not shared", never a count.
// progressBox(el, individual) is also meant for the coordinator's one-person overview later (Phase 8, T8.2).
import { requireArea, rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice } from "/mirror/assets/mirror-ui.js?v=20261113h";

/** Columns of the area table: [key, heading]. */
const AREA_COLS = [
  ["needs_open", "Needs I'm working on"],
  ["needs_met", "Needs I got"],
  ["needs_verified", "Confirmed by someone"],
  ["goals_active", "Goals I'm working toward"],
  ["goals_reached", "Goals reached"],
  ["steps_done", "Steps done"],
  ["steps_open", "Steps to do"],
  ["milestones", "Milestones"],
  ["strengths", "Strengths"],
];
/** Columns of the month table. */
const MONTH_COLS = [
  ["needs_noted", "Needs noted"],
  ["needs_met", "Needs got"],
  ["needs_verified", "Confirmed by someone"],
  ["steps_done", "Steps done"],
  ["goals_reached", "Goals reached"],
  ["milestones", "Milestones"],
];
const n = (/** @type {any} */ v) => Number(v) || 0;
const monthName = (/** @type {string} */ ym) => new Date(ym + "-15T12:00:00").toLocaleDateString("en-US", { month: "long", year: "numeric" });
const msg = (/** @type {unknown} */ e) => (e instanceof Error ? e.message : String(e));

export async function progressPage() {
  await requireArea("my");
  await progressBox(/** @type {HTMLElement} */ (document.getElementById("mmBox")));
}

/** @param {HTMLElement} el @param {string|null} [individual] */
export async function progressBox(el, individual = null) {
  /** @type {any} */ let P;
  try { P = await rpc("mirror_progress", individual ? { p_individual: individual } : {}); }
  catch (e) { el.innerHTML = notice("urgent", `<p>${esc(msg(e))}</p>`); return; }
  const you = P.self ? "you" : "they";
  const shared = P.areas.filter((/** @type {any} */ a) => a.shared);
  const busy = shared.filter((/** @type {any} */ a) => AREA_COLS.some(([k]) => n(a[k]) > 0));
  const quiet = shared.filter((/** @type {any} */ a) => !busy.includes(a));
  const hidden = P.areas.filter((/** @type {any} */ a) => !a.shared);
  const na = P.no_area || {};
  const naAny = ["steps_done", "steps_open", "milestones", "strengths"].some((k) => n(na[k]) > 0);
  const months = [...P.history].reverse();   // newest first
  const year = Object.fromEntries(MONTH_COLS.map(([k]) => [k, P.history.reduce((s, /** @type {any} */ m) => s + n(m[k]), 0)]));
  const yearAny = MONTH_COLS.some(([k]) => year[k] > 0);
  const cell = (/** @type {string} */ k, /** @type {string} */ h, /** @type {any} */ v) => `<td class="mm-num" data-label="${esc(h)}">${v == null ? "" : n(v)}</td>`;

  const areaTable = busy.length || naAny ? `
    <div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Counts for each area of life</caption>
      <thead><tr><th scope="col">Area of life</th>${AREA_COLS.map(([, h]) => `<th scope="col" class="mm-num">${esc(h)}</th>`).join("")}</tr></thead>
      <tbody>
        ${busy.map((/** @type {any} */ a) => `<tr><td data-label="Area of life"><strong>${esc(a.title)}</strong>${a.private ? ' <span class="mm-tag">private</span>' : ""}</td>
          ${AREA_COLS.map(([k, h]) => cell(k, h, a[k])).join("")}</tr>`).join("")}
        ${naAny ? `<tr><td data-label="Area of life"><strong>Not tied to one area</strong></td>
          ${AREA_COLS.map(([k, h]) => cell(k, h, k in na ? na[k] : null)).join("")}</tr>` : ""}
      </tbody></table></div>` : notice("info", `<p>Nothing to count yet. As ${you} add needs, goals, steps, milestones and strengths, they show up here.</p>`);

  const monthTable = yearAny ? `
    <div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Counts for each of the last 12 months</caption>
      <thead><tr><th scope="col">Month</th>${MONTH_COLS.map(([, h]) => `<th scope="col" class="mm-num">${esc(h)}</th>`).join("")}</tr></thead>
      <tbody>${months.map((/** @type {any} */ m) => `<tr><td data-label="Month">${esc(monthName(m.month))}</td>${MONTH_COLS.map(([k, h]) => cell(k, h, m[k])).join("")}</tr>`).join("")}</tbody>
      <tfoot><tr><td data-label="Month">All 12 months</td>${MONTH_COLS.map(([k, h]) => cell(k, h, year[k])).join("")}</tr></tfoot>
    </table></div>` : `<p class="mm-muted">Nothing done or noted in the last 12 months yet.</p>`;

  el.innerHTML = `
    <div class="mm-read">
      ${notice("info", `<p><strong>These are counts, not a score.</strong> Nothing here rates ${P.self ? "you" : "the person"} or compares ${P.self ? "you" : "them"} with anyone.
        Every step counts, and nothing is ever late.</p>`)}
    </div>
    <h2>By area of life</h2>
    ${areaTable}
    ${quiet.length ? `<p class="mm-small mm-muted">Nothing here yet: ${quiet.map((/** @type {any} */ a) => esc(a.title)).join("; ")}.</p>` : ""}
    ${hidden.length ? `<p class="mm-small">Not shared with you: ${hidden.map((/** @type {any} */ a) => esc(a.title)).join("; ")}. The person decides what to share.</p>` : ""}
    <h2>Over time</h2>
    <p class="mm-read">What was done or noted each month, newest first. A step that was opened again no longer counts as done.</p>
    ${monthTable}
    ${P.self ? `<p class="mm-small mm-read">Organizations you work with see these counts only for the parts of life you share with them
      (<a href="/mirror/my-mirror/settings/">Settings</a>). Private parts of life stay out of their counts.</p>` : ""}
    ${P.self ? `<p class="mm-small mm-row" style="gap:var(--mm-space-3)"><a href="/mirror/my-mirror/my-needs/">My needs</a>
      <a href="/mirror/my-mirror/plan/">My plan</a><a href="/mirror/my-mirror/actions/">My steps</a>
      <a href="/mirror/my-mirror/milestones/">My milestones</a><a href="/mirror/my-mirror/my-strengths/">My strengths</a></p>` : ""}`;
}
