import fs from "node:fs";
const f = "site/assets/portal/nav-common.js";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (s.split(a).length !== 2) { console.log("MISS or not unique:", a.slice(0, 80)); process.exit(1); } s = s.replace(a, b); };
rep(`  const shared = c ? W.topics.filter((x) => ["view", "edit"].includes(c.topics[x.key])).map((x) => esc(x.label) + (c.topics[x.key] === "edit" ? " (see and change)" : " (see)")) : [];
  el.innerHTML = c`,
`  const shared = c ? W.topics.filter((x) => ["view", "edit"].includes(c.topics[x.key])).map((x) => esc(x.label) + (c.topics[x.key] === "edit" ? " (see and change)" : " (see)")) : [];
  el.innerHTML = mirrorBlock(W) + (W.own_signin
    ? \`<div class="banner"><b>Sharing beyond housing:</b> they have their own Human Mirror sign-in, so they choose what they share themselves, in their Mirror Settings.\${c ? \` Last signed here by \${esc(c.signed_by)} on \${fmtDate(String(c.signed_at).slice(0, 10))}.\` : ""}</div>\`
    : c`);
rep(`        such as health, money or documents. <button class="btn small" data-w="open">Record their choice</button></div>\` : "";`,
`        such as health, money or documents. <button class="btn small" data-w="open">Record their choice</button></div>\` : "");
  wireMirror(el, W, id, ctx);`);
rep(`async function wholeConsent(el, id, ctx) {`,
`// ---------------------------------------------------------------- their Human Mirror (TN.2, migration 20261119620000)
const MIRROR_STATUS = { invited: "invited: it opens to you once they sign in and accept", active: "active", ended: "ended (their housing consent was withdrawn)" };
function mirrorBlock(W) {
  const m = W.mirror;
  if (m) return \`<div class="banner ok"><b>Their Human Mirror:</b> \${esc(MIRROR_STATUS[m.status] || m.status || "")}.
      \${m.status === "active" ? \` <a class="btn small" href="https://2ndchinc.org/mirror/workspace/person/?id=\${encodeURIComponent(m.individual_id)}&org=\${encodeURIComponent(m.organization_id)}" target="_blank" rel="noopener">Open their Mirror</a>
      <div class="sub">The Mirror has its own sign-in at https://2ndchinc.org/mirror/sign-in/ with an authenticator app.</div>\` : ""}</div>\`;
  if (!W.can_start_mirror) return "";
  return \`<div class="banner"><b>Human Mirror</b> (optional): a private place for their whole life, not only housing: their needs, strengths, goals and plan.
      <button class="btn small" data-m="open">Start their Mirror</button><div class="mslot"></div></div>\`;
}
function wireMirror(el, W, id, ctx) {
  el.querySelector('[data-m="open"]')?.addEventListener("click", () => {
    const slot = el.querySelector(".mslot");
    slot.innerHTML = \`<div class="panel">
      \${W.has_email ? '<label class="chk"><input type="radio" name="mWay" value="email" checked> Invite them with their email: they sign in and fill it in themselves, and it opens to you once they accept</label>' : ""}
      <label class="chk"><input type="radio" name="mWay" value="none"\${W.has_email ? "" : " checked"}> Without email: you fill it in together with them</label>
      <label class="chk"><input type="checkbox" data-m="yes"> I asked them, and they said yes to starting a Human Mirror with me</label>
      <div class="sub">What they shared beyond housing goes with it. No email is sent.</div>
      <div class="row"><button class="btn primary" data-m="go">Start their Mirror</button><button class="linkbtn" data-m="no">Cancel</button></div></div>\`;
    slot.querySelector('[data-m="no"]').addEventListener("click", () => { slot.innerHTML = ""; });
    slot.querySelector('[data-m="go"]').addEventListener("click", async (e) => {
      const b = e.currentTarget; b.disabled = true; ctx.say("Saving ...");
      try {
        await rpc("nav_mirror_start", { p_id: id, p_with_email: (slot.querySelector('input[name="mWay"]:checked') || {}).value === "email", p_person_agreed: slot.querySelector('[data-m="yes"]').checked });
        ctx.say("Their Human Mirror is started."); wholeConsent(el, id, ctx);
      } catch (err) { ctx.say(err.message, true); b.disabled = false; }
    });
  });
}
async function wholeConsent(el, id, ctx) {`);
fs.writeFileSync(f, s);
for (const p of ["site/navigator/index.html", "site/navigator/unit/index.html", "site/staff/navigators/index.html"]) {
  let h = fs.readFileSync(p, "utf8"); const n = h.split("nav-common.js?v=20261113a").length - 1;
  h = h.replaceAll("nav-common.js?v=20261113a", "nav-common.js?v=20261113b"); fs.writeFileSync(p, h); console.log(p, n);
}
console.log("ok");
