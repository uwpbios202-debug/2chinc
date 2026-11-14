// @ts-check
// The Human Mirror Phase 5 (T5.1): everyday activities (ADL + IADL) with the person's own preference beside each, and the
// 11 other functional areas. Used by the person's pages (/mirror/my-mirror/abilities/activities/ and .../areas/) and, with an
// individual id, by a helper on /mirror/workspace/person/. Never a diagnosis, never a score (prompt Part 5, D-09).

import { requireArea, rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice, countBar, toast } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { runSet } from "/mirror/assets/assessment-engine.js?v=20261113p";
import { voiceAll } from "/mirror/assets/mirror-voice.js?v=20261113c";
import { ADL, IADL, LEVELS, PREFERENCES, NOT_A_DIAGNOSIS, labelOf } from "/mirror/assets/functional-data.js?v=20261113a";
import { REVIEW_MEANS } from "/mirror/assets/living-options.js?v=20261113a";

const fmt = (/** @type {string} */ d) => new Date(d).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
const BY = { self: "you", coordinator: "a coordinator", org_admin: "an organization admin", volunteer: "a volunteer" };

/** Plain words for one saved row. @param {any} row */
function rowText(row) {
  if (!row) return "not answered";
  const bits = [];
  if (row.level) bits.push(labelOf(LEVELS, row.level));
  if (row.preference) bits.push("would like: " + labelOf(PREFERENCES, row.preference).toLowerCase());
  if (row.note) bits.push("“" + row.note + "”");
  return bits.join(" · ");
}

/** The "professional review needed" mark: shown to everyone who can see the check-in; set only by a helper. @param {any} rv */
function reviewNotice(rv, mine) {
  if (!rv || !rv.needed) return "";
  return notice("caution", `<p><strong>Professional review needed</strong>${rv.at ? ` <span class="mm-small">(marked ${esc(fmt(rv.at))} by ${esc(BY[rv.by] || rv.by)})</span>` : ""}</p>
    ${rv.note ? `<p>${esc(rv.note)}</p>` : ""}<p class="mm-small">${esc(mine ? REVIEW_MEANS : "Shown to the person with this explanation: " + REVIEW_MEANS)}</p>`);
}

/**
 * Everyday activities for one person.
 * @param {HTMLElement} el
 * @param {string|null} [individual] null = the signed-in person's own Mirror
 */
