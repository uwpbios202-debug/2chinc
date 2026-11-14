// One-off edit: replaces history() in daily-number-page.js with the full "what changed" and an accessible line chart (Phase 4 step 2).
import fs from "node:fs";
const f = "site/mirror/assets/daily-number-page.js";
let s = fs.readFileSync(f, "utf8");
const a = s.indexOf("async function history(body) {");
if (a < 0) throw new Error("history not found");
s = s.slice(0, a) + `async function history(body) {
  body.innerHTML = \`<div class="mm-read"><h1>How my Daily Number has changed</h1><p class="mm-lead">Each save keeps the date, the numbers and what they were made of.
    The Mirror also saves on its own: the first time you change something on a new day, it first keeps your numbers as they were. Moving, a new job, a car, or health coverage can all change them.</p></div>
    <div id="hist"><p role="status">Loading…</p></div>\`;
  let H;
  try { H = await rpc("mirror_dn_history", {}); } catch (e) { errBox(body.querySelector("#hist"), e); return; }
  const el = /** @type {HTMLElement} */ (body.querySelector("#hist"));
  if (!H.length) { el.innerHTML = notice("info", \`<p>Nothing saved yet. Press "Save today's numbers" on <a href="\${BASE}">My Daily Number</a>.</p>\`); return; }
  const L = (s) => s.results.levels || {};
  const day = (s, k) => (L(s)[k] && L(s)[k].cost ? L(s)[k].cost.daily : 0);
  el.innerHTML = (H.length >= 2 ? chart([...H].reverse()) : "") + H.map((snap, i) => {
    const older = H[i + 1];
    const diff = older ? changes(snap, older) : [];
    const gap = L(snap).current && L(snap).current.shortfall ? L(snap).current.shortfall.daily : 0;
    return \`<div class="mm-card" style="margin-bottom:var(--mm-space-4)">
      <h2 style="margin-top:0;font-size:1.2rem">\${esc(new Date(snap.taken_at).toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }))}\${snap.note ? \` · \${esc(snap.note)}\` : ""}</h2>
      <p>Today \${money(day(snap, "current"))} a day · Survival \${money(day(snap, "survival"))} · Stability \${money(day(snap, "stability"))} · The life I want \${money(day(snap, "aspirational"))} · Daily gap \${money(gap)}</p>
      \${older ? (diff.length ? \`<p class="mm-small"><strong>What changed since \${esc(new Date(older.taken_at).toLocaleDateString("en-US", { month: "short", day: "numeric" }))}:</strong></p><ul class="mm-small">\${diff.map((d) => \`<li>\${esc(d)}</li>\`).join("")}</ul>\` : '<p class="mm-muted mm-small">No changes from the save before.</p>') : '<p class="mm-muted mm-small">First save.</p>'}
    </div>\`;
  }).join("");
  wireChart(el);
}

/** Everything that differs between two saves: costs, income, help that isn't cash, goals, tax rate. */
function changes(newer, older) {
  const out = [];
  const lists = [["expenses", "cost", (x) => \`\${x.label} (\${(LEVEL[x.level] || { short: x.level }).short})\`, (x) => [x.level, x.category, String(x.label).toLowerCase()].join("|")],
    ["income", "income", (x) => x.label, (x) => ["i", x.kind, String(x.label).toLowerCase()].join("|")],
    ["noncash", "help that isn't cash", (x) => x.label, (x) => ["n", x.kind, x.category, String(x.label).toLowerCase()].join("|")]];
  for (const [key, what, name, id] of lists) {
    const a = new Map(((older.inputs || {})[key] || []).map((x) => [id(x), x])), b = new Map(((newer.inputs || {})[key] || []).map((x) => [id(x), x]));
    for (const [k, x] of b) {
      const o = a.get(k);
      if (!o) out.push(\`Added \${what}: \${name(x)}, \${fmtLine(x)}\`);
      else if (annualOf(o) !== annualOf(x) || o.paid_by !== x.paid_by || o.start_on !== x.start_on || o.end_on !== x.end_on
        || JSON.stringify(o.applies_to || null) !== JSON.stringify(x.applies_to || null)) out.push(\`Changed \${what}: \${name(x)}, \${fmtLine(o)} → \${fmtLine(x)}\`);
    }
    for (const [k, x] of a) if (!b.has(k)) out.push(\`Removed \${what}: \${name(x)}\`);
  }
  const ga = new Map(((older.inputs || {}).goals || []).map((g) => [String(g.label).toLowerCase(), g]));
  for (const g of ((newer.inputs || {}).goals || [])) {
    const o = ga.get(String(g.label).toLowerCase());
    if (!o) out.push(\`Added goal: \${g.label}\`);
    else if (Number(o.current_amount) !== Number(g.current_amount)) out.push(\`Goal \${g.label}: saved \${money(Number(o.current_amount))} → \${money(Number(g.current_amount))}\`);
    else if (Number(o.target_amount) !== Number(g.target_amount) || o.target_date !== g.target_date || o.level !== g.level) out.push(\`Changed goal: \${g.label}\`);
  }
  const ta = Number((older.inputs || {}).tax_rate_pct || 0), tb = Number((newer.inputs || {}).tax_rate_pct || 0);
  if (ta !== tb) out.push(\`Tax rate: \${ta}% → \${tb}%\`);
  return out;
}

// ---------------------------------------------------------------- the chart: Today and Stability per day, over time
// Change over time = a line chart (two series, one axis in dollars a day starting at 0). Colors: the dataviz reference blue and orange,
// validated (light on white, dark on #1D242B: all checks pass). Legend + direct end labels, so identity is never color alone; hover or
// focus shows the values; the save cards below are the table view.
const SERIES = [["current", "Today", "--mm-viz-1"], ["stability", "Stability", "--mm-viz-2"]];
function chart(asc) {
  const W = 640, H = 220, padL = 56, padR = 86, padT = 14, padB = 34;
  const vals = asc.flatMap((snap) => SERIES.map(([k]) => (snap.results.levels && snap.results.levels[k] ? snap.results.levels[k].cost.daily : 0)));
  const max = Math.max(1, ...vals);
  const step = max <= 20 ? 5 : max <= 50 ? 10 : max <= 100 ? 20 : max <= 250 ? 50 : 100;
  const top = Math.ceil(max / step) * step;
  const t0 = Date.parse(asc[0].taken_at), t1 = Date.parse(asc[asc.length - 1].taken_at);
  const x = (t) => padL + (t1 === t0 ? (W - padL - padR) / 2 : ((t - t0) / (t1 - t0)) * (W - padL - padR));
  const y = (v) => padT + (1 - v / top) * (H - padT - padB);
  const ticks = []; for (let v = 0; v <= top + 0.001; v += step) ticks.push(v);
  const pts = (k) => asc.map((snap) => [x(Date.parse(snap.taken_at)), y(snap.results.levels && snap.results.levels[k] ? snap.results.levels[k].cost.daily : 0)]);
  const fmtD = (t) => new Date(t).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  const last = asc[asc.length - 1];
  return \`<figure class="mm-card mm-viz" style="margin:0 0 var(--mm-space-5)">
    <figcaption><strong>Cost per day over time</strong></figcaption>
    <div class="mm-viz-legend">\${SERIES.map(([, name, c]) => \`<span><i style="background:var(\${c})"></i>\${esc(name)}</span>\`).join("")}</div>
    <div class="mm-viz-wrap">
    <svg viewBox="0 0 \${W} \${H}" role="img" aria-label="Line chart: cost per day for Today and Stability at each save, from \${esc(fmtD(t0))} to \${esc(fmtD(t1))}. The saves below list every value.">
      \${ticks.map((v) => \`<line x1="\${padL}" x2="\${W - padR}" y1="\${y(v)}" y2="\${y(v)}" class="mm-viz-grid"/><text x="\${padL - 8}" y="\${y(v) + 4}" text-anchor="end" class="mm-viz-axis">\${esc(money(v).replace(".00", ""))}</text>\`).join("")}
      <text x="\${padL}" y="\${H - 10}" class="mm-viz-axis">\${esc(fmtD(t0))}</text>
      <text x="\${W - padR}" y="\${H - 10}" text-anchor="end" class="mm-viz-axis">\${esc(fmtD(t1))}</text>
      \${SERIES.map(([k, name, c]) => { const p = pts(k); const lp = p[p.length - 1];
        return \`<polyline fill="none" stroke="var(\${c})" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" points="\${p.map((q) => q.join(",")).join(" ")}"/>
          \${p.map((q) => \`<circle cx="\${q[0]}" cy="\${q[1]}" r="4" fill="var(\${c})" stroke="var(--mm-surface)" stroke-width="2"/>\`).join("")}
          <text x="\${lp[0] + 10}" y="\${lp[1] + 4}" class="mm-viz-label">\${esc(name)} \${esc(money(last.results.levels[k] ? last.results.levels[k].cost.daily : 0))}</text>\`; }).join("")}
      <line class="mm-viz-cross" y1="\${padT}" y2="\${H - padB}" x1="-10" x2="-10"/>
      \${asc.map((snap, i) => { const cx = x(Date.parse(snap.taken_at)); const w = asc.length > 1 ? Math.max(14, (W - padL - padR) / (asc.length - 1)) : 40;
        return \`<rect class="mm-viz-hit" x="\${cx - w / 2}" y="\${padT}" width="\${w}" height="\${H - padT - padB}" tabindex="0" data-i="\${i}"
          aria-label="\${esc(fmtD(Date.parse(snap.taken_at)))}: \${SERIES.map(([k, n]) => n + " " + money(snap.results.levels[k] ? snap.results.levels[k].cost.daily : 0) + " a day").join(", ")}"/>\`; }).join("")}
    </svg>
    <div class="mm-viz-tip" hidden></div></div>
    <script type="application/json" class="mm-viz-data">\${JSON.stringify(asc.map((snap) => ({ x: x(Date.parse(snap.taken_at)), d: fmtD(Date.parse(snap.taken_at)),
      v: SERIES.map(([k]) => (snap.results.levels[k] ? snap.results.levels[k].cost.daily : 0)) }))).replace(/</g, "\\\\u003c")}</script>
  </figure>\`;
}

/** Hover or keyboard focus on a save shows a crosshair and the values. */
function wireChart(root) {
  const fig = root.querySelector(".mm-viz");
  if (!fig) return;
  const data = JSON.parse(fig.querySelector(".mm-viz-data").textContent);
  const tip = /** @type {HTMLElement} */ (fig.querySelector(".mm-viz-tip"));
  const cross = fig.querySelector(".mm-viz-cross");
  const svg = fig.querySelector("svg");
  const show = (i) => {
    const p = data[i];
    cross.setAttribute("x1", p.x); cross.setAttribute("x2", p.x);
    tip.innerHTML = \`<strong>\${esc(p.d)}</strong>\${SERIES.map(([, n, c], j) => \`<span><i style="background:var(\${c})"></i>\${esc(n)} \${esc(money(p.v[j]))} a day</span>\`).join("")}\`;
    tip.hidden = false;
    const box = svg.getBoundingClientRect();
    tip.style.left = Math.min(box.width - 180, Math.max(0, (p.x / 640) * box.width - 90)) + "px";
  };
  const hide = () => { tip.hidden = true; cross.setAttribute("x1", "-10"); cross.setAttribute("x2", "-10"); };
  fig.querySelectorAll(".mm-viz-hit").forEach((r) => {
    const i = Number(r.getAttribute("data-i"));
    r.addEventListener("pointerenter", () => show(i)); r.addEventListener("focus", () => show(i));
    r.addEventListener("pointerleave", hide); r.addEventListener("blur", hide);
  });
}
`;
fs.writeFileSync(f, s);
console.log("ok");
