// One-off edit (Stephen 11/13/2026, Phase 4 step 2 "make it trustworthy") of site/mirror/assets/daily-number-page.js.
import fs from "node:fs";
const f = "site/mirror/assets/daily-number-page.js";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (!s.includes(a)) throw new Error("miss: " + a.slice(0, 90)); s = s.split(a).join(b); };

rep(`import { annualOf, money, CATEGORIES, FREQUENCIES, goalMonthly, inEffect, shortDate, daysBetween } from "/mirror/assets/daily-number.js?v=20261113b";`,
  `import { annualOf, money, CATEGORIES, FREQUENCIES, goalMonthly, inEffect, shortDate, daysBetween, isTaxable, roughTaxRate } from "/mirror/assets/daily-number.js?v=20261113c";`);

// ---------------------------------------------------------------- shared helpers: which numbers a resource counts toward
rep(`/** Lines starting or ending within the next 90 days.`, `const LEVEL_KEYS = ["current", "survival", "stability", "aspirational"];
const LEVEL_SHORT = { current: "Today", survival: "Survival", stability: "Stability", aspirational: "The life I want" };
/** Does a resource count toward this number? (no list = all four) @param {any} x @param {string} lv */
const appliesTo = (x, lv) => !x.applies_to || !x.applies_to.length || x.applies_to.includes(lv);
/** "Today and Survival only" (empty when it counts everywhere). @param {any} x */
const appliesText = (x) => !x.applies_to || !x.applies_to.length || x.applies_to.length === 4 ? "" : x.applies_to.map((k) => LEVEL_SHORT[k]).join(", ") + " only";
/** Four checkboxes: which numbers this income or help counts toward. @param {any} x */
const appliesFields = (x) => \`<fieldset class="mm-choices" style="margin-bottom:var(--mm-space-4)"><legend class="mm-legend">Counts toward</legend>
  <span class="mm-hint">Untick a number if this won't be there at that level, for example SNAP that would stop with a full-time job, or a job that hasn't started.</span>
  <div class="mm-choices-other">\${LEVEL_KEYS.map((k) => \`<label class="mm-choice"><input type="checkbox" name="inApplies" value="\${k}"\${appliesTo(x || {}, k) ? " checked" : ""}> \${esc(LEVEL_SHORT[k])}</label>\`).join("")}</div></fieldset>\`;
const readApplies = (f) => [...f.querySelectorAll('input[name="inApplies"]:checked')].map((i) => /** @type {HTMLInputElement} */ (i).value);

/** Lines starting or ending within the next 90 days.`);