export async function activitiesBox(el, individual = null) {
  /** @type {any} */ let d;
  const mine = !individual;
  async function load(msg = "") {
    try { d = await rpc("mirror_fa_get", { p_individual: individual }); }
    catch (e) { el.innerHTML = notice("caution", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); return; }
    draw(msg);
  }

  function draw(msg) {
    const open = d.open || null, last = d.last || null;
    const cur = open || { adl: {}, iadl: {} };
    const answered = Object.keys(cur.adl).length + Object.keys(cur.iadl).length;
    const total = ADL.length + IADL.length;
    const part = (/** @type {"adl"|"iadl"} */ key, /** @type {string} */ title, /** @type {any[]} */ list, /** @type {string} */ intro) => `
      <section style="margin-bottom:var(--mm-space-5)"><h2>${esc(title)}</h2><p class="mm-hint">${esc(intro)}</p>
      ${list.map((a) => {
        const row = cur[key][a.key] || null, before = last && last[key][a.key];
        const id = `${key}-${a.key}`;
        return `<fieldset class="mm-card" style="margin-bottom:var(--mm-space-3)" data-part="${key}" data-act="${esc(a.key)}">
          <legend class="mm-legend" style="font-weight:700">${esc(a.label)}</legend>${a.help ? `<span class="mm-hint">${esc(a.help)}</span>` : ""}
          <div class="mm-row">
            <div class="mm-field" style="min-width:15rem"><label for="${id}-l">How it goes now</label>
              <select class="mm-select" id="${id}-l" data-k="level"${d.can_edit ? "" : " disabled"}><option value="">Choose…</option>
              ${LEVELS.map((l) => `<option value="${l.key}"${row && row.level === l.key ? " selected" : ""}>${esc(l.label)}</option>`).join("")}</select></div>
            <div class="mm-field" style="min-width:15rem"><label for="${id}-p">What I would like</label>
              <select class="mm-select" id="${id}-p" data-k="preference"${d.can_edit ? "" : " disabled"}><option value="">Choose…</option>
              ${PREFERENCES.map((p) => `<option value="${p.key}"${row && row.preference === p.key ? " selected" : ""}>${esc(p.label)}</option>`).join("")}</select></div>
          </div>
          <div class="mm-field"><label for="${id}-n">Anything to add <span class="mm-muted mm-small">(optional)</span></label>
            <input class="mm-input" id="${id}-n" data-k="note" maxlength="1000" value="${esc(row ? row.note || "" : "")}"${d.can_edit ? "" : " disabled"}></div>
          ${before ? `<p class="mm-small mm-muted" style="margin:0">Last check-in (${esc(fmt(last.completed_at))}): ${esc(rowText(before))}</p>` : ""}
        </fieldset>`;
      }).join("")}</section>`;

    el.innerHTML = `${msg}
      ${notice("info", `<p>${esc(NOT_A_DIAGNOSIS)}</p><p class="mm-small">This is private health information. ${mine
        ? "Only you see it, unless you share Physical health with an organization in Settings."
        : "You see it because the person shared Physical health with your organization."}</p>`)}
      ${reviewNotice(d.review, mine)}
      ${countBar(answered, total, "activities answered in this check-in")}
      ${open ? `<p class="mm-small mm-muted">Check-in started ${esc(fmt(open.started_at))}${open.by !== "self" ? ` by ${esc(BY[open.by] || open.by)}` : ""}. Each answer saves by itself.</p>`
        : `<p class="mm-small mm-muted">${last ? "Your answers start a new check-in. The last one stays in the history below." : "Your first answer starts a check-in. Each answer saves by itself."}</p>`}
      ${part("adl", "Taking care of myself", ADL, "Everyday personal care.")}
      ${part("iadl", "Running my home and my day", IADL, "The everyday tasks of running a home.")}
      ${d.can_edit ? `<div class="mm-card" style="margin-bottom:var(--mm-space-5)"><h2 style="margin-top:0">Finish this check-in</h2>
        <p class="mm-hint">Finishing keeps today's answers as they are, with the date, so you can see later what changed. You can start a new check-in any time.</p>
        <button type="button" class="mm-btn" id="faFinish"${open && answered ? "" : " disabled"}>Finish and keep this check-in</button></div>` : ""}
      ${d.can_flag ? flagForm(d.review) : ""}
      ${history()}
      ${mine ? `<p><button type="button" class="mm-btn mm-btn-quiet" id="faDownload">Download my abilities and living records</button></p>` : ""}`;
    wire();
  }

  function flagForm(/** @type {any} */ rv) {
    const on = !!(rv && rv.needed);
    return `<form class="mm-card" id="faFlag" style="margin-bottom:var(--mm-space-5)" novalidate><h2 style="margin-top:0">Professional review</h2>
      <p class="mm-hint">Mark this only when a trained professional (for example a nurse, social worker or options counselor) could help the person look at their choices.
        It is a note, not a decision. The person sees it with this explanation: ${esc(REVIEW_MEANS)}</p>
      <label class="mm-choice"><input type="checkbox" id="faFlagOn"${on ? " checked" : ""}> Professional review needed</label>
      <div class="mm-field"><label for="faFlagNote">Why (the person sees this)</label><input class="mm-input" id="faFlagNote" maxlength="1000" value="${esc(on && rv.note ? rv.note : "")}"></div>
      <button class="mm-btn mm-btn-secondary" type="submit">Save the mark</button></form>`;
  }

  function history() {
    if (!d.history.length) return "";
    return `<details class="mm-card" style="margin-bottom:var(--mm-space-5)"><summary><strong>Earlier check-ins (${d.history.length})</strong></summary>
      ${d.history.map((/** @type {any} */ h) => `<h3>${esc(fmt(h.completed_at))} <span class="mm-small mm-muted">by ${esc(BY[h.by] || h.by)}${h.organization && h.by !== "self" ? ", " + esc(h.organization) : ""}</span></h3>
        <ul>${[...ADL.map((a) => ["adl", a]), ...IADL.map((a) => ["iadl", a])].filter(([k, a]) => h[k][a.key])
          .map(([k, a]) => `<li><strong>${esc(a.label)}:</strong> ${esc(rowText(h[k][a.key]))}</li>`).join("") || "<li>No activities answered.</li>"}</ul>`).join("")}
    </details>`;
  }

  function wire() {
    el.querySelectorAll("fieldset[data-part]").forEach((fs) => {
      const f = /** @type {HTMLFieldSetElement} */ (fs);
      const get = (/** @type {string} */ k) => /** @type {HTMLInputElement} */ (f.querySelector(`[data-k="${k}"]`)).value;
      const save = async () => {
        try {
          const s = await rpc("mirror_fa_save", { p_part: f.dataset.part, p_activity: f.dataset.act, p_level: get("level"), p_preference: get("preference"), p_note: get("note"), p_individual: individual });
          if (s) { if (!d.open) { d.open = s; return load(); } d.open = s; }
          toast("Saved.");
        } catch (e) { toast(e instanceof Error ? e.message : String(e)); }
      };
      f.querySelectorAll("select").forEach((s) => s.addEventListener("change", save));
      const note = f.querySelector('[data-k="note"]');
      if (note) note.addEventListener("change", save);
    });
    el.querySelector("#faFinish")?.addEventListener("click", async () => {
      try { await rpc("mirror_fa_finish", { p_individual: individual }); load(notice("ok", "<p>Kept, with today's date. It is in the history below.</p>")); }
      catch (e) { toast(e instanceof Error ? e.message : String(e)); }
    });
    el.querySelector("#faFlag")?.addEventListener("submit", async (e) => {
      e.preventDefault();
      const on = /** @type {HTMLInputElement} */ (el.querySelector("#faFlagOn")).checked;
      try { await rpc("mirror_fa_review", { p_needed: on, p_note: /** @type {HTMLInputElement} */ (el.querySelector("#faFlagNote")).value, p_individual: individual });
        load(notice("ok", `<p>${on ? "Marked. The person sees the mark and what it means." : "Mark removed."}</p>`)); }
      catch (err) { toast(err instanceof Error ? err.message : String(err)); }
    });
    el.querySelector("#faDownload")?.addEventListener("click", downloadLiving);
    voiceAll(el);
  }

  await load();
}

