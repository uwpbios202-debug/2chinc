// Makes the sequestered copy of site/mirror/admin/index.html with the "2nd Chance platform admins" section (finding E).
// Built from the CURRENT working file; re-run right before applying, in case another session changed the page meanwhile.
import fs from 'node:fs';
const add = (src, anchor, extra, label, before = false) => {
  if (src.split(anchor).length !== 2) throw new Error('anchor not unique/found: ' + label);
  return src.replace(anchor, before ? extra + anchor : anchor + extra);
};
let s = fs.readFileSync('site/mirror/admin/index.html', 'utf8');

s = add(s, `      <button class="mm-btn" type="submit">Add organization</button>
    </form>\` : ""}`, `
    \${data.platform_admin ? '<section class="mm-card mm-read" id="mmPlat" style="margin-top:var(--mm-space-4)"><p role="status">Loading platform admins…</p></section>' : ""}`, 'section');

s = add(s, `  if (body) members(body, data.orgs.find((o) => o.id === body.dataset.org));\n`,
  `  const plat = box.querySelector("#mmPlat");\n  if (plat) platform(plat);\n`, 'call');

s = add(s, `\nload();\n</script>`, `
// Phase 2 finding E (11/13/2026): who is a 2nd Chance platform admin is an explicit list (mirror.platform_admins).
// Platform admins see it; only the 2nd Chance main admin can change it. Every change is logged.
async function platform(el) {
  let P;
  try { P = await rpc("mirror_platform_admins"); }
  catch (e) { el.innerHTML = notice("caution", \`<p>\${esc(e.message)}</p>\`); return; }
  const day = (d) => new Date(d).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
  const on = P.admins.filter((a) => a.active), off = P.admins.filter((a) => !a.active);
  el.innerHTML = \`<h2 style="margin-top:0">2nd Chance platform admins</h2>
    <p>Platform admins can see and manage every organization and its members. Only the people on this list have that power.
      Being an admin of 2nd Chance Housing's own team does not give it, and leaving 2nd Chance ends it.</p>
    <ul>\${on.map((a) => \`<li style="margin-bottom:var(--mm-space-3)"><strong>\${esc(a.name)}</strong> (\${esc(a.email)})\${a.is_me ? ' <span class="mm-tag mm-tag-info">You</span>' : ""}
        \${a.member_active ? "" : ' <span class="mm-tag">Not an active 2nd Chance member, so no power now</span>'}
        <br><span class="mm-muted mm-small">Added by \${esc(a.added_by)}, \${esc(day(a.added_at))}</span>
        \${P.can_edit && !a.is_me ? \` <button class="mm-btn mm-btn-quiet" type="button" data-unplat="\${esc(a.email)}">Remove</button>\` : ""}</li>\`).join("")}</ul>
    \${off.length ? \`<details><summary>Removed (\${off.length})</summary><ul>\${off.map((a) => \`<li>\${esc(a.name)} (\${esc(a.email)})
        <span class="mm-muted mm-small">removed by \${esc(a.removed_by || "")}\${a.removed_at ? ", " + esc(day(a.removed_at)) : ""}</span></li>\`).join("")}</ul></details>\` : ""}
    \${P.can_edit ? \`<form id="mmPlatAdd" novalidate style="margin-top:var(--mm-space-4)">
      <h3 style="margin-top:0">Add a platform admin</h3>
      <p class="mm-hint">They must be an active member of 2nd Chance Housing first (add them in its member list above). Every change is recorded with your name.</p>
      <div class="mm-field"><label for="pEmail">Their email</label><input class="mm-input" type="email" id="pEmail" autocomplete="off"></div>
      <div id="pMsg" aria-live="assertive"></div>
      <button class="mm-btn" type="submit">Add platform admin</button>
    </form>\` : '<p class="mm-muted mm-small">Only the 2nd Chance main admin can change this list.</p>'}\`;
  el.querySelectorAll("[data-unplat]").forEach((b) => b.addEventListener("click", async () => {
    if (b.dataset.sure !== "1") { b.dataset.sure = "1"; b.textContent = "Press again to remove"; return; }   // a second press confirms
    b.disabled = true;
    try { await rpc("mirror_platform_admin_save", { p: { email: b.dataset.unplat, active: false } }); toast("Removed. It's in the audit log."); platform(el); }
    catch (e) { b.disabled = false; toast(e.message); }
  }));
  el.querySelector("#mmPlatAdd")?.addEventListener("submit", async (e) => {
    e.preventDefault();
    const email = el.querySelector("#pEmail").value.trim();
    try { await rpc("mirror_platform_admin_save", { p: { email, active: true } }); toast("Added. It's in the audit log."); platform(el); }
    catch (err) { el.querySelector("#pMsg").innerHTML = notice("urgent", \`<p>\${esc(err.message)}</p>\`); }
  });
}
`, 'function', true);

fs.mkdirSync('.claude-tools/sequestered-E/site/mirror/admin', { recursive: true });
fs.writeFileSync('.claude-tools/sequestered-E/site/mirror/admin/index.html', s);
console.log('ok');