// ---------------------------------------------------------------- home: the paper's three figures for today
rep(`    <h2>What you have each day</h2>
    <div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Daily resources and gap</caption>
      <thead><tr><th scope="col">Today</th><th scope="col" class="mm-num">Per day</th><th scope="col" class="mm-num">Per month</th></tr></thead>
      <tbody>
        <tr><td data-label="Today">Cash income you have</td><td class="mm-num" data-label="Per day">\${money(R.income.daily)}</td><td class="mm-num" data-label="Per month">\${money(R.income.monthly)}</td></tr>
        <tr><td data-label="Today">Help that isn't cash (SNAP, donations, coverage)</td><td class="mm-num" data-label="Per day">\${money(R.noncash.daily)}</td><td class="mm-num" data-label="Per month">\${money(R.noncash.monthly)}</td></tr>
        <tr><td data-label="Today">Costs paid for you (subsidy, programs, donated)</td><td class="mm-num" data-label="Per day">\${money(L.current.paid_by_others.daily)}</td><td class="mm-num" data-label="Per month">\${money(L.current.paid_by_others.monthly)}</td></tr>
      </tbody>
      <tfoot><tr><td data-label="Today">Daily gap today</td><td class="mm-num" data-label="Per day">\${money(L.current.shortfall.daily)}</td><td class="mm-num" data-label="Per month">\${money(L.current.shortfall.monthly)}</td></tr></tfoot>
    </table></div>`,
  `    <h2>Today: cost, resources, gap</h2>
    <div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Today's cost, resources and gap</caption>
      <thead><tr><th scope="col">Today</th><th scope="col" class="mm-num">Per day</th><th scope="col" class="mm-num">Per month</th></tr></thead>
      <tbody>
        <tr><td data-label="Today"><strong>What life costs</strong></td><td class="mm-num" data-label="Per day">\${money(L.current.cost.daily)}</td><td class="mm-num" data-label="Per month">\${money(L.current.cost.monthly)}</td></tr>
        <tr><td data-label="Today"><strong>Resources available</strong></td><td class="mm-num" data-label="Per day">\${money(L.current.resources.daily)}</td><td class="mm-num" data-label="Per month">\${money(L.current.resources.monthly)}</td></tr>
        <tr><td data-label="Today">&nbsp;&nbsp;Cash income</td><td class="mm-num" data-label="Per day">\${money(L.current.income.daily)}</td><td class="mm-num" data-label="Per month">\${money(L.current.income.monthly)}</td></tr>
        <tr><td data-label="Today">&nbsp;&nbsp;Help that isn't cash, used for your costs</td><td class="mm-num" data-label="Per day">\${money(L.current.noncash_applied.daily)}</td><td class="mm-num" data-label="Per month">\${money(L.current.noncash_applied.monthly)}</td></tr>
        <tr><td data-label="Today">&nbsp;&nbsp;Costs paid for you</td><td class="mm-num" data-label="Per day">\${money(L.current.paid_by_others.daily)}</td><td class="mm-num" data-label="Per month">\${money(L.current.paid_by_others.monthly)}</td></tr>
      </tbody>
      <tfoot><tr><td data-label="Today">Daily gap (still needed)</td><td class="mm-num" data-label="Per day">\${money(L.current.shortfall.daily)}</td><td class="mm-num" data-label="Per month">\${money(L.current.shortfall.monthly)}</td></tr></tfoot>
    </table></div>
    \${L.current.resources.annual > L.current.cost.annual && L.current.cost.annual > 0 ? notice("ok", \`<p>Your resources cover today's costs, with \${money(L.current.resources.daily - L.current.cost.daily)} a day to spare.</p>\`) : ""}`);

// ---------------------------------------------------------------- income page: "counts toward", taxed or not, list tags, rough tax
rep(`  const incomeForm = (x) => simpleForm(body.querySelector("#incForm"), "income", x, "Add cash income", sel("inKind", INCOME_KINDS, x ? x.kind : "wages"), (f) => ({ kind: v(f, "inKind") }));`,
  `  const incomeForm = (x) => simpleForm(body.querySelector("#incForm"), "income", x, "Add cash income",
    \`\${sel("inKind", INCOME_KINDS, x ? x.kind : "wages")}
    <div class="mm-field" style="margin-top:var(--mm-space-3)"><label for="inTax">Is this income taxed?</label>
      <span class="mm-hint">Pay from a job, your own work and most pensions are taxed. SSI, gifts from family and most other help are not. Not sure? Leave "The usual way".</span>
      \${sel("inTax", [["", "The usual way for this kind"], ["true", "Yes, it is taxed"], ["false", "No, it isn't taxed"]], x && x.taxable !== null && x.taxable !== undefined ? String(x.taxable) : "")}</div>\`,
    (f) => ({ kind: v(f, "inKind"), taxable: v(f, "inTax") }));`);
rep(`    \${freqFields("in", x)}
    <p class="mm-hint" id="inDaily" aria-live="polite"></p>
    \${dateFields("in", x)}`, `    \${freqFields("in", x)}
    <p class="mm-hint" id="inDaily" aria-live="polite"></p>
    \${appliesFields(x)}
    \${dateFields("in", x)}`);
rep(`        times_per_year: v(f, "inTimes"), spread_months: v(f, "inSpread"), start_on: v(f, "inStart"), end_on: v(f, "inEnd"), ...extra(f) } });`,
  `        times_per_year: v(f, "inTimes"), spread_months: v(f, "inSpread"), start_on: v(f, "inStart"), end_on: v(f, "inEnd"), applies_to: readApplies(f), ...extra(f) } });`);
