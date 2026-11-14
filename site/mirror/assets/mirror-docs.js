// @ts-check
// The Human Mirror T7.4: "My documents" (the person) and a person's Documents page (workspace). One box for both.
// Files live in the private bucket mirror-docs. The browser never reaches it by itself: the edge function mirror-files asks the
// database gate as the signed-in person, then hands out a one-time upload link or a link that works for 5 minutes.
// Who may see, add or delete is decided in the database (migration 20261119414000); this file only shows it.
//   docsBox(el, individual|null, { name })    individual null = the signed-in person's own documents
import { client, rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice, toast } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { errorText } from "/assets/portal/portal.js";

const KINDS = { "application/pdf": "PDF", "image/jpeg": "photo", "image/png": "picture", "image/webp": "picture", "image/heic": "photo", "image/heif": "photo" };
const ACCEPT = Object.keys(KINDS).join(",") + ",.heic,.heif";
const msg = (/** @type {unknown} */ e) => (e instanceof Error ? e.message : String(e));
const day = (/** @type {string} */ d) => new Date(d.length === 10 ? d + "T12:00:00" : d).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
const size = (/** @type {number} */ n) => (n >= 1048576 ? (n / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(n / 1024)) + " KB");
const todayYMD = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };
const soonYMD = () => { const d = new Date(Date.now() + 60 * 86400000); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };
/** Phones often leave the type empty for HEIC photos. @param {File} f */
const mimeOf = (f) => f.type || (/\.heic$/i.test(f.name) ? "image/heic" : /\.heif$/i.test(f.name) ? "image/heif" : /\.pdf$/i.test(f.name) ? "application/pdf" : "");

/** @param {Record<string, unknown>} body */
async function files(body) {
  const { data, error } = await client.functions.invoke("mirror-files", { body });
  if (error) throw new Error(await errorText(error));
  return data;
}

