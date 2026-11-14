import fs from 'node:fs';
const f = 'site/mirror/my-mirror/resources/index.html';
let s = fs.readFileSync(f, 'utf8');
const rep = (a, b) => { if (s.split(a).length !== 2) throw new Error('not once: ' + a.slice(0, 70)); s = s.replace(a, b); };
rep(`<!-- Phase 7 (T7.2): programs from the housing resource directory (CHPMS) suggested for the person's open needs. Every program is`,
`<!-- Phase 7 (T7.2, follow-up 11/13/2026: ranked best fit first with no limit, Top 1 / 3 / 5 / All; place and groups shared only by
     the person's choice): programs from the housing resource directory (CHPMS) suggested for the person's open needs. Every program is`);
rep(`const msg = (e) =>`, `const VIEWS = [["1", "Top 1"], ["3", "Top 3"], ["5", "Top 5"], ["all", "All"]];
/** How many matches to show per need: a per-browser convenience; works without storage. */
let view = "3";
try { const v = localStorage.getItem("mm-resources-view"); if (v && VIEWS.some(([k]) => k === v)) view = v; } catch { /* no storage */ }
const msg = (e) =>`);
rep(`function matchItem(p, needId) {
  return \`<li style="list-style:none;padding:var(--mm-space-3) 0;border-top:1px solid var(--mm-border)">
    <strong>\${esc(p.program_name)}</strong> <span class="mm-tag mm-tag-suggested">Suggested</span>`,
`function matchItem(p, needId) {
  const why = (p.why || []).map((w) => \`<li>\${esc(w.reason)}\${w.points ? \` <span class="mm-muted">(\${w.points > 0 ? "+" : ""}\${w.points})</span>\` : ""}</li>\`).join("");
  return \`<li style="list-style:none;padding:var(--mm-space-3) 0;border-top:1px solid var(--mm-border)">
    <span class="mm-muted mm-small">Best fit #\${esc(p.rank)}</span><br>
    <strong>\${esc(p.program_name)}</strong> <span class="mm-tag mm-tag-suggested">Suggested</span>
    \${why ? \`<details style="margin-top:var(--mm-space-2)"><summary class="mm-small">Why it is here</summary><ul class="mm-small" style="margin:var(--mm-space-2) 0 0">\${why}</ul></details>\` : ""}`);
rep(`      <p class="mm-hint">This only changes which programs are suggested. Nobody else sees it, not even organizations you work with.</p>`,
`      <p class="mm-hint">This changes which programs are suggested and their order. Unless you share it below, nobody else sees it.</p>`);
rep(`      \${fromHome.length ? \`<p class="mm-small mm-muted">From your household and birth year we also count: \${esc(fromHome.join(", "))}.</p>\` : ""}`,
`      \${fromHome.length ? \`<p class="mm-small mm-muted">From your household and birth year we also count: \${esc(fromHome.join(", "))}.</p>\` : ""}
      <label class="mm-choice"><input type="checkbox" name="sh"\${p.shared ? " checked" : ""}> Share where I live and these groups with organizations I work with</label>
      <span class="mm-hint">They see it, cannot change it, and their suggestions for you then use it. Some groups (disability, coming home from prison) are private; share only if you want to. You can take it back any time.</span>`);
rep(`    const groups = [...pf.querySelectorAll('input[name="gr"]:checked')].map((x) => /** @type {HTMLInputElement} */ (x).value);
    try { await rpc("mirror_resource_profile_save", { p_place: place, p_groups: groups }); toast("Saved."); load(); }`,
`    const groups = [...pf.querySelectorAll('input[name="gr"]:checked')].map((x) => /** @type {HTMLInputElement} */ (x).value);
    const shared = /** @type {HTMLInputElement} */ (pf.querySelector('input[name="sh"]')).checked;
    try { await rpc("mirror_resource_profile_save", { p_place: place, p_groups: groups, p_shared: shared }); toast("Saved."); load(); }`);
rep(`      <h2>Suggested for my needs</h2>
      \${withPrograms.length ? withPrograms.map((x) => \`<section class="mm-card" style="margin-bottom:var(--mm-space-4)" aria-label="\${esc(x.need_title)}">
          <h3 style="margin-top:0">\${esc(x.need_title)}\${x.private ? ' <span class="mm-tag mm-tag-info">Private</span>' : ""}</h3>
          <p class="mm-muted mm-small" style="margin:0">\${esc(x.dimension_title || "")}</p>
          <ul style="padding:0;margin:0">\${x.programs.map((p) => matchItem(p, x.need_id)).join("")}</ul></section>\`).join("")`,
`      <h2>Suggested for my needs</h2>
      \${withPrograms.length ? \`<p class="mm-hint">Best fit first, from what you have told your Mirror and how well the directory knows the program. It is still a suggestion, not a promise that you qualify.</p>
        <div class="mm-row" style="gap:var(--mm-space-2);margin-bottom:var(--mm-space-4)"><label for="mmView">Show for each need</label>
          <select class="mm-select" id="mmView" style="width:auto">\${VIEWS.map(([k, l]) => \`<option value="\${k}"\${k === view ? " selected" : ""}>\${l}</option>\`).join("")}</select></div>\` : ""}
      \${withPrograms.length ? withPrograms.map((x) => {
          const shown = view === "all" ? x.programs : x.programs.slice(0, Number(view));
          const more = x.programs.length - shown.length;
          return \`<section class="mm-card" style="margin-bottom:var(--mm-space-4)" aria-label="\${esc(x.need_title)}">
          <h3 style="margin-top:0">\${esc(x.need_title)}\${x.private ? ' <span class="mm-tag mm-tag-info">Private</span>' : ""}</h3>
          <p class="mm-muted mm-small" style="margin:0">\${esc(x.dimension_title || "")} · \${x.programs.length} program\${x.programs.length === 1 ? "" : "s"} in the directory</p>
          <ul style="padding:0;margin:0">\${shown.map((p) => matchItem(p, x.need_id)).join("")}</ul>
          \${more ? \`<p style="margin:var(--mm-space-3) 0 0"><button class="mm-btn mm-btn-quiet" type="button" data-all>Show all \${x.programs.length}</button></p>\` : ""}</section>\`;
        }).join("")`);
rep(`function wire() {`, `/** @param {string} v */
function setView(v) {
  view = v;
  try { localStorage.setItem("mm-resources-view", v); } catch { /* no storage */ }
  draw("");
}

function wire() {
  box.querySelector("#mmView")?.addEventListener("change", (e) => setView(/** @type {HTMLSelectElement} */ (e.currentTarget).value));
  box.querySelectorAll("[data-all]").forEach((b) => b.addEventListener("click", () => setView("all")));`);
fs.writeFileSync(f, s);