rep(`    \${list("income", I.income, (x) => IK[x.kind] || x.kind)}`,
  `    \${list("income", I.income, (x) => [IK[x.kind] || x.kind, isTaxable(x) ? "taxed" : "not taxed", appliesText(x)].filter(Boolean).join(" · "))}`);
rep(`    \${list("noncash", I.noncash, (x) => (NK[x.kind] || x.kind) + " · covers " + (CAT[x.category] || x.category))}`,
  `    \${list("noncash", I.noncash, (x) => [(NK[x.kind] || x.kind) + " · covers " + (CAT[x.category] || x.category), appliesText(x)].filter(Boolean).join(" · "))}`);
rep(`      <div class="mm-field" style="max-width:14rem"><label for="setTax">Tax rate on new income (%)</label>
        <span class="mm-hint">Leave 0 if you're not sure. Your coordinator can help. Nothing is assumed.</span>
        <input class="mm-input" id="setTax" inputmode="decimal" data-mm-no-voice value="\${esc(D.results.tax_rate_pct || 0)}"></div>`,
  `      <div class="mm-field" style="max-width:14rem"><label for="setTax">Tax rate on taxed income (%)</label>
        <span class="mm-hint">Used for "income needed before taxes". Untaxed income (SSI, gifts) is left out of it. Nothing is assumed.</span>
        <input class="mm-input" id="setTax" inputmode="decimal" data-mm-no-voice value="\${esc(D.results.tax_rate_pct || 0)}"></div>
      <p class="mm-small"><button class="mm-btn mm-btn-quiet" type="button" id="setRough" style="padding:0;min-height:auto">Not sure? Use a rough estimate</button></p>
      <p class="mm-hint" id="setRoughText" aria-live="polite"></p>
      <p class="mm-hint">For a real figure, free tax help (VITA) is available every year: call 2-1-1 to find a site near you.</p>`);
rep(`  body.querySelector("#setForm").addEventListener("submit", async (e) => {`,
  `  body.querySelector("#setRough").addEventListener("click", () => {
    // rough guide from the taxed income in the Stability number (or today's when Stability has none)
    const taxed = (lv) => I.income.filter((x) => inEffect(x, asOf()) && appliesTo(x, lv) && isTaxable(x)).reduce((sum, x) => sum + annualOf(x) / 12, 0);
    const monthly = taxed("stability") || taxed("current");
    const rate = roughTaxRate(monthly);
    /** @type {HTMLInputElement} */ (body.querySelector("#setTax")).value = String(rate);
    body.querySelector("#setRoughText").textContent = \`Rough estimate: \${rate}% for about \${money(monthly)} a month of taxed income (Social Security and Medicare take 7.65% of pay, plus some income tax). Press Save to use it.\`;
  });
  body.querySelector("#setForm").addEventListener("submit", async (e) => {`);

// ---------------------------------------------------------------- the gap: resources per level, benefit warnings
rep(`  const row = (k, label) => \`<tr><td data-label="Level"><strong>\${esc(label)}</strong></td>
    <td class="mm-num" data-label="Costs a day">\${money(L[k].cost.daily)}</td>
    <td class="mm-num" data-label="Cash you'd pay a day">\${money(L[k].cash_needed.daily)}</td>
    <td class="mm-num" data-label="Short a day">\${money(L[k].shortfall.daily)}</td>
    <td class="mm-num" data-label="Short a month">\${money(L[k].shortfall.monthly)}</td>
    <td class="mm-num" data-label="Earn before taxes, a month">\${money(L[k].gross_needed.monthly)}</td></tr>\`;`,
  `  const row = (k, label) => \`<tr><td data-label="Level"><strong>\${esc(label)}</strong></td>
    <td class="mm-num" data-label="Costs a day">\${money(L[k].cost.daily)}</td>
    <td class="mm-num" data-label="Resources a day">\${money(L[k].resources.daily)}</td>
    <td class="mm-num" data-label="Short a day">\${money(L[k].shortfall.daily)}</td>
    <td class="mm-num" data-label="Short a month">\${money(L[k].shortfall.monthly)}</td>
    <td class="mm-num" data-label="Taxed income needed, a month">\${money(L[k].gross_needed.monthly)}</td></tr>\`;
  // Benefits that count today but not higher up, and benefits still counted higher up although earnings rise there.
  const BENEFIT_NONCASH = ["snap", "wic", "healthcare_coverage"];
  const live = (x) => inEffect(x, asOf());
  const benefits = [...D.inputs.income.filter((x) => live(x) && x.kind === "cash_benefit"), ...D.inputs.noncash.filter((x) => live(x) && BENEFIT_NONCASH.includes(x.kind))];
  const earned = (lv) => D.inputs.income.filter((x) => live(x) && appliesTo(x, lv) && ["wages", "self_employment"].includes(x.kind)).reduce((sum, x) => sum + annualOf(x), 0);
  const dropped = benefits.filter((x) => appliesTo(x, "current") && (!appliesTo(x, "stability") || !appliesTo(x, "aspirational")));
  const atRisk = ["stability", "aspirational"].filter((lv) => earned(lv) > earned("current")).flatMap((lv) => benefits.filter((x) => appliesTo(x, lv)).map((x) => [lv, x]));
  const riskNames = [...new Set(atRisk.map(([, x]) => x.label))];`);
