// @ts-check
// The Human Mirror Phase 11, T11.1 (migration 20261119701000): clothing, laundry and garment care, from the Clothes paper.
// The person's page is /mirror/my-mirror/clothing/; a coordinator uses the same box on /mirror/workspace/person/ with the person's id.
// What they have, per kind of clothing (only what they can reach), what needs fixing, how many they want (a suggested number follows
// how often they can do laundry; they choose), sizes (private unless they share them), storage, skills. Each gap becomes a suggested need.

import { requireArea, rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice, toast } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { voiceAll } from "/mirror/assets/mirror-voice.js?v=20261113c";

const SIZES = [["top", "Tops"], ["bottom", "Pants (for example waist and length)"], ["dress", "Dresses"], ["under", "Underwear"], ["bra", "Bra"], ["shoe", "Shoes"], ["coat", "Coat"]];
const STORAGE = [["closet", "A closet"], ["drawers", "Drawers or a dresser"], ["hangers", "Hangers"], ["separate", "A way to keep clean and dirty clothes apart"],
  ["seasonal", "Somewhere to keep clothes for other seasons"], ["safe", "Clothes are safe from damp, bugs and theft"]];
const SKILLS = [["sort", "Sort clothes and read care labels"], ["wash", "Use a washer"], ["dry", "Use a dryer or hang clothes to dry"], ["hand", "Wash by hand"],
  ["fold", "Fold and put away"], ["iron", "Iron or steam"], ["stains", "Get out stains"], ["mend", "Sew a button or fix a seam"], ["hem", "Hem pants"]];
const LAUNDRY_DAYS = { 7: "about every week", 14: "about every 2 weeks", 28: "about every 3 or 4 weeks", 35: "less often than once a month" };

/**
 * @param {HTMLElement} el
 * @param {string|null} [individual] null = the signed-in person's own Mirror
 */