/** The person's own download of their Phase 5 records (JSON). */
export async function downloadLiving() {
  try {
    const data = await rpc("mirror_my_export_living");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([JSON.stringify({ exported_at: new Date().toISOString(), about: "Your abilities and living records from The Human Mirror. They are yours.", ...data }, null, 2)], { type: "application/json" }));
    a.download = "my-human-mirror-abilities-living-" + new Date().toISOString().slice(0, 10) + ".json";
    document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  } catch (e) { toast(e instanceof Error ? e.message : String(e)); }
}

/** /mirror/my-mirror/abilities/activities/ */
export async function activitiesPage() {
  await requireArea("my");
  activitiesBox(/** @type {HTMLElement} */ (document.getElementById("mmBox")));
}

/** The 11 functional areas as cards. @param {HTMLElement} el @param {string|null} individual @param {(key: string, title: string) => void} [onOpen] */
export async function areasList(el, individual = null, onOpen) {
  let sets;
  try { sets = await rpc("mirror_sets", { p_kind: "functional", p_individual: individual }); }
  catch (e) { el.innerHTML = notice("caution", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); return; }
  el.innerHTML = `<div class="mm-grid">${sets.map((/** @type {any} */ s) => onOpen
    ? `<button type="button" class="mm-card" data-set="${esc(s.key)}" style="text-align:left;font:inherit;cursor:pointer"><strong>${esc(s.title)}</strong>
        <p class="mm-small" style="margin:var(--mm-space-1) 0">${esc(s.intro || "")}</p>${countBar(s.answered, s.questions, "answered")}</button>`
    : `<a class="mm-card" href="?a=${esc(s.key.replace(/^functional_/, ""))}"><strong>${esc(s.title)}</strong>
        <p class="mm-small" style="margin:var(--mm-space-1) 0">${esc(s.intro || "")}</p>${countBar(s.answered, s.questions, "answered")}</a>`).join("")}</div>`;
  if (onOpen) el.querySelectorAll("[data-set]").forEach((b) => b.addEventListener("click", () =>
    onOpen(/** @type {HTMLElement} */ (b).dataset.set || "", /** @type {HTMLElement} */ (b.querySelector("strong")).textContent || "")));
}

/** /mirror/my-mirror/abilities/areas/ (list) and ?a=<area> (one area's questions). */
export async function areasPage() {
  await requireArea("my");
  const head = /** @type {HTMLElement} */ (document.getElementById("mmHead"));
  const box = /** @type {HTMLElement} */ (document.getElementById("mmBox"));
  const a = new URLSearchParams(location.search).get("a") || "";
  if (!a) { areasList(box); return; }
  let sets;
  try { sets = await rpc("mirror_sets", { p_kind: "functional" }); }
  catch (e) { box.innerHTML = notice("caution", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); return; }
  const i = sets.findIndex((/** @type {any} */ s) => s.key === "functional_" + a);
  if (i < 0) { box.innerHTML = notice("info", "<p>This area isn't available. <a href=\"./\">See all areas</a>.</p>"); return; }
  const s = sets[i], nxt = sets.slice(i + 1).concat(sets.slice(0, i)).find((/** @type {any} */ x) => x.answered === 0);
  head.innerHTML = `<p class="mm-eyebrow"><a href="/mirror/my-mirror/abilities/">What I can do</a> · <a href="./">More areas</a></p>
    <h1>${esc(s.title)}</h1><p class="mm-lead">${esc(s.intro || "")}</p>${notice("info", `<p class="mm-small">${esc(NOT_A_DIAGNOSIS)}</p>`)}`;
  document.title = s.title + " | The Human Mirror";
  runSet(box, s.key, { nextLink: nxt ? { href: "?a=" + nxt.key.replace(/^functional_/, ""), label: "Next: " + nxt.title } : { href: "./", label: "All areas" } });
}
