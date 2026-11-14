import fs from "node:fs";
const f = "site/mirror/admin/index.html";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (!s.includes(a)) { console.log("MISS:", a.slice(0, 70)); process.exit(1); } s = s.replace(a, b); };
rep(`  try { list = await rpc("mirror_admin_members", { p_org: org.id }); }`,
`  /** @type {any[]} */ let auth = [];
  try { [list, auth] = await Promise.all([rpc("mirror_admin_members", { p_org: org.id }), rpc("mirror_admin_authenticators", { p_org: org.id })]); }`);
rep(`<th scope="col">Active</th><th scope="col"><span class="mm-sr">Save</span></th></tr></thead>`,
`<th scope="col">Active</th><th scope="col">Authenticator</th><th scope="col"><span class="mm-sr">Save</span></th></tr></thead>`);
rep(`        <td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-save="\${esc(m.id)}">Save</button></td>
      </tr>\`).join("")}</tbody></table></div>\``,
`        <td data-label="Authenticator">\${authCell(auth.find((a) => a.id === m.id), m)}</td>
        <td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-save="\${esc(m.id)}">Save</button></td>
      </tr>\`).join("")}</tbody></table></div><div id="mmReset"></div>\``);
rep(`  body.querySelector("#mmNewMember").addEventListener("submit", async (e) => {`,
`  // P2-11 (11/13/2026): reset a member's authenticator after confirming who they are. The database decides who may (migration 20261119600000).
  body.querySelectorAll("[data-reset]").forEach((b) => b.addEventListener("click", () => {
    const m = list.find((x) => x.id === b.dataset.reset), box = body.querySelector("#mmReset");
    box.innerHTML = \`<form class="mm-card mm-read" id="mmResetForm" novalidate style="margin-top:var(--mm-space-4)">
      <h3 style="margin-top:0">Reset the authenticator of \${esc(m.name)}</h3>
      <p>Their authenticator app is removed and they are signed out on every device. At their next sign-in at https://2ndchinc.org/mirror/sign-in/
        (emailed code) they set up a new authenticator app. No email is sent from here; tell them yourself.</p>
      <div class="mm-field"><label for="rsWhy">Why</label><span class="mm-hint" id="rsWhyHint">For example: lost their phone; new phone; deleted the app.</span>
        <input class="mm-input" id="rsWhy" maxlength="300" aria-describedby="rsWhyHint" autocomplete="off"></div>
      <label class="mm-choice"><input type="checkbox" id="rsSure"> I confirmed it is really \${esc(m.name)}, by phone or in person (not only by email).</label>
      <div id="rsMsg" aria-live="assertive"></div>
      <p class="mm-row" style="gap:var(--mm-space-2)"><button class="mm-btn" type="submit">Reset their authenticator</button>
        <button class="mm-btn mm-btn-quiet" type="button" id="rsNo">Cancel</button></p></form>\`;
    box.querySelector("#rsNo").addEventListener("click", () => { box.innerHTML = ""; });
    box.querySelector("#rsWhy").focus();
    box.querySelector("#mmResetForm").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        const r = await rpc("mirror_admin_authenticator_reset", { p_org: org.id, p_member: m.id, p_reason: box.querySelector("#rsWhy").value, p_confirmed: box.querySelector("#rsSure").checked });
        load(notice("ok", \`<p>The authenticator of <strong>\${esc(r.name)}</strong> was reset\${r.signed_out_devices ? " and they were signed out on " + r.signed_out_devices + (r.signed_out_devices === 1 ? " device" : " devices") : ""}.
          Tell them to sign in again at https://2ndchinc.org/mirror/sign-in/ and set up a new authenticator app. It is in your organization's audit log.</p>\`));
      } catch (err) { box.querySelector("#rsMsg").innerHTML = notice("urgent", \`<p>\${esc(err.message)}</p>\`); }
    });
  }));
  body.querySelector("#mmNewMember").addEventListener("submit", async (e) => {`);
rep(`// Phase 2 finding E (11/13/2026)`,
`/** The Authenticator cell: set up or not, the Reset button when this admin may, or why only 2nd Chance can. @param {any} a @param {any} m */
function authCell(a, m) {
  if (!a) return "";
  const last = a.last_reset_at ? \`<br><span class="mm-muted mm-small">Last reset \${esc(new Date(a.last_reset_at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }))}</span>\` : "";
  if (!a.has_authenticator) return \`<span class="mm-muted mm-small">Not set up yet (they set it up at their first sign-in)</span>\${last}\`;
  if (m.is_me) return \`Set up\${last}\`;
  if (a.refusal) return \`Set up<br><span class="mm-muted mm-small">\${esc(a.refusal)}</span>\${last}\`;
  return \`Set up <button class="mm-btn mm-btn-quiet" type="button" data-reset="\${esc(m.id)}">Reset</button>\${last}\`;
}

// Phase 2 finding E (11/13/2026)`);
fs.writeFileSync(f, s); console.log("ok");
