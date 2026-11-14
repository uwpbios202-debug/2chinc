// One-off edit (Stephen 11/13/2026, "fix what's wrong or broken"): dates, goals that count, one-step copy on the Daily Number pages.
import fs from "node:fs";
const f = "site/mirror/assets/daily-number-page.js";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (!s.includes(a)) throw new Error("miss: " + a.slice(0, 80)); s = s.split(a).join(b); };

rep(`import { annualOf, money, CATEGORIES, FREQUENCIES } from "/mirror/assets/daily-number.js?v=20261113a";`,
  `import { annualOf, money, CATEGORIES, FREQUENCIES, goalMonthly, inEffect, shortDate, daysBetween } from "/mirror/assets/daily-number.js?v=20261113b";`);

// lines show their dates; a line not counted today says so
rep(`const fmtLine = (l) => \`\${money(Number(l.amount))} \${(FREQ[l.frequency] || l.frequency).toLowerCase()}\${l.frequency === "irregular" ? \` (\${Number(l.times_per_year)} times a year)\` : ""}\${l.frequency === "one_time" && l.spread_months ? \` over \${l.spread_months} months\` : ""}\`;`,
  `const fmtLine = (l) => \`\${money(Number(l.amount))} \${(FREQ[l.frequency] || l.frequency).toLowerCase()}\${l.frequency === "irregular" ? \` (\${Number(l.times_per_year)} times a year)\` : ""}\${l.frequency === "one_time" && l.spread_months ? \` over \${l.spread_months} months\` : ""}\${l.start_on ? " from " + shortDate(l.start_on) : ""}\${l.end_on ? " until " + shortDate(l.end_on) : ""}\`;
/** Today's date used by the numbers (Milwaukee time, from the database). */
const asOf = () => (D && D.results && D.results.as_of) || new Date().toISOString().slice(0, 10);
/** A tag for a line that is not counted today. @param {any} l */
const dateTag = (l) => inEffect(l, asOf()) ? "" : (l.start_on && l.start_on > asOf()
  ? \` <span class="mm-tag mm-tag-info">Starts \${esc(shortDate(l.start_on))}</span>\` : \` <span class="mm-tag">Ended \${esc(shortDate(l.end_on))}</span>\`);
/** Per-day cell: the amount, or a dash when the line isn't counted today. @param {any} l */
const perDayCell = (l) => inEffect(l, asOf()) ? money(annualOf(l) / 365) : '<span class="mm-muted" title="Not counted today">—</span>';
/** Optional start and end dates, folded away unless used. @param {string} prefix @param {any} x */
const dateFields = (prefix, x) => \`<details class="mm-dates"\${x && (x.start_on || x.end_on) ? " open" : ""}><summary>Only for part of the time? Add a start or end date</summary>
  <div class="mm-row" style="margin-top:var(--mm-space-3)">
    <div class="mm-field" style="max-width:14rem"><label for="\${prefix}Start">Starts on <span class="mm-muted">(optional)</span></label><input class="mm-input" type="date" id="\${prefix}Start" value="\${esc(x && x.start_on ? x.start_on : "")}"></div>
    <div class="mm-field" style="max-width:14rem"><label for="\${prefix}End">Ends on <span class="mm-muted">(optional)</span></label><input class="mm-input" type="date" id="\${prefix}End" value="\${esc(x && x.end_on ? x.end_on : "")}"></div></div>
  <p class="mm-hint">The Daily Number counts it only between these dates. Leave them empty for a cost that goes on.</p></details>\`;
/** Lines starting or ending within the next 90 days. @param {any[]} rows */
const comingUp = (rows) => rows.filter((l) => (l.start_on && l.start_on > asOf() && daysBetween(asOf(), l.start_on) <= 90) || (l.end_on && l.end_on >= asOf() && daysBetween(asOf(), l.end_on) <= 90))
  .map((l) => l.start_on && l.start_on > asOf() ? \`\${l.label} starts \${shortDate(l.start_on)}\` : \`\${l.label} ends \${shortDate(l.end_on)}\`);`);

// level page: per-day cells, tags, goals, coming up, one-step copy
rep(`<td data-label="Cost">\${esc(x.label)}\${x.poverty_premium ? ' <span class="mm-tag mm-tag-suggested">Could go down</span>' : ""}`,
  `<td data-label="Cost">\${esc(x.label)}\${dateTag(x)}\${x.poverty_premium ? ' <span class="mm-tag mm-tag-suggested">Could go down</span>' : ""}`);
rep(`          <td class="mm-num" data-label="Per day">\${money(annualOf(x) / 365)}</td>
          <td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-edit="\${esc(x.id)}">Change</button></td></tr>\`).join("")}</tbody></table></div>\`).join("")
      : notice("info", "<p>No costs here yet. Add the first one below.</p>")}`,
  `          <td class="mm-num" data-label="Per day">\${perDayCell(x)}</td>
          <td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-edit="\${esc(x.id)}">Change</button></td></tr>\`).join("")}</tbody></table></div>\`).join("")
      : notice("info", "<p>No costs here yet. Add the first one below.</p>")}
    \${L.goals && L.goals.annual > 0 ? notice("info", \`<p><strong>Savings goals: \${money(L.goals.monthly)} a month</strong> (\${money(L.goals.daily)} a day) is included above as a cost you pay. Change your goals on <a href="\${BASE}income/">Income and support</a>.</p>\`) : ""}
    \${comingUp(own).length ? \`<h2 style="font-size:1.2rem">Coming up</h2><ul>\${comingUp(own).map((t) => \`<li>\${esc(t)}</li>\`).join("")}</ul>\` : ""}`);
