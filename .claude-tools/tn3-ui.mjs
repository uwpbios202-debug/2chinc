import fs from "node:fs";
const f = "site/assets/portal/chpms.js";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (s.split(a).length !== 2) { console.log("MISS or not unique:", a.slice(0, 80)); process.exit(1); } s = s.replace(a, b); };
rep(`  let D = null, X = null, REFS = null;
  const F = { q: "", pop: "", help: "", ver: "", show: "" };`,
`  let D = null, X = null, REFS = null, L = null;   // L: life areas (Human Mirror TN.3, migration 20261119630000)
  const F = { q: "", pop: "", help: "", area: "", ver: "", show: "" };
  const areasOf = (pid) => (L && L.links[pid]) || [];
  const areaTitle = (k) => ((L && L.areas.find((a) => a.key === k)) || { title: k }).title;`);
rep(`    D = await rpc("chpms_directory");`,
`    D = await rpc("chpms_directory");
    try { L = await rpc("chpms_life_areas"); } catch (e) { L = null; }   // the directory still works without it`);
rep(`    if (F.help && !p.assist.includes(F.help)) return false;`,
`    if (F.help && !p.assist.includes(F.help)) return false;
    if (F.area && !areasOf(p.program_id).includes(F.area)) return false;`);
rep(`    if ((F.pop || F.help || F.show === "money") && !o.programs.some(progMatches)) return false;`,
`    if ((F.pop || F.help || F.area || F.show === "money") && !o.programs.some(progMatches)) return false;`);
rep(`        const ps = (F.pop || F.help || F.show === "money") ? o.programs.filter(progMatches) : o.programs;`,
`        const ps = (F.pop || F.help || F.area || F.show === "money") ? o.programs.filter(progMatches) : o.programs;`);
rep(`        \${select("pop", "Who", POPS, F.pop, "Anyone")}\${select("help", "Kind of help", HELP, F.help, "Any help")}`,
`        \${select("pop", "Who", POPS, F.pop, "Anyone")}\${select("help", "Kind of help", HELP, F.help, "Any help")}
        \${L ? select("area", "Life area", Object.fromEntries(L.areas.map((a) => [a.key, a.title])), F.area, "Any area of life") : ""}`);
rep(`copied: "Copied from the 11/11 directory (to audit)",`, `copied: "Copied from the 11/11 directory (to audit)", tn3: "Added 11/13 beyond housing (ID, health, food, phone, work, education)",`);
rep(`    if (F.show === "copied" && !(o.import_version === "aid-11/11" || o.programs.some((p) => p.import_version === "aid-11/11"))) return false;`,
`    if (F.show === "copied" && !(o.import_version === "aid-11/11" || o.programs.some((p) => p.import_version === "aid-11/11"))) return false;
    if (F.show === "tn3" && !(o.import_version === "tn3-11/13" || o.programs.some((p) => p.import_version === "tn3-11/13"))) return false;`);
rep(`      \${p.pops.length ? \`<div class="cx-small"><span class="cx-meta">Serves:</span> \${esc(p.pops.join(", "))}</div>\` : ""}
      <dl class="cx-dl">`,
`      \${p.pops.length ? \`<div class="cx-small"><span class="cx-meta">Serves:</span> \${esc(p.pops.join(", "))}</div>\` : ""}
      \${L ? \`<div class="cx-small"><span class="cx-meta">Life areas:</span> \${areasOf(p.program_id).length ? esc(areasOf(p.program_id).map(areaTitle).join("; ")) : "none yet"}
        \${L.can_tag ? \` <button class="linkbtn" data-areas="\${esc(p.program_id)}">Change life areas</button>\` : ""}</div>\` : ""}
      <dl class="cx-dl">`);
rep(`    body.querySelectorAll("[data-editprog]").forEach((b) => b.addEventListener("click", () => progEdit(o, o.programs.find((p) => p.program_id === b.dataset.editprog))));`,
`    body.querySelectorAll("[data-editprog]").forEach((b) => b.addEventListener("click", () => progEdit(o, o.programs.find((p) => p.program_id === b.dataset.editprog))));
    // TN.3: office staff tag a program with life areas; areas that come from its help types stay (they follow the help types).
    body.querySelectorAll("[data-areas]").forEach((b) => b.addEventListener("click", () => {
      const pid = b.dataset.areas, slot = body.querySelector(\`[data-slot="program:\${CSS.escape(pid)}"]\`), fixed = (L.by_rule[pid] || []), on = areasOf(pid);
      slot.innerHTML = \`<div class="panel"><b>Life areas</b><div class="cx-meta">Ticked areas show this program under Find help &gt; Life area and in the Human Mirror's "Help I could get".
          Greyed areas come from its kinds of help and change with them.</div>
        <div class="cx-checks">\${L.areas.map((a) => \`<label><input type="checkbox" name="area" value="\${esc(a.key)}" \${on.includes(a.key) ? "checked" : ""} \${fixed.includes(a.key) ? "disabled" : ""}>\${esc(a.title)}</label>\`).join("")}</div>
        <div class="row"><button class="btn small primary" data-areasave>Save life areas</button><button class="linkbtn" data-areano>Cancel</button></div></div>\`;
      slot.querySelector("[data-areano]").onclick = () => { slot.innerHTML = ""; };
      slot.querySelector("[data-areasave]").onclick = async () => {
        const keys = [...slot.querySelectorAll('input[name="area"]:checked:not(:disabled)')].map((x) => x.value);
        try { L = await rpc("chpms_program_areas_save", { p_program: pid, p_areas: keys }); say("Life areas saved."); orgView(o.org_id, pid); } catch (e) { fail(e); }
      };
    }));`);
fs.writeFileSync(f, s);
for (const p of ["site/navigator/index.html", "site/staff/resources/index.html"]) {
  let h = fs.readFileSync(p, "utf8"); const n = h.split("chpms.js?v=20261112c").length - 1;
  h = h.replaceAll("chpms.js?v=20261112c", "chpms.js?v=20261113a"); fs.writeFileSync(p, h); console.log(p, n);
}
console.log("ok");