/** @param {HTMLElement} el @param {string|null} individual @param {{ name?: string }} [opt] */
export function docsBox(el, individual, opt = {}) {
  const self = !individual;
  const who = self ? "you" : (opt.name || "they");
  /** @type {any} */ let data;

  async function load(note = "") {
    try { data = await rpc("mirror_documents", individual ? { p_individual: individual } : {}); }
    catch (e) {
      el.innerHTML = notice("caution", `<p>${esc(msg(e))}</p>${self ? "" : `<p class="mm-small">They choose who sees Documents in their Settings, or you record the choice they give you on their page.</p>`}`);
      return;
    }
    draw(note);
  }

  /** @param {any} d */
  function item(d) {
    const exp = d.expires_on ? (d.expires_on < todayYMD() ? ' <span class="mm-tag mm-tag-urgent">Expired</span>' : d.expires_on <= soonYMD() ? ' <span class="mm-tag mm-tag-suggested">Expires soon</span>' : "") : "";
    return `<li class="mm-card" style="margin-bottom:var(--mm-space-3);list-style:none" data-doc="${esc(d.id)}">
      <strong>${esc(d.title || d.type_label)}</strong>${exp}
      <span class="mm-muted mm-small" style="display:block">${esc(d.type_label)} · ${esc(KINDS[d.mime] || "file")}, ${esc(size(d.size_bytes))} · added ${esc(day(d.created_at))}${d.added_by_role === "self" ? (self ? " by you" : " by them") : d.added_by_org ? " by " + esc(d.added_by_org) : ""}</span>
      ${d.expires_on ? `<span class="mm-small" style="display:block">Expires ${esc(day(d.expires_on))}</span>` : ""}
      ${d.location_note ? `<span class="mm-small" style="display:block">Paper original: ${esc(d.location_note)}</span>` : ""}
      <p class="mm-row" style="gap:var(--mm-space-2);margin:var(--mm-space-3) 0 0">
        <button class="mm-btn mm-btn-secondary" type="button" data-open>Open</button>
        <button class="mm-btn mm-btn-quiet" type="button" data-save>Save a copy</button>
        ${d.can_edit ? '<button class="mm-btn mm-btn-quiet" type="button" data-edit>Change details</button>' : ""}
        ${d.can_delete ? '<button class="mm-btn mm-btn-quiet" type="button" data-del>Delete</button>' : ""}</p>
      <div data-more></div>
    </li>`;
  }

  /** @param {any} [d] */
  function fields(d) {
    const types = data.types.filter((/** @type {any} */ t) => t.can_add || (d && t.key === d.type));
    const pre = d ? d.id : "new";
    return `<div class="mm-field"><label for="ty-${pre}">What is it?</label><select class="mm-select" id="ty-${pre}" data-f="type">
        ${d ? "" : '<option value="">Choose…</option>'}${types.map((/** @type {any} */ t) => `<option value="${esc(t.key)}" data-exp="${t.has_expiry ? 1 : 0}"${d && d.type === t.key ? " selected" : ""}>${esc(t.label)}</option>`).join("")}</select></div>
      <div class="mm-field"><label for="ti-${pre}">Name <span class="mm-muted">(optional)</span></label>
        <input class="mm-input" id="ti-${pre}" data-f="title" maxlength="120" value="${esc(d ? d.title || "" : "")}" placeholder="For example: ID, front and back"></div>
      <div class="mm-field" data-expbox><label for="ex-${pre}">Expires <span class="mm-muted">(optional)</span></label>
        <input class="mm-input" id="ex-${pre}" data-f="expires" type="date" style="max-width:12rem" value="${esc(d ? d.expires_on || "" : "")}"></div>
      <div class="mm-field"><label for="lo-${pre}">Where is the paper original? <span class="mm-muted">(optional)</span></label>
        <input class="mm-input" id="lo-${pre}" data-f="where" maxlength="300" value="${esc(d ? d.location_note || "" : "")}" placeholder="For example: blue folder at my sister's"></div>`;
  }

  /** Shows the expiry box only for kinds that expire. @param {HTMLElement} f */
  function wireExpiry(f) {
    const sel = /** @type {HTMLSelectElement} */ (f.querySelector('[data-f="type"]'));
    const box = /** @type {HTMLElement} */ (f.querySelector("[data-expbox]"));
    const show = () => { const o = sel.selectedOptions[0]; box.hidden = !(o && o.dataset.exp === "1"); };
    sel.addEventListener("change", show); show();
  }

  function draw(note) {
    const canAdd = data.types.some((/** @type {any} */ t) => t.can_add);
    el.innerHTML = `${note}
      ${data.list.length ? `<ul style="padding:0">${data.list.map(item).join("")}</ul>` : `<p class="mm-muted">${self ? "No documents yet." : "No documents they share with you."}</p>`}
      ${canAdd ? `<form class="mm-card" data-add novalidate style="margin-top:var(--mm-space-4)">
        <h2 style="margin-top:0">Add a document</h2>
        <p class="mm-hint">A photo (JPG, PNG or a phone's HEIC) or a PDF, up to 10 MB. ${self ? "Only you see it unless you share Documents in Settings." : "They will see it on their own Documents page."}
          Never type ID or Social Security numbers here; the picture is enough.</p>
        <div class="mm-field"><label for="fi-new">File</label><input class="mm-input" id="fi-new" type="file" accept="${ACCEPT}" data-f="file"></div>
        ${fields()}
        <div data-err aria-live="assertive"></div>
        <button class="mm-btn" type="submit">Add it</button></form>` : self ? "" : `<p class="mm-small mm-muted">To add documents for ${esc(who)}, they share Documents with "see and change".</p>`}`;
    wire();
  }

  /** @param {HTMLElement} f */
  const val = (f, k) => /** @type {HTMLInputElement} */ (f.querySelector(`[data-f="${k}"]`)).value;

  function wire() {
    const add = /** @type {HTMLFormElement|null} */ (el.querySelector("[data-add]"));
    if (add) {
      wireExpiry(add);
      add.addEventListener("submit", async (e) => {
        e.preventDefault();
        const err = /** @type {HTMLElement} */ (add.querySelector("[data-err]"));
        const btn = /** @type {HTMLButtonElement} */ (add.querySelector('button[type="submit"]'));
        const file = /** @type {HTMLInputElement} */ (add.querySelector('[data-f="file"]')).files?.[0];
        err.innerHTML = "";
        if (!file) { err.innerHTML = notice("urgent", "<p>Choose the photo or PDF first.</p>"); return; }
        if (!val(add, "type")) { err.innerHTML = notice("urgent", "<p>Choose what kind of document it is.</p>"); return; }
        const mime = mimeOf(file);
        btn.disabled = true; btn.textContent = "Adding…";
        try {
          const u = await files({ action: "upload", individual, type: val(add, "type"), title: val(add, "title") || null, file_name: file.name,
            mime, size: file.size, expires_on: val(add, "expires") || null, location_note: val(add, "where") || null });
          const { error } = await client.storage.from("mirror-docs").uploadToSignedUrl(u.path, u.token, file, { contentType: mime });
          if (error) throw new Error("The file didn't arrive. Check your connection and try again.");
          toast("Added."); load();
        } catch (e2) { err.innerHTML = notice("urgent", `<p>${esc(msg(e2))}</p>`); btn.disabled = false; btn.textContent = "Add it"; }
      });
    }
    el.querySelectorAll("[data-doc]").forEach((li) => {
      const id = /** @type {HTMLElement} */ (li).dataset.doc || "";
      const d = data.list.find((/** @type {any} */ x) => x.id === id);
      const more = /** @type {HTMLElement} */ (li.querySelector("[data-more]"));
      /** @param {boolean} download */
      const open = async (download) => {
        const win = download ? null : window.open("", "_blank");   // opened now, while the click still counts, so it isn't blocked
        try {
          const r = await files({ action: "open", id, download });
          if (win) win.location.href = r.url; else location.href = r.url;
        } catch (e) { if (win) win.close(); toast(msg(e)); }
      };
      li.querySelector("[data-open]")?.addEventListener("click", () => open(false));
      li.querySelector("[data-save]")?.addEventListener("click", () => open(true));
      li.querySelector("[data-edit]")?.addEventListener("click", () => {
        more.innerHTML = `<form data-ed novalidate style="margin-top:var(--mm-space-3)">${fields(d)}<div data-err aria-live="assertive"></div>
          <p class="mm-row" style="gap:var(--mm-space-2)"><button class="mm-btn" type="submit">Save</button><button class="mm-btn mm-btn-quiet" type="button" data-x>Cancel</button></p></form>`;
        const f = /** @type {HTMLFormElement} */ (more.querySelector("[data-ed]"));
        wireExpiry(f);
        f.querySelector("[data-x]")?.addEventListener("click", () => { more.innerHTML = ""; });
        f.addEventListener("submit", async (e) => {
          e.preventDefault();
          try {
            await rpc("mirror_document_update", { p_id: id, p_type: val(f, "type"), p_title: val(f, "title") || null,
              p_expires_on: val(f, "expires") || null, p_location_note: val(f, "where") || null });
            toast("Saved."); load();
          } catch (e2) { /** @type {HTMLElement} */ (f.querySelector("[data-err]")).innerHTML = notice("urgent", `<p>${esc(msg(e2))}</p>`); }
        });
      });
      li.querySelector("[data-del]")?.addEventListener("click", () => {
        more.innerHTML = `<p class="mm-small" style="margin-top:var(--mm-space-3)">Delete "${esc(d.title || d.type_label)}"? The file is removed for good.
          <button class="mm-btn mm-btn-secondary" type="button" data-yes>Yes, delete it</button> <button class="mm-btn mm-btn-quiet" type="button" data-no>Keep it</button></p>`;
        more.querySelector("[data-no]")?.addEventListener("click", () => { more.innerHTML = ""; });
        more.querySelector("[data-yes]")?.addEventListener("click", async () => {
          try { await files({ action: "delete", id }); toast("Deleted."); load(); } catch (e) { toast(msg(e)); }
        });
      });
    });
  }

  load();
}
