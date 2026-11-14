// @ts-check
// The Human Mirror Phase 5 (T5.2): where I live now, the living options I want to learn about, what makes finding a home hard,
// what a home needs to have, and the places I have lived. The person's page is /mirror/my-mirror/living/; a helper uses the same
// box on /mirror/workspace/person/ with the person's id. Nothing here recommends a setting (prompt Part 5): the person chooses.

import { requireArea, rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice, toast } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { voiceAll } from "/mirror/assets/mirror-voice.js?v=20261113c";
import { OPTIONS, ARRANGEMENTS, BARRIERS, ACCESS_NEEDS, REVIEW_MEANS } from "/mirror/assets/living-options.js?v=20261113a";
import { downloadLiving } from "/mirror/assets/functional-page.js?v=20261113p";

const fmt = (/** @type {string} */ d) => new Date(d.length === 10 ? d + "T12:00:00" : d).toLocaleDateString("en-US", { month: "short", year: "numeric" });
const BY = { self: "you", coordinator: "a coordinator", org_admin: "an organization admin", volunteer: "a volunteer" };
const PRIVATE = [["", "No: anyone I share my answers with can see it"], ["health", "Yes: only with Physical health"], ["mental_health", "Yes: only with How I feel inside"],
  ["safety", "Yes: only with Safety"], ["legal", "Yes: only with ID, papers and legal matters"]];
const arrLabel = (/** @type {string} */ k) => (ARRANGEMENTS.find((a) => a.key === k) || { label: k }).label;

/**
 * @param {HTMLElement} el
 * @param {string|null} [individual] null = the signed-in person's own Mirror
 */
