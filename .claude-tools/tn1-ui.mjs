import fs from "node:fs";
const f = "site/assets/portal/nav-common.js";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (s.split(a).length !== 2) { console.log("MISS or not unique:", a.slice(0, 70)); process.exit(1); } s = s.replace(a, b); };
rep(`    \${r.consent_on ? consentHtml("", r) : '<div class="banner warn">No consent yet. Open <b>Edit details</b> and have the person type their name.</div>'}`,
`    \${r.consent_on ? consentHtml("", r) : '<div class="banner warn">No consent yet. Open <b>Edit details</b> and have the person type their name.</div>'}
    \${r.consent_on ? '<div class="nwhole"></div>' : ""}`);
rep(`    if (a === "note") run(b, () => rpc("nav_note", { p_id: r.id, p_text: box.querySelector("#noteText").value, p_private: !!box.querySelector("#notePrivate")?.checked }), "Note added.");
  });
}`,
`    if (a === "note") run(b, () => rpc("nav_note", { p_id: r.id, p_text: box.querySelector("#noteText").value, p_private: !!box.querySelector("#notePrivate")?.checked }), "Note added.");
  });
  const whole = box.querySelector(".nwhole");
  if (whole) wholeConsent(whole, r.id, ctx);
}

// ---------------------------------------------------------------- sharing beyond housing (Human Mirror TN.1, migration 20261119610000)
// After the housing consent, the person may choose which private parts of their life their Navigator may see in their Human Mirror.
// They read the exact words and type their own full name. The database keeps the words; withdrawing the housing consent ends this too.
const WHOLE_ACCESS = { none: "Not shared", view: "Can see", edit: "Can see and change" };
/** The same sentence the database keeps (nav_whole_words). */
function wholeWords(W, t) {
  const on = W.topics.filter((x) => t[x.key] === "view" || t[x.key] === "edit"), off = W.topics.filter((x) => !(t[x.key] === "view" || t[x.key] === "edit"));
  return "Beyond housing, I agree that " + W.receiver + " may work with me on my Human Mirror and see "
    + (on.length ? on.map((x) => x.mine + (t[x.key] === "edit" ? " (see and change)" : " (see)")).join(", ") : "none of my private topics")
    + ". Everything else private stays private: " + (off.length ? off.map((x) => x.mine).join(", ") : "nothing")
    + ". My name, my goals and my strengths are seen by an organization I work with. I can change or stop this at any time by telling my Navigator"
    + " or the office (info@2ndchinc.org), and stopping my housing consent stops this too.";
}
async function wholeConsent(el, id, ctx) {
  let W;
  try { W = await rpc("nav_whole_consent", { p_id: id }); } catch (e) { el.innerHTML = \`<div class="sub">\${esc(e.message)}</div>\`; return; }
  const c = W.current;
  const shared = c ? W.topics.filter((x) => ["view", "edit"].includes(c.topics[x.key])).map((x) => esc(x.label) + (c.topics[x.key] === "edit" ? " (see and change)" : " (see)")) : [];
  el.innerHTML = c
    ? \`<div class="banner \${c.withdrawn_on ? "" : "ok"}"><b>Sharing beyond housing</b> signed by <b>\${esc(c.signed_by)}</b> on \${fmtDate(String(c.signed_at).slice(0, 10))}\${c.withdrawn_on ? \` · <b>ended \${fmtDate(c.withdrawn_on)}</b>\` : ""}:
        \${shared.length ? shared.join(", ") : "no private topics"}.\${W.can_record ? ' <button class="linkbtn" data-w="open">Change</button>' : ""}
        <details><summary class="sub">The words they agreed to</summary><div class="sub">\${esc(c.words)}</div></details></div>\`
    : W.can_record ? \`<div class="banner"><b>Sharing beyond housing</b> (optional): the person can choose which private parts of their life you may see in their Human Mirror,
        such as health, money or documents. <button class="btn small" data-w="open">Record their choice</button></div>\` : "";
  el.querySelector('[data-w="open"]')?.addEventListener("click", () => {
    const cur = (c && !c.withdrawn_on && c.topics) || {};
    el.innerHTML = \`<div class="panel"><h3 class="nsec" style="margin-top:0">Sharing beyond housing</h3>
      <div class="sub">Hand the screen to the person. For each topic they choose; "Not shared" keeps it private. Housing information stays under their housing consent.</div>
      \${W.topics.map((x) => \`<label class="nf">\${esc(x.label)}<select class="field" data-topic="\${esc(x.key)}">\${Object.entries(WHOLE_ACCESS).map(([k, v]) => \`<option value="\${k}"\${(cur[x.key] || "none") === k ? " selected" : ""}>\${esc(v)}</option>\`).join("")}</select></label>\`).join("")}
      <div class="banner warn"><b>They agree to:</b><p style="margin:6px 0" data-w="words"></p>
        <label class="nf">Their full name, typed by them (\${esc(W.full_name)})<input class="field" data-w="name" autocomplete="off"></label></div>
      <div class="row"><button class="btn primary" data-w="save">Save their choice</button><button class="linkbtn" data-w="cancel">Cancel</button></div></div>\`;
    const pick = () => Object.fromEntries([...el.querySelectorAll("[data-topic]")].map((x) => [x.dataset.topic, x.value]));
    const show = () => { el.querySelector('[data-w="words"]').textContent = wholeWords(W, pick()); };
    el.querySelectorAll("[data-topic]").forEach((x) => x.addEventListener("change", show)); show();
    el.querySelector('[data-w="cancel"]').addEventListener("click", () => wholeConsent(el, id, ctx));
    el.querySelector('[data-w="save"]').addEventListener("click", async (e) => {
      const b = e.currentTarget; b.disabled = true; ctx.say("Saving ...");
      try { await rpc("nav_whole_consent_save", { p_id: id, p_topics: pick(), p_consent_name: el.querySelector('[data-w="name"]').value }); ctx.say("Saved: sharing beyond housing."); wholeConsent(el, id, ctx); }
      catch (err) { ctx.say(err.message, true); b.disabled = false; }
    });
  });
}`);
fs.writeFileSync(f, s);
for (const p of ["site/navigator/index.html", "site/navigator/unit/index.html", "site/staff/navigators/index.html"]) {
  let h = fs.readFileSync(p, "utf8"); const n = h.split("nav-common.js?v=20261112n").length - 1;
  h = h.replaceAll("nav-common.js?v=20261112n", "nav-common.js?v=20261113a"); fs.writeFileSync(p, h); console.log(p, n);
}
console.log("ok");