rep(`    b.disabled = true;
    try {
      for (const x of from) await rpc("mirror_dn_save", { p_kind: "expense", p: { ...x, id: "", level: lv } });
      reload(lv, \`Copied \${from.length} lines. Change any amount to fit this level.\`);
    } catch (e) { toast(e instanceof Error ? e.message : String(e)); b.disabled = false; }`,
  `    b.disabled = true;
    try {
      const r = await rpc("mirror_dn_copy", { p_from: b.dataset.copy, p_to: lv });   // one step: all lines or none
      reload(lv, \`Copied \${r.copied} lines. Change any amount to fit this level.\`);
    } catch (e) { toast(e instanceof Error ? e.message : String(e)); b.disabled = false; }`);

// expense form: dates
rep(`    <p class="mm-hint" id="exDaily" aria-live="polite"></p>
    <div class="mm-field"><label for="exPaid">Who pays it?</label>`, `    <p class="mm-hint" id="exDaily" aria-live="polite"></p>
    \${dateFields("ex", x)}
    <div class="mm-field"><label for="exPaid">Who pays it?</label>`);
rep(`        poverty_premium: /** @type {HTMLInputElement} */ (f.querySelector("#exPoor")).checked, note: v(f, "exNote") } });`,
  `        poverty_premium: /** @type {HTMLInputElement} */ (f.querySelector("#exPoor")).checked, note: v(f, "exNote"),
        start_on: v(f, "exStart"), end_on: v(f, "exEnd") } });`);

// income / help forms: dates
rep(`    <p class="mm-hint" id="inDaily" aria-live="polite"></p>
    <div id="inMsg" aria-live="assertive"></div>`, `    <p class="mm-hint" id="inDaily" aria-live="polite"></p>
    \${dateFields("in", x)}
    <div id="inMsg" aria-live="assertive"></div>`);
rep(`        times_per_year: v(f, "inTimes"), spread_months: v(f, "inSpread"), ...extra(f) } });`,
  `        times_per_year: v(f, "inTimes"), spread_months: v(f, "inSpread"), start_on: v(f, "inStart"), end_on: v(f, "inEnd"), ...extra(f) } });`);
rep(`      <tbody>\${rows.map((x) => \`<tr><td data-label="What">\${esc(x.label)}<br>`, `      <tbody>\${rows.map((x) => \`<tr><td data-label="What">\${esc(x.label)}\${dateTag(x)}<br>`);
rep(`        <td class="mm-num" data-label="Per day">\${money(annualOf(x) / 365)}</td><td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-\${kind}=`,
  `        <td class="mm-num" data-label="Per day">\${perDayCell(x)}</td><td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-\${kind}=`);

// goals: which number they count in, and what that means each month
rep(`        \${g.target_amount ? countBar(Math.round(Number(g.current_amount)), Math.round(Number(g.target_amount)), "dollars saved") : \`<p class="mm-small">\${money(Number(g.current_amount))} saved</p>\`}</div>\`).join("")`,
  `        \${g.target_amount ? countBar(Math.round(Number(g.current_amount)), Math.round(Number(g.target_amount)), "dollars saved") : \`<p class="mm-small">\${money(Number(g.current_amount))} saved</p>\`}
        <p class="mm-small" style="margin:0">\${goalText(g)}</p></div>\`).join("")`);
rep(`function goalForm(el, g) {`, `/** What a goal means for the Daily Number. @param {any} g */
function goalText(g) {
  const where = g.level === "aspirational" ? "The life I want" : "Stability";
  if ((Number(g.target_amount) || 0) <= (Number(g.current_amount) || 0) && g.target_amount) return "Reached. Well done.";
  if (g.level === "none") return "Not counted in your Daily Number.";
  if (!g.target_amount || !g.target_date) return "Add a goal amount and a date, and the Mirror works out what to save each month.";
  const m = goalMonthly(g, asOf());
  if (m <= 0) return "The date has passed. Choose a new date to plan again.";
  return \`Saving \${esc(money(m))} a month until \${esc(shortDate(g.target_date))}, counted in \${where}.\`;
}

function goalForm(el, g) {`);
rep(`    <div class="mm-field"><label for="gLabel">Name</label><input class="mm-input" id="gLabel" maxlength="120" value="\${esc(g ? g.label : "")}" placeholder="For example: Emergency fund"></div>`,
  `    <div class="mm-field"><label for="gLabel">Name</label><input class="mm-input" id="gLabel" maxlength="120" value="\${esc(g ? g.label : "")}" placeholder="For example: Emergency fund"></div>
    <div class="mm-field"><label for="gLevel">Count the monthly saving in</label>
      <span class="mm-hint">With an amount and a date, the Mirror works out what to save each month and adds it to that number.</span>
      \${sel("gLevel", [["stability", "My Stability Number"], ["aspirational", "The life I want"], ["none", "Don't count it"]], g ? g.level : "stability")}</div>`);
rep(`      await rpc("mirror_dn_save", { p_kind: "goal", p: { id: g ? g.id : "", kind: v(f, "gKind"), label: v(f, "gLabel"),`,
  `      await rpc("mirror_dn_save", { p_kind: "goal", p: { id: g ? g.id : "", kind: v(f, "gKind"), label: v(f, "gLabel"), level: v(f, "gLevel"),`);

fs.writeFileSync(f, s);
console.log("ok");