export async function housingBox(el, individual = null) {
  /** @type {any} */ let d;
  const mine = !individual;
  /** @type {string|null} */ let editing = null;   // history row id being changed, "new" for a new one

  async function load(msg = "") {
    try { d = await rpc("mirror_housing_get", { p_individual: individual }); }
    catch (e) { el.innerHTML = notice("caution", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); return; }
    draw(msg);
  }

  function draw(msg) {
    const p = d.profile || { preferred: [], barriers: { keys: [], note: null, hidden: 0 }, accessibility: { keys: [], note: null } };
    const sees = /** @type {string[]} */ (d.sees);
    const dis = d.can_edit ? "" : " disabled";
    const box = (/** @type {string} */ name, /** @type {string} */ key, /** @type {string} */ label, /** @type {boolean} */ on, /** @type {string} */ extra = "") =>
      `<label class="mm-choice"><input type="checkbox" name="${name}" value="${esc(key)}"${on ? " checked" : ""}${dis}> ${esc(label)}${extra}</label>`;
    const arrOptions = ARRANGEMENTS.filter((a) => sees.includes(a.category));
    const acc = p.accessibility && !p.accessibility.private ? p.accessibility : null;

    el.innerHTML = `${msg}
      ${p.professional_review_needed ? notice("caution", `<p><strong>Professional review needed</strong> <span class="mm-small">(marked ${esc(new Date(p.review_at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }))} by ${esc(BY[p.review_by] || p.review_by)})</span></p>
        ${p.review_note ? `<p>${esc(p.review_note)}</p>` : ""}<p class="mm-small">${esc(mine ? REVIEW_MEANS : "Shown to the person with this explanation: " + REVIEW_MEANS)}</p>`) : ""}
      <form id="hpForm" novalidate>
      <section class="mm-card" style="margin-bottom:var(--mm-space-4)"><h2 style="margin-top:0">Where ${mine ? "I live" : "they live"} now</h2>
        ${p.current_private ? `<p class="mm-muted">Private: ${mine ? "" : "the person has not shared this topic with your organization."}</p>`
          : `<div class="mm-field"><label for="hpCur">Where ${mine ? "are you" : "are they"} staying?</label><select class="mm-select" id="hpCur"${dis}><option value="">Choose…</option>
            ${arrOptions.map((a) => `<option value="${a.key}"${p.current_arrangement === a.key ? " selected" : ""}>${esc(a.label)}</option>`).join("")}</select></div>`}
        <div class="mm-field"><label for="hpCurNote">How is it going there? <span class="mm-muted mm-small">(optional)</span></label>
          <textarea class="mm-textarea" id="hpCurNote" rows="3" maxlength="2000"${dis}>${esc(p.current_note || "")}</textarea></div>
      </section>
      <section class="mm-card" style="margin-bottom:var(--mm-space-4)"><h2 style="margin-top:0">Living options ${mine ? "I'd like to learn about" : "they'd like to learn about"}</h2>
        <p class="mm-hint">Choose any. This does not sign ${mine ? "you" : "them"} up for anything, and nothing is chosen for ${mine ? "you" : "them"}.
          <a href="/mirror/living-options/" target="_blank" rel="noopener">Read about each option</a>.</p>
        ${OPTIONS.map((o) => box("pref", o.key, o.title, p.preferred.includes(o.key), ` <span class="mm-muted mm-small">${esc(o.summary)}</span>`)).join("")}
      </section>
      <section class="mm-card" style="margin-bottom:var(--mm-space-4)"><h2 style="margin-top:0">What makes finding a home hard</h2>
        ${BARRIERS.filter((b) => sees.includes(b.category)).map((b) => box("bar", b.key, b.label, p.barriers.keys.includes(b.key))).join("")}
        ${p.barriers.hidden ? `<p class="mm-small mm-muted">${esc(p.barriers.hidden)} more ${p.barriers.hidden === 1 ? "is" : "are"} private (a topic not shared with your organization) and stay${p.barriers.hidden === 1 ? "s" : ""} as ${p.barriers.hidden === 1 ? "it is" : "they are"}.</p>` : ""}
        <div class="mm-field"><label for="hpBarNote">Anything else about this <span class="mm-muted mm-small">(optional)</span></label>
          <input class="mm-input" id="hpBarNote" maxlength="2000" value="${esc(p.barriers.note || "")}"${dis}></div>
      </section>
      <section class="mm-card" style="margin-bottom:var(--mm-space-4)"><h2 style="margin-top:0">What a home needs to have</h2>
        ${acc ? `<p class="mm-hint">Private health information: seen only by organizations ${mine ? "you share" : "the person shares"} Physical health with.</p>
          ${ACCESS_NEEDS.map((a) => `<label class="mm-choice"><input type="checkbox" name="acc" value="${a.key}"${acc.keys.includes(a.key) ? " checked" : ""}${d.can_edit_health ? "" : " disabled"}> ${esc(a.label)}</label>`).join("")}
          <div class="mm-field"><label for="hpAccNote">Anything else a home needs <span class="mm-muted mm-small">(optional)</span></label>
            <input class="mm-input" id="hpAccNote" maxlength="2000" value="${esc(acc.note || "")}"${d.can_edit_health ? "" : " disabled"}></div>`
          : `<p class="mm-muted">Private: the person has not shared Physical health with your organization.</p>`}
      </section>
      <div id="hpMsg" aria-live="assertive"></div>
      ${d.can_edit ? `<p><button class="mm-btn" type="submit">Save</button></p>` : ""}
      </form>
      ${d.can_flag ? flagForm(p) : ""}
      <section style="margin-bottom:var(--mm-space-5)"><h2>Places ${mine ? "I have" : "they have"} lived</h2>
        <p class="mm-hint">One line per place, newest first. Dates are optional.</p>
        ${d.history.length ? `<ul class="mm-read">${d.history.map((/** @type {any} */ h) => `<li style="margin-bottom:var(--mm-space-2)"><strong>${esc(arrLabel(h.arrangement))}</strong>${h.city ? ", " + esc(h.city) : ""}
          <span class="mm-muted mm-small">${h.from_on ? esc(fmt(h.from_on)) : "?"} to ${h.to_on ? esc(fmt(h.to_on)) : "now"}${h.private ? " · private" : ""}</span>
          ${h.note ? `<br><span class="mm-small">${esc(h.note)}</span>` : ""}
          ${d.can_edit ? ` <button type="button" class="mm-btn mm-btn-quiet" data-edit="${esc(h.id)}">Change</button> <button type="button" class="mm-btn mm-btn-quiet" data-del="${esc(h.id)}">Remove</button>` : ""}</li>`).join("")}</ul>`
          : `<p class="mm-muted">None yet.</p>`}
        ${d.history_hidden ? `<p class="mm-small mm-muted">${esc(d.history_hidden)} more ${d.history_hidden === 1 ? "is" : "are"} private.</p>` : ""}
        ${d.can_edit ? (editing ? historyForm() : `<p><button type="button" class="mm-btn mm-btn-secondary" id="hhAdd">Add a place</button></p>`) : ""}
      </section>
      ${mine ? `<p><button type="button" class="mm-btn mm-btn-quiet" id="hpDownload">Download my abilities and living records</button></p>` : ""}`;
    wire();
  }

  function flagForm(/** @type {any} */ p) {
    const on = !!p.professional_review_needed;
    return `<form class="mm-card" id="hpFlag" style="margin-bottom:var(--mm-space-5)" novalidate><h2 style="margin-top:0">Professional review</h2>
      <p class="mm-hint">Mark this only when a trained professional could help the person look at their living choices. It is a note, not a decision,
        and never a recommendation of any setting. The person sees it with this explanation: ${esc(REVIEW_MEANS)}</p>
      <label class="mm-choice"><input type="checkbox" id="hpFlagOn"${on ? " checked" : ""}> Professional review needed</label>
      <div class="mm-field"><label for="hpFlagNote">Why (the person sees this)</label><input class="mm-input" id="hpFlagNote" maxlength="1000" value="${esc(on && p.review_note ? p.review_note : "")}"></div>
      <button class="mm-btn mm-btn-secondary" type="submit">Save the mark</button></form>`;
  }

  function historyForm() {
    const h = editing === "new" ? {} : d.history.find((/** @type {any} */ x) => x.id === editing) || {};
    const sees = /** @type {string[]} */ (d.sees);
    return `<form class="mm-card" id="hhForm" novalidate><h3 style="margin-top:0">${editing === "new" ? "Add a place" : "Change this place"}</h3>
      <div class="mm-field"><label for="hhArr">What kind of place</label><select class="mm-select" id="hhArr"><option value="">Choose…</option>
        ${ARRANGEMENTS.filter((a) => sees.includes(a.category)).map((a) => `<option value="${a.key}"${h.arrangement === a.key ? " selected" : ""}>${esc(a.label)}</option>`).join("")}</select></div>
      <div class="mm-row">
        <div class="mm-field"><label for="hhFrom">From <span class="mm-muted mm-small">(optional)</span></label><input class="mm-input" type="date" id="hhFrom" value="${esc(h.from_on || "")}"></div>
        <div class="mm-field"><label for="hhTo">To <span class="mm-muted mm-small">(empty = still there)</span></label><input class="mm-input" type="date" id="hhTo" value="${esc(h.to_on || "")}"></div></div>
      <div class="mm-field"><label for="hhCity">City or neighborhood <span class="mm-muted mm-small">(optional)</span></label><input class="mm-input" id="hhCity" maxlength="120" value="${esc(h.city || "")}"></div>
      <div class="mm-field"><label for="hhNote">Anything about it <span class="mm-muted mm-small">(optional)</span></label><textarea class="mm-textarea" id="hhNote" rows="3" maxlength="2000">${esc(h.note || "")}</textarea></div>
      <div class="mm-field"><label for="hhPriv">Keep this line private?</label><select class="mm-select" id="hhPriv">
        ${PRIVATE.filter(([k]) => !k || sees.includes(k)).map(([k, l]) => `<option value="${k}"${(h.private || "") === k ? " selected" : ""}>${esc(l)}</option>`).join("")}</select></div>
      <div id="hhMsg" aria-live="assertive"></div>
      <p class="mm-row"><button class="mm-btn" type="submit">Save</button> <button type="button" class="mm-btn mm-btn-quiet" id="hhCancel">Cancel</button></p></form>`;
  }

  function wire() {
    const $ = (/** @type {string} */ s) => /** @type {HTMLInputElement} */ (el.querySelector(s));
    const checked = (/** @type {string} */ n) => Array.from(el.querySelectorAll(`input[name="${n}"]:checked`)).map((c) => /** @type {HTMLInputElement} */ (c).value);
    el.querySelector("#hpForm")?.addEventListener("submit", async (e) => {
      e.preventDefault();
      /** @type {Record<string, unknown>} */
      const p = { current_note: $("#hpCurNote").value, preferred: checked("pref"), barriers: { keys: checked("bar"), note: $("#hpBarNote").value } };
      if ($("#hpCur")) p.current_arrangement = $("#hpCur").value;
      if ($("#hpAccNote") && d.can_edit_health) p.accessibility = { keys: checked("acc"), note: $("#hpAccNote").value };
      try { await rpc("mirror_housing_save", { p, p_individual: individual }); load(notice("ok", "<p>Saved.</p>")); }
      catch (err) { $("#hpMsg").innerHTML = notice("urgent", `<p>${esc(err instanceof Error ? err.message : String(err))}</p>`); }
    });
    el.querySelector("#hpFlag")?.addEventListener("submit", async (e) => {
      e.preventDefault();
      const on = $("#hpFlagOn").checked;
      try { await rpc("mirror_housing_review", { p_needed: on, p_note: $("#hpFlagNote").value, p_individual: individual });
        load(notice("ok", `<p>${on ? "Marked. The person sees the mark and what it means." : "Mark removed."}</p>`)); }
      catch (err) { toast(err instanceof Error ? err.message : String(err)); }
    });
    el.querySelector("#hhAdd")?.addEventListener("click", () => { editing = "new"; draw(""); $("#hhArr").focus(); });
    el.querySelectorAll("[data-edit]").forEach((b) => b.addEventListener("click", () => { editing = /** @type {HTMLElement} */ (b).dataset.edit || null; draw(""); $("#hhArr").focus(); }));
    el.querySelectorAll("[data-del]").forEach((b) => b.addEventListener("click", async () => {
      const btn = /** @type {HTMLButtonElement} */ (b);
      if (btn.dataset.sure !== "1") { btn.dataset.sure = "1"; btn.textContent = "Press again to remove"; return; }
      try { await rpc("mirror_housing_history_delete", { p_id: btn.dataset.del, p_individual: individual }); load(notice("ok", "<p>Removed.</p>")); }
      catch (err) { toast(err instanceof Error ? err.message : String(err)); }
    }));
    el.querySelector("#hhCancel")?.addEventListener("click", () => { editing = null; draw(""); });
    el.querySelector("#hhForm")?.addEventListener("submit", async (e) => {
      e.preventDefault();
      const p = { id: editing === "new" ? "" : editing, arrangement: $("#hhArr").value, from_on: $("#hhFrom").value, to_on: $("#hhTo").value,
        city: $("#hhCity").value, note: $("#hhNote").value, private: $("#hhPriv").value };
      try { await rpc("mirror_housing_history_save", { p, p_individual: individual }); editing = null; load(notice("ok", "<p>Saved.</p>")); }
      catch (err) { $("#hhMsg").innerHTML = notice("urgent", `<p>${esc(err instanceof Error ? err.message : String(err))}</p>`); }
    });
    el.querySelector("#hpDownload")?.addEventListener("click", downloadLiving);
    voiceAll(el);
  }

  await load();
}

/** /mirror/my-mirror/living/ */
export async function livingPage() {
  await requireArea("my");
  housingBox(/** @type {HTMLElement} */ (document.getElementById("mmBox")));
}
