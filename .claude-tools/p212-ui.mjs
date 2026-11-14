import fs from "node:fs";
const edit = (f, pairs) => { let s = fs.readFileSync(f, "utf8"); for (const [a, b] of pairs) { if (s.split(a).length !== 2) { console.log("MISS", f, a.slice(0, 70)); process.exit(1); } s = s.split(a).join(b); } fs.writeFileSync(f, s); console.log("ok", f); };
const DAY = `new Date(String(S[k].until) + "T12:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })`;
// Coordinator's "What they share": the end date; the record form takes an optional end date.
edit("site/mirror/workspace/person/index.html", [
  [`recorded by \${esc(S[k].by)}, \${esc(new Date(S[k].at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }))})</span>\``,
   `recorded by \${esc(S[k].by)}, \${esc(new Date(S[k].at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }))})</span>\${S[k].until ? \` <span class="mm-tag">until \${esc(${DAY})}</span>\` : ""}\``],
  [`      <input class="mm-input" id="rNote" maxlength="500" aria-describedby="rNoteHint"></div>
    <label class="mm-choice" style="margin-bottom:var(--mm-space-3)"><input type="checkbox" id="rConfirm">`,
   `      <input class="mm-input" id="rNote" maxlength="500" aria-describedby="rNoteHint"></div>
    <div class="mm-field"><label for="rUntil">Until <span class="mm-muted">(optional: the last day they agreed to share)</span></label>
      <input class="mm-input" id="rUntil" type="date" style="max-width:12rem"></div>
    <label class="mm-choice" style="margin-bottom:var(--mm-space-3)"><input type="checkbox" id="rConfirm">`],
  [`      rec = await rpc("mirror_consent_record", { p_individual: id, p_org: org, p_category: val("rTopic"), p_access: val("rAccess"), p_method: val("rHow"), p_note: val("rNote") });`,
   `      rec = await rpc("mirror_consent_record", { p_individual: id, p_org: org, p_category: val("rTopic"), p_access: val("rAccess"), p_method: val("rHow"), p_note: val("rNote") });
      // P2-12: an end date the person gave (only for a topic they share)
      if (val("rUntil") && val("rAccess") !== "none") rec = await rpc("mirror_consent_record_until", { p_individual: id, p_org: org, p_category: val("rTopic"), p_until: val("rUntil") });`],
]);
// Settings: under each shared topic, its end date and a way to set or clear it.
edit("site/mirror/my-mirror/settings/index.html", [
  [`          : \`\${hint ? \`<span class="mm-hint">\${esc(hint)}</span>\` : ""}\${sharingSelect(o, k)}\`}\${recordedNote(o, k)}</div>\`).join("")}`,
   `          : \`\${hint ? \`<span class="mm-hint">\${esc(hint)}</span>\` : ""}\${sharingSelect(o, k)}\`}\${recordedNote(o, k)}\${untilBox(o, k)}</div>\`).join("")}`],
  [`// Phase 2 fix 2: a choice a coordinator recorded for you`,
   `// P2-12 (migration 20261119690000): an end date for what you share. The day after it, the sharing stops by itself; a week before, an email
// reminds you (once Stephen turns that email on). You can change or clear it any time.
function untilBox(org, key) {
  if (!org.sharing[key]) return "";
  const u = org.sharing_until && org.sharing_until[key];
  const day = u ? new Date(u + "T12:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : "";
  return \`<div class="mm-row mm-small" style="gap:var(--mm-space-2);align-items:flex-end;margin-top:var(--mm-space-2)">
    <label>\${u ? "Shared until " + esc(day) + ". Change the last day" : "No end date. Last day to share (optional)"}
      <input class="mm-input" type="date" data-until-org="\${esc(org.id)}" data-until-topic="\${key}" value="\${esc(u || "")}" style="max-width:12rem"></label>
    <button class="mm-btn mm-btn-quiet" type="button" data-until-save>Save end date</button>
    \${u ? '<button class="mm-btn mm-btn-quiet" type="button" data-until-clear>No end date</button>' : ""}</div>\`;
}

// Phase 2 fix 2: a choice a coordinator recorded for you`],
  [`  box.querySelectorAll("[data-end]").forEach((b) => b.addEventListener("click", async () => {`,
   `  box.querySelectorAll("[data-until-save], [data-until-clear]").forEach((b) => b.addEventListener("click", async () => {
    const inp = /** @type {HTMLInputElement} */ (b.parentElement.querySelector("[data-until-org]"));
    const clear = b.hasAttribute("data-until-clear");
    if (!clear && !inp.value) { toast("Pick a date first."); return; }
    b.disabled = true;
    try { await rpc("mirror_my_consent_until", { p_org: inp.dataset.untilOrg, p_category: inp.dataset.untilTopic, p_until: clear ? null : inp.value });
      toast(clear ? "No end date." : "End date saved."); await load(); }
    catch (e) { b.disabled = false; toast(e.message); }
  }));
  box.querySelectorAll("[data-end]").forEach((b) => b.addEventListener("click", async () => {`],
]);
// Register page: keep the phone number on one line (lease-6f's accessibility pass).
edit("site/mirror/register/index.html", [[`<a href="tel:+12622365443">(262) 236-5443</a>`, `<a href="tel:+12622365443">(262)&nbsp;236&#8209;5443</a>`]]);
