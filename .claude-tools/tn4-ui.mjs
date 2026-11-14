import fs from "node:fs";
const f = "site/assets/portal/nav-common.js";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (s.split(a).length !== 2) { console.log("MISS or not unique:", a.slice(0, 80)); process.exit(1); } s = s.replace(a, b); };
rep(`    \${r.consent_on ? '<div class="nwhole"></div>' : ""}`,
`    \${r.consent_on ? '<div class="nwhole"></div>' : ""}
    \${u && ["matched", "approved", "moved_in"].includes(s) ? '<div class="nown"></div>' : ""}`);
rep(`  const whole = box.querySelector(".nwhole");
  if (whole) wholeConsent(whole, r.id, ctx);`,
`  const whole = box.querySelector(".nwhole");
  if (whole) wholeConsent(whole, r.id, ctx);
  const own = box.querySelector(".nown");
  if (own) ownRoom(own, r.id, ctx);`);
rep(`// ---------------------------------------------------------------- their Human Mirror (TN.2, migration 20261119620000)`,
`// ---------------------------------------------------------------- a room the Navigator runs (TN.4, migration 20261119640000)
// A match to a home the person's own Navigator runs is marked, and the placement waits until the person confirms on screen,
// typing their full name, that they know it and chose it. The database enforces it; the office lists these matches.
async function ownRoom(el, id, ctx) {
  let O;
  try { O = await rpc("nav_own_room_state", { p_id: id }); } catch (e) { el.innerHTML = ""; return; }
  if (!O.own_room) { el.innerHTML = ""; return; }
  const c = O.confirmed;
  el.innerHTML = c
    ? \`<div class="banner ok"><b>A room you run:</b> \${esc(O.place)}. The person confirmed they know and chose it: <b>\${esc(c.name)}</b>, \${fmtDate(String(c.at).slice(0, 10))}.
        <details><summary class="sub">The words they agreed to</summary><div class="sub">\${esc(c.words)}</div></details></div>\`
    : \`<div class="banner warn"><b>A room you run:</b> \${esc(O.place)}. Before the placement is confirmed, hand the screen to the person.
        \${O.status === "matched" || O.status === "approved" ? \`<p style="margin:6px 0">\${esc(O.words)}</p>
        <label class="nf">Their full name, typed by them (\${esc(O.full_name)})<input class="field" data-o="name" autocomplete="off"></label>
        <div class="row"><button class="btn primary small" data-o="save">They confirm</button></div>\` : ""}</div>\`;
  el.querySelector('[data-o="save"]')?.addEventListener("click", async (e) => {
    const b = e.currentTarget; b.disabled = true; ctx.say("Saving ...");
    try { await rpc("nav_own_room_confirm", { p_id: id, p_consent_name: el.querySelector('[data-o="name"]').value }); ctx.say("Confirmed. You can now confirm the placement."); ownRoom(el, id, ctx); }
    catch (err) { ctx.say(err.message, true); b.disabled = false; }
  });
}

// ---------------------------------------------------------------- their Human Mirror (TN.2, migration 20261119620000)`);
fs.writeFileSync(f, s);
const st = "site/staff/navigators/index.html";
let h = fs.readFileSync(st, "utf8");
const a = `      <p class="sub">Pathways are for program reporting and outreach only, never a reason to turn someone away.</p></div>\`;
}`;
if (h.split(a).length !== 2) { console.log("MISS staff"); process.exit(1); }
h = h.replace(a, `      <p class="sub">Pathways are for program reporting and outreach only, never a reason to turn someone away.</p></div>
    <div class="panel" id="ownRooms"><h2 style="margin:0">Matches to rooms a Navigator runs</h2><p class="sub">Loading ...</p></div>\`;
  ownRoomList();
}

// TN.4 (migration 20261119640000): every file matched to, or housed in, a home its own Navigator runs, with the person's confirmation.
async function ownRoomList() {
  const el = pane("dashboard").querySelector("#ownRooms");
  let L;
  try { L = await rpc("nav_own_room_matches"); } catch (e) { el.querySelector(".sub").textContent = e.message; return; }
  el.innerHTML = \`<h2 style="margin:0">Matches to rooms a Navigator runs</h2>
    <p class="sub">The person must confirm on screen that they know their Navigator runs the home and chose it before the placement is confirmed.</p>
    \${L.length ? \`<ul>\${L.map((x) => \`<li><a href="#referrals/\${esc(x.id)}">\${esc(x.label)}</a>\${x.is_sample ? " (sample)" : ""}: \${esc(x.place || "")} · \${esc(x.navigator || "")} · \${esc(STATUS[x.status] || x.status)} ·
      \${x.confirmed ? \`confirmed by <b>\${esc(x.confirmed.name)}</b> \${fmtDate(String(x.confirmed.at).slice(0, 10))}\` : "<b>not confirmed yet</b>"}</li>\`).join("")}</ul>\` : '<p class="sub">None.</p>'}\`;
}`);
fs.writeFileSync(st, h);
for (const p of ["site/navigator/index.html", "site/navigator/unit/index.html", "site/staff/navigators/index.html"]) {
  let x = fs.readFileSync(p, "utf8"); const n = x.split("nav-common.js?v=20261113b").length - 1;
  x = x.replaceAll("nav-common.js?v=20261113b", "nav-common.js?v=20261113c"); fs.writeFileSync(p, x); console.log(p, n);
}
console.log("ok");
