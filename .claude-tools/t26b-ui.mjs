import fs from "node:fs";
const edit = (f, pairs) => { let s = fs.readFileSync(f, "utf8"); for (const [a, b] of pairs) { if (s.split(a).length !== 2) { console.log("MISS", f, a.slice(0, 70)); process.exit(1); } s = s.replace(a, b); } fs.writeFileSync(f, s); console.log("ok", f); };
const SAID = `const SAID = { queued: "Invitation sent.", held: "Recorded. Invitation emails are not switched on yet: give them https://2ndchinc.org/mirror/register/ yourself.", skipped: "Not sent again: it was sent in the last 12 hours." };`;
edit("site/mirror/workspace/people/index.html", [
  [`          : \`<button class="mm-btn mm-btn-quiet" type="button" data-status="\${esc(p.id)}" data-to="ended" data-name="\${esc(p.preferred_name)}">End</button>\`}</td>`,
   `          : \`<button class="mm-btn mm-btn-quiet" type="button" data-status="\${esc(p.id)}" data-to="ended" data-name="\${esc(p.preferred_name)}">End</button>\`}\${p.status === "invited" && p.email ? \` <button class="mm-btn mm-btn-quiet" type="button" data-resend="\${esc(p.id)}">Send the invitation again</button>\` : ""}</td>`],
  [`  box.querySelector("#mmAdd").addEventListener("submit", async (e) => {`,
   `  // T2.6 (Phase 9, migration 20261119670000): the invitation email again, at most once per 12 hours; held while Stephen has it switched off.
  \${""}`.slice(0, 0) + `  ${SAID}
  box.querySelectorAll("[data-resend]").forEach((b) => b.addEventListener("click", async () => {
    b.disabled = true;
    try { const s = await rpc("mirror_invitation_resend", { p_org: org, p_individual: b.dataset.resend }); toast(SAID[s] || s); }
    catch (e) { b.disabled = false; toast(e.message); }
  }));
  box.querySelector("#mmAdd").addEventListener("submit", async (e) => {`],
]);
edit("site/mirror/admin/index.html", [
  [`        <td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-save="\${esc(m.id)}">Save</button></td>`,
   `        <td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-save="\${esc(m.id)}">Save</button>\${m.active && !m.is_me ? \` <button class="mm-btn mm-btn-quiet" type="button" data-reinvite="\${esc(m.id)}">Send the invitation again</button>\` : ""}</td>`],
  [`  body.querySelector("#mmNewMember").addEventListener("submit", async (e) => {`,
   `  // T2.6 (Phase 9): the member invitation email again (held while Stephen has it switched off).
  body.querySelectorAll("[data-reinvite]").forEach((b) => b.addEventListener("click", async () => {
    b.disabled = true;
    try { const s = await rpc("mirror_member_invite_resend", { p_member: b.dataset.reinvite });
      toast({ queued: "Invitation sent.", held: "Recorded. Invitation emails are not switched on yet: tell them to sign in at https://2ndchinc.org/mirror/sign-in/.", skipped: "Not sent again: it was sent in the last 12 hours." }[s] || s); }
    catch (e) { b.disabled = false; toast(e.message); }
  }));
  body.querySelector("#mmNewMember").addEventListener("submit", async (e) => {`],
]);
