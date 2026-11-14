import fs from 'node:fs';
const f = 'site/mirror/my-mirror/resources/index.html';
let s = fs.readFileSync(f, 'utf8');
const rep = (a, b) => { if (s.split(a).length !== 2) throw new Error('not once: ' + a.slice(0, 70)); s = s.replace(a, b); };
rep(`/** @type {any} */ let data = null;`, `/** @type {any} */ let data = null;
/** @type {any} */ let refs = { organizations: [], referrals: [] };   // T7.3: organizations I work with, open referrals`);
rep(`  try { data = await rpc("mirror_resources"); }`, `  try { [data, refs] = await Promise.all([rpc("mirror_resources"), rpc("mirror_referrals")]); }`);
rep(`    <div data-more></div>`, `    \${askBox(s)}
    <div data-more></div>`);
rep(`function profileForm() {`, `/** T7.3: ask an organization I work with to refer me to this program. @param {any} s */
function askBox(s) {
  if (!data.self || !s.program_id || s.status === "declined") return "";
  const open = refs.referrals.find((x) => x.program_id === s.program_id && (x.status === "awaiting_consent" || x.status === "consented" || x.status === "referred"));
  if (open) return \`<p class="mm-small" style="margin:var(--mm-space-2) 0 0"><a href="/mirror/my-mirror/referrals/">Referral: \${open.status === "referred" ? "made" : open.status === "consented" ? "you agreed" : "waiting for your answer"}</a></p>\`;
  const orgs = refs.organizations || [];
  if (!orgs.length) return "";
  const helps = (s.program && s.program.help) || [];
  return \`<details style="margin-top:var(--mm-space-2)"><summary class="mm-small">Ask for a referral</summary>
    <form data-ask novalidate style="margin-top:var(--mm-space-2)">
      <div class="mm-field"><label for="ao-\${esc(s.id)}">Who should make the referral?</label>
        <select class="mm-select" id="ao-\${esc(s.id)}">\${orgs.map((o) => \`<option value="\${esc(o.id)}">\${esc(o.name)}</option>\`).join("")}</select></div>
      \${helps.length ? \`<fieldset class="mm-choices"><legend class="mm-legend">What help do you need from them? <span class="mm-muted mm-small">(optional)</span></legend>
        \${helps.map((h) => \`<label class="mm-choice"><input type="checkbox" name="ah" value="\${esc(h)}"> \${esc(h)}</label>\`).join("")}</fieldset>\` : ""}
      <div class="mm-field"><label for="an-\${esc(s.id)}">Anything the program should know <span class="mm-muted">(optional)</span></label>
        <textarea class="mm-textarea" id="an-\${esc(s.id)}" rows="2" maxlength="2000"></textarea></div>
      <p class="mm-hint">Next you will see exactly what would be shared and agree by typing your name. Nothing is shared before that.</p>
      <button class="mm-btn mm-btn-secondary" type="submit">Continue</button>
    </form></details>\`;
}

function profileForm() {`);
rep(`  box.querySelectorAll("[data-sug]").forEach((el) => {`, `  box.querySelectorAll("[data-ask]").forEach((fa) => fa.addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = /** @type {HTMLFormElement} */ (fa);
    const sid = /** @type {HTMLElement} */ (f.closest("[data-sug]")).dataset.sug || "";
    const orgSel = /** @type {HTMLSelectElement} */ (f.querySelector("select"));
    const help = [...f.querySelectorAll('input[name="ah"]:checked')].map((x) => /** @type {HTMLInputElement} */ (x).value);
    const note = /** @type {HTMLTextAreaElement} */ (f.querySelector("textarea")).value;
    try { await rpc("mirror_referral_propose", { p_suggestion: sid, p_org: orgSel.value, p_help: help, p_note: note || null }); location.href = "/mirror/my-mirror/referrals/"; }
    catch (err) { toast(msg(err)); }
  }));

  box.querySelectorAll("[data-sug]").forEach((el) => {`);
fs.writeFileSync(f, s);
const ST = 'site/mirror/my-mirror/settings/index.html';
let t = fs.readFileSync(ST, 'utf8');
const r2 = (a, b) => { if (t.split(a).length !== 2) throw new Error('settings not once: ' + a.slice(0, 70)); t = t.replace(a, b); };
r2(`      data.resources = await rpc("mirror_my_export_resources");           // T7.2: programs on my list, their history, where I live and my groups`,
`      data.resources = await rpc("mirror_my_export_resources");           // T7.2: programs on my list, their history, where I live and my groups
      data.referrals = await rpc("mirror_my_export_referrals");           // T7.3: referrals, what I agreed to share, history`);
r2(`    d.resources = await rpc("mirror_my_export_resources"); } catch (e) { toast(e.message); return; }`,
`    d.resources = await rpc("mirror_my_export_resources"); d.referrals = await rpc("mirror_my_export_referrals"); } catch (e) { toast(e.message); return; }
  const REF_STATUS = { awaiting_consent: "Waiting for my answer", consented: "I agreed", referred: "Referred", declined: "I said no", withdrawn: "I took it back" };`);
r2(`    \${d.conversations.length`, `    \${d.referrals.length ? \`<h2>My referrals</h2><ul>\${d.referrals.map((x) => \`<li>\${esc(x.to)}\${x.program ? " (" + esc(x.program) + ")" : ""}, through \${esc(x.through || "")}: \${esc(REF_STATUS[x.status] || x.status)}\${x.consent_words ? ". I agreed: " + esc(x.consent_words) : ""}</li>\`).join("")}</ul>\` : ""}
    \${d.conversations.length`);
fs.writeFileSync(ST, t);
const H = 'site/mirror/my-mirror/index.html';
let hm = fs.readFileSync(H, 'utf8');
const a3 = `  <p><a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/resources/">Help I could get</a></p>`;
if (hm.split(a3).length !== 2) throw new Error('home');
hm = hm.replace(a3, `  <p class="mm-row"><a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/resources/">Help I could get</a>
    <a class="mm-btn mm-btn-secondary" href="/mirror/my-mirror/referrals/">My referrals</a></p>`);
fs.writeFileSync(H, hm);
const P = 'site/mirror/workspace/person/index.html';
let pp = fs.readFileSync(P, 'utf8');
const a4 = `    <p><a class="mm-btn mm-btn-secondary" href="/mirror/workspace/conversation/?id=\${encodeURIComponent(id)}&org=\${encodeURIComponent(org)}">Conversation plan</a></p>`;
if (pp.split(a4).length !== 2) throw new Error('person');
pp = pp.replace(a4, `    <p class="mm-row"><a class="mm-btn mm-btn-secondary" href="/mirror/workspace/conversation/?id=\${encodeURIComponent(id)}&org=\${encodeURIComponent(org)}">Conversation plan</a>
      <a class="mm-btn mm-btn-secondary" href="/mirror/workspace/referrals/?id=\${encodeURIComponent(id)}&org=\${encodeURIComponent(org)}">Referrals</a></p>`);
fs.writeFileSync(P, pp);
