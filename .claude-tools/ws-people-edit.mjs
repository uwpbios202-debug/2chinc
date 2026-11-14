// T8.1 people list: search, status filter, counts per person (mirror_people_counts). Each replace must match exactly once.
import fs from "node:fs";
const f = "site/mirror/workspace/people/index.html";
let t = fs.readFileSync(f, "utf8");
const edits = [
  [`  try { people = await rpc("mirror_people", { p_org: org }); }
  catch (e) { box.innerHTML = notice("urgent", \`<p>\${esc(e.message)}</p>\`); return; }`,
   `  try { people = await rpc("mirror_people", { p_org: org }); }
  catch (e) { box.innerHTML = notice("urgent", \`<p>\${esc(e.message)}</p>\`); return; }
  // T8.1: counts beside each person (only what they share with this organization); the list still works without them
  let counts = {};
  try { counts = Object.fromEntries((await rpc("mirror_people_counts", { p_org: org })).map((c) => [c.id, c])); } catch { counts = {}; }
  const cnt = (p, k) => (counts[p.id] ? Number(counts[p.id][k]) || 0 : "");`],
  [`    \${people.length ? \`<div class="mm-table-wrap mm-stack"><table class="mm-table">`,
   `    \${people.length > 1 ? \`<div class="mm-row" style="gap:var(--mm-space-4);align-items:flex-end">
      <div class="mm-field" style="margin:0;min-width:16rem"><label for="mmFind">Find a person</label><input class="mm-input" id="mmFind" type="search" autocomplete="off" data-mm-no-voice></div>
      <div class="mm-field" style="margin:0"><label for="mmShow">Show</label><select class="mm-select" id="mmShow">
        <option value="open">Active and waiting</option><option value="active">Active only</option><option value="invited">Waiting to accept</option>
        <option value="urgent">With an urgent need</option><option value="ended">Ended</option><option value="all">Everyone</option></select></div>
      <p class="mm-small mm-muted" id="mmShown" aria-live="polite" style="margin:0"></p></div>\` : ""}
    \${people.length ? \`<div class="mm-table-wrap mm-stack"><table class="mm-table">`],
  [`<th scope="col">Coordinator</th><th scope="col">Email</th>`,
   `<th scope="col">Coordinator</th><th scope="col" class="mm-num">Open needs</th><th scope="col" class="mm-num">Steps to do</th><th scope="col" class="mm-num">Goals</th><th scope="col">Email</th>`],
  [`      <tbody>\${people.map((p) => \`<tr>`,
   `      <tbody>\${people.map((p) => \`<tr data-row data-status="\${esc(p.status)}" data-urgent="\${cnt(p, "needs_urgent") > 0 ? 1 : 0}" data-name="\${esc(((p.preferred_name || "") + " " + (p.legal_name || "") + " " + (p.email || "")).toLowerCase())}">`],
  [`        <td data-label="Coordinator">\${esc(p.coordinator || "")}</td>`,
   `        <td data-label="Coordinator">\${esc(p.coordinator || "")}</td>
        <td class="mm-num" data-label="Open needs">\${cnt(p, "needs_open")}\${cnt(p, "needs_urgent") ? \` <span class="mm-tag mm-tag-urgent">\${cnt(p, "needs_urgent")} urgent</span>\` : ""}</td>
        <td class="mm-num" data-label="Steps to do">\${cnt(p, "steps_open")}</td>
        <td class="mm-num" data-label="Goals">\${cnt(p, "goals_active")}</td>`],
  [`  voiceAll(box);
  box.querySelector("#mmOrg")`,
   `  voiceAll(box);
  const find = box.querySelector("#mmFind"), show = box.querySelector("#mmShow");
  const filter = () => {
    if (!find) return;
    const q = find.value.trim().toLowerCase(), s = show.value;
    let n = 0;
    box.querySelectorAll("tr[data-row]").forEach((tr) => {
      const st = tr.dataset.status;
      const okS = s === "all" || (s === "open" ? st !== "ended" : s === "urgent" ? tr.dataset.urgent === "1" : st === s);
      const on = okS && (!q || tr.dataset.name.includes(q));
      tr.hidden = !on; if (on) n++;
    });
    box.querySelector("#mmShown").textContent = n + (n === 1 ? " person shown" : " people shown");
  };
  find?.addEventListener("input", filter); show?.addEventListener("change", filter); filter();
  box.querySelector("#mmOrg")`],
  [`<p class="mm-lead">The people your organization works with. You see only your own organization's people.</p>`,
   `<p class="mm-lead">The people your organization works with. You see only your own organization's people. The counts include only what each person shares with you.</p>`],
];
for (const [a, b] of edits) {
  const k = t.split(a).length - 1;
  if (k !== 1) { console.log("FAIL (" + k + "): " + a.slice(0, 70)); process.exit(1); }
  t = t.replace(a, () => b);
}
fs.writeFileSync(f, t);
console.log("ok " + edits.length + " edits");