export async function clothingBox(el, individual = null) {
  /** @type {any} */ let d;
  const mine = !individual;

  async function load(msg = "") {
    try { d = await rpc("mirror_clothing_get", { p_individual: individual }); }
    catch (e) { el.innerHTML = notice("caution", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); return; }
    draw(msg);
  }

  function draw(msg) {
    const dis = d.can_edit ? "" : " disabled";
    const P = d.profile;
    const has = (/** @type {string[]} */ list, /** @type {string} */ k) => (list || []).includes(k);
    const box = (/** @type {string} */ name, /** @type {string} */ k, /** @type {string} */ label, /** @type {boolean} */ on) =>
      `<label class="mm-choice"><input type="checkbox" name="${name}" value="${esc(k)}"${on ? " checked" : ""}${dis}> ${esc(label)}</label>`;
    const num = (/** @type {string} */ id, /** @type {any} */ v, /** @type {string} */ label) =>
      `<input class="mm-input" type="number" inputmode="numeric" min="0" max="999" id="${id}" value="${v == null ? "" : esc(String(v))}" aria-label="${esc(label)}" style="max-width:6rem"${dis} data-mm-no-voice>`;
    const sizesBlock = P.sizes === null
      ? `<p class="mm-muted">${mine ? "" : "They have not shared their sizes with your organization."}</p>
         ${!mine && !d.has_signin && d.can_edit ? `<label class="mm-choice"><input type="checkbox" id="clAgreed"> They agreed to share their sizes with us (they have no sign-in, so you record it)</label>
           <div class="mm-grid">${SIZES.map(([k, l]) => `<div class="mm-field"><label for="clS_${k}">${esc(l)}</label><input class="mm-input" id="clS_${k}" maxlength="40" data-mm-no-voice></div>`).join("")}</div>` : ""}`
      : `<div class="mm-grid">${SIZES.map(([k, l]) => `<div class="mm-field"><label for="clS_${k}">${esc(l)}</label><input class="mm-input" id="clS_${k}" maxlength="40" value="${esc((P.sizes || {})[k] || "")}"${dis} data-mm-no-voice></div>`).join("")}</div>
         ${mine ? `<label class="mm-choice"><input type="checkbox" id="clShare"${P.sizes_shared ? " checked" : ""}${dis}> Share my sizes with the organizations I work with, so they can find clothes that fit</label>` : ""}`;

    el.innerHTML = `${msg}
      ${!mine && d.matches.length ? `<section class="mm-card" style="margin-bottom:var(--mm-space-4)"><h2 style="margin-top:0">In your donated goods now</h2>
        <p class="mm-hint">Items your organization has that fit what they need${P.sizes === null ? " (sizes not shared, so only items without a size)" : ""}. Give them from <a href="/mirror/workspace/inventory/">Donated goods</a>.</p>
        <ul>${d.matches.map((/** @type {any} */ m) => `<li><strong>${esc(m.item)}</strong>${m.size ? ` (size ${esc(m.size)})` : ""}: ${esc(m.quantity)} on hand, ${esc(m.condition.replace("_", " "))}. For: ${esc(m.for_label)}</li>`).join("")}</ul></section>` : ""}
      <form id="clForm" novalidate>
      <section class="mm-card" style="margin-bottom:var(--mm-space-4)"><h2 style="margin-top:0">${mine ? "What I have and what I need" : "What they have and what they need"}</h2>
        <p class="mm-hint">Count only clothes ${mine ? "you" : "they"} can reach and wear (not clothes kept somewhere ${mine ? "you" : "they"} can't get to).
          ${mine ? "You" : "They"} can do laundry ${esc(LAUNDRY_DAYS[d.laundry_days] || "about every week")}${d.laundry && d.laundry.cl_laundry_often ? "" : " (a guess until the Self-care question about laundry is answered)"},
          so the suggested number is a starting point. ${mine ? "You choose" : "They choose"} how many ${mine ? "you" : "they"} want.</p>
        <div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Clothing by kind</caption>
          <thead><tr><th scope="col">Kind</th><th scope="col" class="mm-num">Can wear</th><th scope="col" class="mm-num">Need fixing</th><th scope="col" class="mm-num">Want</th><th scope="col">Suggested</th></tr></thead>
          <tbody>${d.items.map((/** @type {any} */ i) => `<tr>
            <th scope="row" data-label="Kind">${esc(i.label.charAt(0).toUpperCase() + i.label.slice(1))}</th>
            <td class="mm-num" data-label="Can wear">${num("clU_" + i.category, i.usable, i.label + ": can wear")}</td>
            <td class="mm-num" data-label="Need fixing">${num("clF_" + i.category, i.needs_fixing, i.label + ": need fixing")}</td>
            <td class="mm-num" data-label="Want">${num("clW_" + i.category, i.want, i.label + ": want")}</td>
            <td data-label="Suggested">${i.suggested == null ? '<span class="mm-muted mm-small">depends on your life</span>' : esc(String(i.suggested))}
              ${i.want != null && i.usable != null && i.want > i.usable ? ` <span class="mm-tag mm-tag-suggested">${i.want - i.usable} more</span>` : ""}</td></tr>`).join("")}</tbody></table></div>
        <p class="mm-small mm-muted">Each kind where ${mine ? "you want" : "they want"} more than ${mine ? "you" : "they"} can wear becomes a suggested need on the Needs page. It counts as met only when it fits and ${mine ? "you" : "they"} accepted it.</p>
      </section>
      <section class="mm-card" style="margin-bottom:var(--mm-space-4)"><h2 style="margin-top:0">Sizes</h2>
        <p class="mm-hint">Private. ${mine ? "Only you see your sizes, unless you choose to share them." : "Shown only when the person shares them."} Sizes differ by store, so write them the way that works best.</p>
        ${sizesBlock}
      </section>
      <section class="mm-card" style="margin-bottom:var(--mm-space-4)"><h2 style="margin-top:0">Keeping clothes</h2>
        <fieldset class="mm-choices"><legend class="mm-legend">${mine ? "What I have to keep clothes in" : "What they have to keep clothes in"}</legend>${STORAGE.map(([k, l]) => box("st", k, l, has(P.storage, k))).join("")}</fieldset>
        <fieldset class="mm-choices"><legend class="mm-legend">${mine ? "Things I can do" : "Things they can do"}</legend>${SKILLS.map(([k, l]) => box("sk", k, l, has(P.skills, k))).join("")}</fieldset>
        <fieldset class="mm-choices"><legend class="mm-legend">${mine ? "Things I'd like to learn" : "Things they'd like to learn"}</legend>${SKILLS.map(([k, l]) => box("lr", k, l, has(P.wants_learn, k))).join("")}</fieldset>
        <div class="mm-field"><label for="clNote">Anything else about clothes or laundry <span class="mm-muted mm-small">(optional)</span></label>
          <textarea class="mm-textarea" id="clNote" rows="3" maxlength="1000"${dis}>${esc(P.note || "")}</textarea></div>
      </section>
      <p class="mm-small mm-muted">Where to wash, how often, laundry cost and what gets in the way are in the ${mine ? '<a href="/mirror/my-mirror/life/self-care/">Self-care questions</a>' : "Self-care questions (under Their Mirror)"}.</p>
      <div id="clMsg" aria-live="assertive"></div>
      ${d.can_edit ? '<button class="mm-btn" type="submit">Save</button>' : ""}
      </form>`;

    const f = /** @type {HTMLFormElement} */ (el.querySelector("#clForm"));
    f.addEventListener("submit", async (e) => {
      e.preventDefault();
      const val = (/** @type {string} */ id) => { const x = /** @type {HTMLInputElement|null} */ (f.querySelector("#" + id)); return x ? x.value.trim() : ""; };
      const checked = (/** @type {string} */ n) => [...f.querySelectorAll(`input[name="${n}"]:checked`)].map((x) => /** @type {HTMLInputElement} */ (x).value);
      /** @type {Record<string, unknown>} */
      const p = { items: d.items.map((/** @type {any} */ i) => ({ category: i.category, usable: val("clU_" + i.category), needs_fixing: val("clF_" + i.category), want: val("clW_" + i.category) })),
        storage: checked("st"), skills: checked("sk"), wants_learn: checked("lr"), note: val("clNote") };
      if (f.querySelector("#clS_top")) p.sizes = Object.fromEntries(SIZES.map(([k]) => [k, val("clS_" + k)]));
      const share = /** @type {HTMLInputElement|null} */ (f.querySelector("#clShare"));
      if (share) p.sizes_shared = share.checked;
      const agreed = /** @type {HTMLInputElement|null} */ (f.querySelector("#clAgreed"));
      if (agreed) p.sizes_agreed = agreed.checked;
      try { d = await rpc("mirror_clothing_save", { p, p_individual: individual }); draw(notice("ok", "<p>Saved.</p>")); toast("Saved."); }
      catch (err) { /** @type {HTMLElement} */ (f.querySelector("#clMsg")).innerHTML = notice("urgent", `<p>${esc(err instanceof Error ? err.message : String(err))}</p>`); }
    });
    voiceAll(el);
  }

  await load();
}

/** /mirror/my-mirror/clothing/ */
export async function clothingPage() {
  await requireArea("my");
  clothingBox(/** @type {HTMLElement} */ (document.getElementById("mmBox")));
}