rep(`      <thead><tr><th scope="col">Level</th><th scope="col" class="mm-num">Costs a day</th><th scope="col" class="mm-num">Cash you'd pay a day</th>
        <th scope="col" class="mm-num">Short a day</th><th scope="col" class="mm-num">Short a month</th><th scope="col" class="mm-num">Earn before taxes, a month</th></tr></thead>
      <tbody>\${row("current", "Today")}\${row("survival", "Survival")}\${row("stability", "Stability")}\${row("aspirational", "The life I want")}</tbody></table></div>
    <p class="mm-muted mm-small">"Earn before taxes" uses the tax rate you entered (\${esc(R.tax_rate_pct)}%) on <a href="\${BASE}income/">Income and support</a>. It covers the cash you'd pay from all income together.</p>`,
  `      <thead><tr><th scope="col">Level</th><th scope="col" class="mm-num">Costs a day</th><th scope="col" class="mm-num">Resources a day</th>
        <th scope="col" class="mm-num">Short a day</th><th scope="col" class="mm-num">Short a month</th><th scope="col" class="mm-num">Taxed income needed, a month</th></tr></thead>
      <tbody>\${row("current", "Today")}\${row("survival", "Survival")}\${row("stability", "Stability")}\${row("aspirational", "The life I want")}</tbody></table></div>
    <p class="mm-muted mm-small">Resources = cash income + help that isn't cash used for your costs + costs paid for you. "Taxed income needed" is what you'd need to earn
      before taxes (at the \${esc(R.tax_rate_pct)}% you entered on <a href="\${BASE}income/">Income and support</a>) to pay your cash costs, after your untaxed income.</p>
    \${dropped.length ? notice("info", \`<p>Not counted at every level: \${dropped.map((x) => \`<strong>\${esc(x.label)}</strong> (\${esc(appliesText(x) || "")})\`).join(", ")}. The gap at those levels already leaves them out.</p>\`) : ""}
    \${riskNames.length ? notice("caution", \`<p><strong>Benefits can go down as earnings go up.</strong> Your Stability or The life I want numbers include more earned income than today,
      and still count \${riskNames.map((n) => "<strong>" + esc(n) + "</strong>").join(", ")}. SNAP, SSI, BadgerCare and similar help often shrink or stop when pay rises.
      Ask your coordinator whether they will continue, and untick those levels on <a href="\${BASE}income/">Income and support</a> if not.</p>\`) : ""}`);
rep(`      <p class="mm-lead">Your cash income is \${money(R.income.daily)} a day. For each level: what life costs, the cash you'd pay after help that isn't cash,
        what's still missing, and what income before taxes would cover it.</p></div>`,
  `      <p class="mm-lead">For each level: what life costs, the resources you'd have, what's still missing, and the taxed income that would cover it.</p></div>`);

fs.writeFileSync(f, s);
console.log("ok");
