// @ts-check
// The Human Mirror T4.3 + T4.4: the Daily Number pages. Each /mirror/my-mirror/daily-number/<page>/ is a few lines of HTML with
// <body data-area="my" data-dn="home|current|survival|stability|aspirational|income|gap|plan|whatif|benefits|household|history|reflect"> and loads this file.
// Arithmetic lives only in daily-number.js (shown here) and mirror.daily_number_calc() (saved); both checked against the same fixtures.

import { requireArea, rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice, toast, countBar } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { annualOf, money, CATEGORIES, FREQUENCIES, goalMonthly, inEffect, endOn, shortDate, daysBetween, isTaxable, roughTaxRate,
  dailyNumber, withPlan, whatIf, planEffect, takeHome, opportunityTaxable, openOpportunities, opportunityAsIncome, whoPays } from "/mirror/assets/daily-number.js?v=20261113e";
import { voiceAll } from "/mirror/assets/mirror-voice.js?v=20261113c";
import { runSet } from "/mirror/assets/assessment-engine.js?v=20261113p";

const BASE = "/mirror/my-mirror/daily-number/";
export const PAGES = [
  ["home", "", "My Daily Number"], ["current", "today/", "Today"], ["survival", "survival/", "Survival"], ["stability", "stability/", "Stability"],
  ["aspirational", "aspirations/", "The life I want"], ["income", "income/", "Income and support"], ["gap", "gap/", "The gap"], ["plan", "plan/", "My plan"], ["whatif", "what-if/", "What if"],
  ["benefits", "benefits/", "Benefits"], ["household", "household/", "Household"], ["history", "history/", "History"],
  ["reflect", "reflect/", "Reflect"],
];

// Suggested costs per list (Stephen's Daily Number paper: what each level includes). [category, label, how often, hint]
const SUGGEST = {
  current: [["housing", "Where I stay", "monthly", "Rent, a room, a shelter fee, or what you give family. If someone else pays, choose who pays."],
    ["food", "Food and drinking water", "weekly"], ["communication", "Phone", "monthly"], ["transportation", "Getting around", "weekly", "Bus fares, a pass, gas, rides."],
    ["healthcare", "Medicine and health care", "monthly"], ["personal_care", "Hygiene and toiletries", "monthly"], ["clothing", "Clothing and shoes", "monthly"],
    ["household", "Laundry and cleaning", "weekly"], ["financial", "Debts and fees", "monthly", "Payments on debts, bank or check-cashing fees, late fees."]],
  survival: [["housing", "Safe place to stay", "monthly", "A shelter bed, a room, or a safe temporary place. If it's free, choose “It's donated or free”."],
    ["food", "Food and drinking water", "daily"], ["personal_care", "Personal hygiene", "weekly"], ["clothing", "Essential clothing", "monthly"],
    ["transportation", "Getting to services", "weekly", "Bus fares to appointments, work, the food pantry."], ["communication", "Phone access", "monthly"],
    ["healthcare", "Essential medicine and care", "monthly"]],
  stability: [["housing", "Rent", "monthly"], ["utilities", "Electricity, gas and water", "monthly"], ["food", "Food", "monthly"],
    ["household", "Household supplies", "monthly"], ["transportation", "Transportation", "monthly", "A bus pass, or car payment, gas and insurance."],
    ["communication", "Phone and internet", "monthly"], ["healthcare", "Health care and insurance", "monthly"], ["clothing", "Clothing", "monthly"],
    ["personal_care", "Personal care", "monthly"], ["household", "Upkeep and repairs", "monthly"], ["financial", "Debt payments", "monthly"]],
  aspirational: [["development", "Education and training", "monthly"], ["development", "Recreation and entertainment", "monthly"], ["development", "Travel", "annual"],
    ["development", "Hobbies and interests", "monthly"], ["development", "Family activities", "monthly"], ["future", "Investments", "monthly"],
    ["development", "Starting or growing a business", "monthly"], ["future", "Retirement", "monthly"], ["financial", "Giving to a cause or community", "monthly"]],
};

// The paper's "cost of being poor" (section 7), each with a cheaper way. [kind, label, category, how often, the cheaper way]
const PREMIUMS = [
  ["small_quantities", "Buying food in small amounts", "food", "weekly", "Buying in larger amounts when you can, sharing bulk buys, and food pantries."],
  ["convenience_store", "Convenience-store prices (no way to the supermarket)", "food", "weekly", "A ride or bus to a supermarket, shopping with a neighbor, or grocery delivery."],
  ["laundromat", "Paying per laundry load", "household", "weekly", "A home with laundry, or a shared washer; some laundromats sell cheaper cards."],
  ["prepaid_phone", "Prepaid phone that costs more over time", "communication", "monthly", "Lifeline phone discounts, or a cheaper monthly plan."],
  ["long_commute", "Long or costly trips to work", "transportation", "weekly", "Housing closer to work or a bus line, or a monthly pass."],
  ["per_ride_fares", "Paying per bus ride instead of a pass", "transportation", "weekly", "A weekly or monthly pass, or a reduced-fare card if you qualify."],
  ["late_fees", "Late fees", "financial", "monthly", "Payment reminders, due dates moved to after payday, or automatic payments."],
  ["overdraft", "Overdraft fees", "financial", "monthly", "A bank account with no overdraft fees (look for “Bank On” accounts)."],
  ["check_cashing", "Check-cashing fees", "financial", "monthly", "A free checking account with direct deposit."],
  ["payday_loan", "Payday or title loan costs", "financial", "monthly", "Credit-union small loans or interest-free emergency loans; ask your coordinator."],
  ["rent_to_own", "Rent-to-own furniture or appliances", "household", "monthly", "Donated furniture programs, or saving to buy outright."],
  ["no_reserve", "No savings for surprises (costs that pile up)", "financial", "irregular", "A small emergency reserve, built a little at a time (add it as a savings goal)."],
  ["other", "Something else that costs more because money is tight", "household", "monthly", "Talk it over with your coordinator; there may be a cheaper way."],
];
const PREMIUM = Object.fromEntries(PREMIUMS.map((p) => [p[0], p]));
const SKIP_KEY = (lv) => "mm-dn-skip-" + lv;   // per-device convenience: suggestions the person said don't apply
const skipped = (lv) => { try { return JSON.parse(localStorage.getItem(SKIP_KEY(lv)) || "[]"); } catch { return []; } };
const skip = (lv, label) => { try { localStorage.setItem(SKIP_KEY(lv), JSON.stringify([...new Set([...skipped(lv), label])])); } catch { /* blocked */ } };
const LEVEL = {
  current: { title: "What does my life cost today?", short: "Today",
    intro: "The real cost of your life right now, including costs someone else pays or that assistance covers. If a shelter, family or a program covers something, list it and choose who pays." },
  survival: { title: "My Survival Number", short: "Survival",
    intro: "What it costs to keep you safe, fed, clean, connected and alive for one day: a safe place to stay, food and water, hygiene, essential clothing, getting to services, a phone, and essential medicine. The immediate minimum, not a way to live for good." },
  stability: { title: "My Stability Number", short: "Stability",
    intro: "What it costs to keep a reasonably secure, independent life: rent, utilities, food and household supplies, getting around, phone and internet, health care and insurance, clothing and personal care, upkeep, debt payments, savings and an emergency reserve." },
  aspirational: { title: "The life I want", short: "The life I want",
    intro: "Everything in your Stability Number, plus your own goals: learning, recreation, travel, hobbies, family activities, savings and investments, a business, retirement, giving back. This is where your vision becomes something you can plan for." },
};
const PAID_BY = [["self", "I pay it"], ["household", "Someone in my household pays it"], ["subsidy", "A housing subsidy or voucher pays it"],
  ["assistance", "A program, agency or family outside my household pays it"], ["donated", "It's donated or free"]];
const MEMBERS = () => (D && D.plan && D.plan.members) || [];
const memberName = (id) => { const m = MEMBERS().find((x) => x.id === id); return m ? m.label : ""; };
/** A "who in the household" choice (empty = not named). @param {string} id @param {string} cur */
const memberSel = (id, cur) => sel(id, [["", MEMBERS().length ? "Not named" : "No one listed yet (add people on Household)"], ...MEMBERS().map((m) => [m.id, m.label])], cur || "");
const PAID_LABEL = Object.fromEntries(PAID_BY);
const INCOME_KINDS = [["wages", "Wages from a job"], ["self_employment", "My own work or business"], ["cash_benefit", "A cash benefit (SSI, SSDI, W-2, unemployment)"],
  ["pension", "Pension or retirement"], ["family_support", "Money from family or friends"], ["other", "Other cash"]];
const NONCASH_KINDS = [["snap", "SNAP / FoodShare"], ["wic", "WIC"], ["donated_goods", "Donated goods (food, clothes, furniture)"],
  ["donated_services", "Donated services"], ["healthcare_coverage", "Health coverage (Medicaid, BadgerCare)"], ["other", "Other help that isn't cash"]];
const GOAL_KINDS = [["emergency_reserve", "Emergency reserve"], ["savings", "Savings"], ["debt_payoff", "Paying off a debt"], ["retirement", "Retirement"], ["purchase", "Something to buy"], ["other", "Other"]];
const CAT = Object.fromEntries(CATEGORIES.map(([k, t]) => [k, t]));
const FREQ = Object.fromEntries(FREQUENCIES);
const POOR_HELP = "For example buying food in small amounts, convenience-store prices, paying per laundry load, prepaid phone plans, long trips to work, late fees, overdrafts or payday loans.";

const sel = (id, opts, cur, extra = "") => `<select class="mm-select" id="${id}" ${extra}>${opts.map(([v, l]) => `<option value="${esc(v)}"${String(cur ?? "") === v ? " selected" : ""}>${esc(l)}</option>`).join("")}</select>`;
const fmtLine = (l) => `${money(Number(l.amount))} ${(FREQ[l.frequency] || l.frequency).toLowerCase()}${l.frequency === "irregular" ? ` (${Number(l.times_per_year)} times a year)` : ""}${l.frequency === "one_time" && l.spread_months ? ` over ${l.spread_months} months` : ""}${l.start_on ? " from " + shortDate(l.start_on) : ""}${l.end_on ? " until " + shortDate(l.end_on) : ""}`;
/** Today's date used by the numbers (Milwaukee time, from the database). */
const asOf = () => (D && D.results && D.results.as_of) || new Date().toISOString().slice(0, 10);
/** A tag for a line that is not counted today. @param {any} l */
const dateTag = (l) => inEffect(l, asOf()) ? "" : (l.start_on && l.start_on > asOf()
  ? ` <span class="mm-tag mm-tag-info">Starts ${esc(shortDate(l.start_on))}</span>` : ` <span class="mm-tag">Ended ${esc(shortDate(endOn(l) || ""))}</span>`);
/** Per-day cell: the amount, or a dash when the line isn't counted today. @param {any} l */
const perDayCell = (l) => inEffect(l, asOf()) ? money(annualOf(l) / 365) : '<span class="mm-muted" title="Not counted today">—</span>';
/** Optional start and end dates, folded away unless used. @param {string} prefix @param {any} x */
const dateFields = (prefix, x) => `<details class="mm-dates"${x && (x.start_on || x.end_on) ? " open" : ""}><summary>Only for part of the time? Add a start or end date</summary>
  <div class="mm-row" style="margin-top:var(--mm-space-3)">
    <div class="mm-field" style="max-width:14rem"><label for="${prefix}Start">Starts on <span class="mm-muted">(optional)</span></label><input class="mm-input" type="date" id="${prefix}Start" value="${esc(x && x.start_on ? x.start_on : "")}"></div>
    <div class="mm-field" style="max-width:14rem"><label for="${prefix}End">Ends on <span class="mm-muted">(optional)</span></label><input class="mm-input" type="date" id="${prefix}End" value="${esc(x && x.end_on ? x.end_on : "")}"></div></div>
  <p class="mm-hint">The Daily Number counts it only between these dates. Leave them empty for a cost that goes on.</p></details>`;
const LEVEL_KEYS = ["current", "survival", "stability", "aspirational"];
const LEVEL_SHORT = { current: "Today", survival: "Survival", stability: "Stability", aspirational: "The life I want" };
/** Does a resource count toward this number? (no list = all four) @param {any} x @param {string} lv */
const appliesTo = (x, lv) => !x.applies_to || !x.applies_to.length || x.applies_to.includes(lv);
/** "Today and Survival only" (empty when it counts everywhere). @param {any} x */
const appliesText = (x) => !x.applies_to || !x.applies_to.length || x.applies_to.length === 4 ? "" : x.applies_to.map((k) => LEVEL_SHORT[k]).join(", ") + " only";
/** Four checkboxes: which numbers this income or help counts toward. @param {any} x */
const appliesFields = (x) => `<fieldset class="mm-choices" style="margin-bottom:var(--mm-space-4)"><legend class="mm-legend">Counts toward</legend>
  <span class="mm-hint">Untick a number if this won't be there at that level, for example SNAP that would stop with a full-time job, or a job that hasn't started.</span>
  <div class="mm-choices-other">${LEVEL_KEYS.map((k) => `<label class="mm-choice"><input type="checkbox" name="inApplies" value="${k}"${appliesTo(x || {}, k) ? " checked" : ""}> ${esc(LEVEL_SHORT[k])}</label>`).join("")}</div></fieldset>`;
const readApplies = (f) => [...f.querySelectorAll('input[name="inApplies"]:checked')].map((i) => /** @type {HTMLInputElement} */ (i).value);

/** Lines starting or ending within the next 90 days. @param {any[]} rows */
const comingUp = (rows) => rows.filter((l) => (l.start_on && l.start_on > asOf() && daysBetween(asOf(), l.start_on) <= 90) || (endOn(l) && endOn(l) >= asOf() && daysBetween(asOf(), endOn(l) || "") <= 90))
  .map((l) => l.start_on && l.start_on > asOf() ? `${l.label} starts ${shortDate(l.start_on)}` : `${l.label} ends ${shortDate(endOn(l) || "")}`);

let D;          // mirror_dn_get()
let box;        // page container

export async function dailyNumberPage() {
  const page = document.body.dataset.dn || "home";
  await requireArea("my");
  box = /** @type {HTMLElement} */ (document.getElementById("mmDn"));
  await load(page);
}

async function load(page, note = "") {
  try { D = await rpc("mirror_dn_get", {}); }
  catch (e) { box.innerHTML = notice("urgent", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); return; }
  // Wide screens: a row of tabs. Phones (CSS, max-width 36rem): one "Daily Number pages" button that opens the list in two columns,
  // instead of 13 tabs wrapping onto 4-5 rows. Only one of the two is displayed, so a screen reader meets the links once.
  const links = PAGES.map(([k, p, t]) => `<a href="${BASE}${p}"${k === page ? ' aria-current="page"' : ""}>${esc(t)}</a>`).join("");
  const here = (PAGES.find((x) => x[0] === page) || PAGES[0])[2];
  const tabs = `<nav class="mm-dn-tabs" aria-label="Daily Number"><div class="mm-dn-tabrow">${links}</div>
    <details class="mm-dn-menu"><summary>Daily Number pages <span class="mm-dn-here">· ${esc(here)}</span></summary><div class="mm-dn-menu-list">${links}</div></details></nav>`;
  box.innerHTML = tabs + note + '<div id="mmDnBody"></div>';
  const body = /** @type {HTMLElement} */ (box.querySelector("#mmDnBody"));
  if (page === "home") home(body);
  else if (LEVEL[page]) level(body, page);
  else if (page === "income") income(body);
  else if (page === "gap") gap(body);
  else if (page === "plan") plan(body);
  else if (page === "whatif") whatIfPage(body);
  else if (page === "benefits") benefits(body);
  else if (page === "household") household(body);
  else if (page === "history") history(body);
  else if (page === "reflect") reflect(body);
  voiceAll(body);
}
const reload = (page, note = "") => load(page, note ? notice("ok", `<p>${esc(note)}</p>`) : "");
const errBox = (el, e) => { el.innerHTML = notice("urgent", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); };

// ---------------------------------------------------------------- home: the four numbers
function home(body) {
  const R = D.results, L = R.levels;
  const fig = (k, label, hint) => `<a class="mm-card mm-dn-fig" href="${BASE}${PAGES.find((p) => p[0] === k)[1]}">
      <div class="mm-figure-label">${esc(label)}</div>
      <div class="mm-figure">${L[k].lines ? money(L[k].cost.daily) : "—"}</div>
      <p class="mm-muted mm-small" style="margin:0">${L[k].lines ? `a day · ${money(L[k].cost.monthly)} a month · ${money(L[k].cost.annual)} a year` : esc(hint)}</p></a>`;
  const empty = !D.inputs.expenses.length;
  body.innerHTML = `
    <div class="mm-read">
      <h1>My Daily Number</h1>
      <p class="mm-lead">What does one day of your life cost? Every person has a daily cost of living, even with no income. Knowing yours is the first step to meeting it.</p>
      ${empty ? notice("info", `<p>Start with <a href="${BASE}today/">Today</a>: list what your life costs now, a few lines at a time. Use "how often" for each cost; the Mirror turns it into a daily amount.</p>`) : ""}
    </div>
    ${alertsHtml()}
    <div class="mm-grid">
      ${fig("current", "Today", "List what your life costs now.")}
      ${fig("survival", "Survival", "The immediate minimum to stay safe.")}
      ${fig("stability", "Stability", "A secure, independent life.")}
      ${fig("aspirational", "The life I want", "Stability plus your goals.")}
    </div>
    <h2>Today: cost, resources, gap</h2>
    <div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Today's cost, resources and gap</caption>
      <thead><tr><th scope="col">Today</th><th scope="col" class="mm-num">Per day</th><th scope="col" class="mm-num">Per month</th></tr></thead>
      <tbody>
        <tr><td data-label="Today"><strong>What life costs</strong></td><td class="mm-num" data-label="Per day">${money(L.current.cost.daily)}</td><td class="mm-num" data-label="Per month">${money(L.current.cost.monthly)}</td></tr>
        <tr><td data-label="Today"><strong>Resources available</strong></td><td class="mm-num" data-label="Per day">${money(L.current.resources.daily)}</td><td class="mm-num" data-label="Per month">${money(L.current.resources.monthly)}</td></tr>
        <tr><td data-label="Today">&nbsp;&nbsp;Cash income</td><td class="mm-num" data-label="Per day">${money(L.current.income.daily)}</td><td class="mm-num" data-label="Per month">${money(L.current.income.monthly)}</td></tr>
        <tr><td data-label="Today">&nbsp;&nbsp;Help that isn't cash, used for your costs</td><td class="mm-num" data-label="Per day">${money(L.current.noncash_applied.daily)}</td><td class="mm-num" data-label="Per month">${money(L.current.noncash_applied.monthly)}</td></tr>
        <tr><td data-label="Today">&nbsp;&nbsp;Costs paid for you</td><td class="mm-num" data-label="Per day">${money(L.current.paid_by_others.daily)}</td><td class="mm-num" data-label="Per month">${money(L.current.paid_by_others.monthly)}</td></tr>
      </tbody>
      <tfoot><tr><td data-label="Today">Daily gap (still needed)</td><td class="mm-num" data-label="Per day">${money(L.current.shortfall.daily)}</td><td class="mm-num" data-label="Per month">${money(L.current.shortfall.monthly)}</td></tr></tfoot>
    </table></div>
    ${L.current.resources.annual > L.current.cost.annual && L.current.cost.annual > 0 ? notice("ok", `<p>Your resources cover today's costs, with ${money(L.current.resources.daily - L.current.cost.daily)} a day to spare.</p>`) : ""}
    <p class="mm-muted mm-small">These are amounts you spend, not your pay before taxes. See <a href="${BASE}gap/">The gap</a> for what you'd need to earn.</p>
    <p class="mm-small">Next: <a href="${BASE}plan/">How will I generate my Daily Number?</a> · <a href="${BASE}what-if/">What if?</a> · <a href="${BASE}benefits/">Benefits and renewal dates</a> · <a href="${BASE}household/">Who pays what</a></p>
    <form class="mm-card mm-read" id="dnSnap" novalidate>
      <h2 style="margin-top:0">Save today's numbers</h2>
      <p class="mm-muted">Saving keeps today's numbers and what they were made of, with the date, so you can see how they change when your life changes.</p>
      <div class="mm-field"><label for="snapNote">What's happening now? <span class="mm-muted">(optional)</span></label><input class="mm-input" id="snapNote" placeholder="For example: staying with my sister" maxlength="500"></div>
      <div id="snapMsg"></div>
      <button class="mm-btn" type="submit"${empty ? " disabled" : ""}>Save today's numbers</button>
    </form>
    <p class="mm-muted mm-small">These numbers are not standards of human worth. They show different money situations, and the possibilities in each.</p>`;
  body.querySelector("#dnSnap").addEventListener("submit", async (e) => {
    e.preventDefault();
    try { await rpc("mirror_dn_snapshot", { p_note: /** @type {HTMLInputElement} */ (body.querySelector("#snapNote")).value }); reload("home", "Saved. See it under History."); }
    catch (err) { errBox(body.querySelector("#snapMsg"), err); }
  });
}

// ---------------------------------------------------------------- one level: its costs
function level(body, lv) {
  const L = D.results.levels[lv];
  const own = D.inputs.expenses.filter((x) => x.level === lv);
  const fromStability = lv === "aspirational" ? D.inputs.expenses.filter((x) => x.level === "stability") : [];
  const byCat = CATEGORIES.map(([k, t]) => [k, t, own.filter((x) => x.category === k)]).filter(([, , xs]) => xs.length);
  const others = Object.keys(LEVEL).filter((k) => k !== lv && D.inputs.expenses.some((x) => x.level === k));
  body.innerHTML = `
    <div class="mm-read"><h1>${esc(LEVEL[lv].title)}</h1><p class="mm-lead">${esc(LEVEL[lv].intro)}</p></div>
    <div class="mm-grid">
      <div class="mm-card"><div class="mm-figure-label">${esc(LEVEL[lv].short)}: per day</div><div class="mm-figure">${money(L.cost.daily)}</div>
        <p class="mm-muted mm-small" style="margin:0">${money(L.cost.weekly)} a week · ${money(L.cost.monthly)} a month · ${money(L.cost.annual)} a year</p></div>
      <div class="mm-card"><div class="mm-figure-label">You pay in cash</div><div class="mm-figure" style="font-size:2rem">${money(L.cash_expenses.daily)}</div>
        <p class="mm-muted mm-small" style="margin:0">a day. Paid for you: ${money(L.paid_by_others.daily)} a day.${L.noncash_applied.annual ? ` Help that isn't cash covers ${money(L.noncash_applied.daily)} a day.` : ""}</p></div>
    </div>
    ${lv === "aspirational" ? notice("info", `<p>Includes your ${fromStability.length} Stability ${fromStability.length === 1 ? "line" : "lines"} (${money(D.results.levels.stability.cost.daily)} a day). Add only what you'd add on top.</p>`) : ""}
    ${byCat.length ? byCat.map(([k, t, xs]) => `<h2 style="font-size:1.2rem">${esc(t)}</h2>
      <div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">${esc(t)}</caption>
        <thead><tr><th scope="col">Cost</th><th scope="col">How much</th><th scope="col">Who pays</th><th scope="col" class="mm-num">Per day</th><th scope="col"><span class="mm-sr">Change</span></th></tr></thead>
        <tbody>${xs.map((x) => `<tr><td data-label="Cost">${esc(x.label)}${dateTag(x)}${x.poverty_premium ? ' <span class="mm-tag mm-tag-suggested">Could go down</span>' : ""}${x.note ? `<br><span class="mm-muted mm-small">${esc(x.note)}</span>` : ""}</td>
          <td data-label="How much">${esc(fmtLine(x))}</td><td data-label="Who pays">${esc(x.paid_by === "household" && memberName(x.household_member_id) ? memberName(x.household_member_id) + " (household)" : PAID_LABEL[x.paid_by] || x.paid_by)}</td>
          <td class="mm-num" data-label="Per day">${perDayCell(x)}</td>
          <td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-edit="${esc(x.id)}">Change</button></td></tr>`).join("")}</tbody></table></div>`).join("")
      : notice("info", "<p>No costs here yet. Add the first one below.</p>")}
    ${L.goals && L.goals.annual > 0 ? notice("info", `<p><strong>Savings goals: ${money(L.goals.monthly)} a month</strong> (${money(L.goals.daily)} a day) is included above as a cost you pay. Change your goals on <a href="${BASE}income/">Income and support</a>.</p>`) : ""}
    ${comingUp(own).length ? `<h2 style="font-size:1.2rem">Coming up</h2><ul>${comingUp(own).map((t) => `<li>${esc(t)}</li>`).join("")}</ul>` : ""}
    ${suggestPanel(lv, own)}
    ${BENCH_LEVELS.includes(lv) ? '<div id="dnBench"></div>' : ""}
    ${others.length ? `<p class="mm-row"><span class="mm-muted mm-small">Start from another list:</span> ${others.map((k) => `<button class="mm-btn mm-btn-quiet" type="button" data-copy="${k}">Copy from ${esc(LEVEL[k].short)}</button>`).join("")}</p>` : ""}
    <div id="dnForm"></div>`;
  const form = (/** @type {any} */ x) => expenseForm(body.querySelector("#dnForm"), lv, x);
  form(null);
  const benchEl = body.querySelector("#dnBench");
  if (benchEl) benchPanel(/** @type {HTMLElement} */ (benchEl), lv, (x) => { form(x); body.querySelector("#dnForm").scrollIntoView({ block: "start" }); });
  body.querySelectorAll("[data-edit]").forEach((b) => b.addEventListener("click", () => {
    form(D.inputs.expenses.find((x) => x.id === b.dataset.edit)); body.querySelector("#dnForm").scrollIntoView({ block: "start" });
  }));
  body.querySelectorAll("[data-suggest]").forEach((b) => b.addEventListener("click", () => {
    const [cat, label, freq] = SUGGEST[lv][Number(b.dataset.suggest)];
    form({ id: "", category: cat, label, frequency: freq, paid_by: "self" });
    body.querySelector("#dnForm").scrollIntoView({ block: "start" });
    /** @type {HTMLElement|null} */ (body.querySelector("#exAmt"))?.focus();
  }));
  body.querySelectorAll("[data-skip]").forEach((b) => b.addEventListener("click", () => { skip(lv, b.dataset.skip); reload(lv); }));
  body.querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", async () => {
    const from = D.inputs.expenses.filter((x) => x.level === b.dataset.copy);
    if (!b.dataset.sure) { b.dataset.sure = "1"; b.textContent = `Press again to copy ${from.length} lines`; return; }
    b.disabled = true;
    try {
      const r = await rpc("mirror_dn_copy", { p_from: b.dataset.copy, p_to: lv });   // one step: all lines or none
      reload(lv, `Copied ${r.copied} lines. Change any amount to fit this level.`);
    } catch (e) { toast(e instanceof Error ? e.message : String(e)); b.disabled = false; }
  }));
}

function freqFields(prefix, x) {
  return `<div class="mm-field" style="max-width:20rem"><label for="${prefix}Freq">How often</label>${sel(prefix + "Freq", FREQUENCIES, x ? x.frequency : "monthly")}</div>
    <div class="mm-field" id="${prefix}TimesWrap" style="max-width:14rem"><label for="${prefix}Times">How many times a year</label><input class="mm-input" id="${prefix}Times" inputmode="decimal" data-mm-no-voice value="${esc(x && x.times_per_year ? x.times_per_year : "")}"></div>
    <div class="mm-field" id="${prefix}SpreadWrap" style="max-width:14rem"><label for="${prefix}Spread">Spread over how many months</label><span class="mm-hint">Counted as the amount divided by the months, only during those months (from the start date; today if none is given).</span><input class="mm-input" id="${prefix}Spread" inputmode="numeric" data-mm-no-voice value="${esc(x && x.spread_months ? x.spread_months : "12")}"></div>`;
}
function wireFreq(root, prefix, onChange) {
  const f = root.querySelector("#" + prefix + "Freq");
  const sync = () => { root.querySelector("#" + prefix + "TimesWrap").hidden = f.value !== "irregular"; root.querySelector("#" + prefix + "SpreadWrap").hidden = f.value !== "one_time"; onChange && onChange(); };
  f.addEventListener("change", sync); sync();
}
/** Live "that is $X a day" line under a form. */
function liveDaily(root, prefix, out) {
  const calc = () => {
    const amt = Number(String(root.querySelector("#" + prefix + "Amt").value).replace(/[$,]/g, ""));
    const l = { amount: amt, frequency: root.querySelector("#" + prefix + "Freq").value, times_per_year: root.querySelector("#" + prefix + "Times").value, spread_months: root.querySelector("#" + prefix + "Spread").value };
    root.querySelector(out).textContent = amt > 0 ? `That comes to ${money(annualOf(l) / 365)} a day, ${money(annualOf(l) / 12)} a month, ${money(annualOf(l))} a year.` : "";
  };
  root.querySelectorAll("input, select").forEach((i) => i.addEventListener("input", calc)); calc();
  return calc;
}
const v = (root, id) => /** @type {HTMLInputElement} */ (root.querySelector("#" + id)).value;

/** Suggested costs for a list, with the ones already added ticked and "doesn't apply" ones hidden. */
function suggestPanel(lv, own) {
  const have = own.map((x) => String(x.label).toLowerCase());
  const gone = skipped(lv);
  const items = (SUGGEST[lv] || []).map((it, i) => [it, i]).filter(([it]) => !gone.includes(it[1]));
  if (!items.length) return "";
  const done = items.filter(([it]) => have.includes(it[1].toLowerCase())).length;
  return `<details class="mm-card mm-read" style="margin:var(--mm-space-5) 0"${done < items.length ? " open" : ""}>
    <summary style="cursor:pointer;font-weight:700">Checklist: costs most people have here (${done} of ${items.length} added)</summary>
    <p class="mm-hint" style="margin-top:var(--mm-space-3)">Press one to add it; you only type the amount. If it doesn't apply to you, press "Not for me".</p>
    <ul class="mm-checklist">${items.map(([[, label, , hint], i]) => have.includes(label.toLowerCase())
      ? `<li class="mm-done"><span aria-hidden="true">✓</span> ${esc(label)} <span class="mm-muted mm-small">added</span></li>`
      : `<li><button class="mm-btn mm-btn-secondary" type="button" data-suggest="${i}">Add: ${esc(label)}</button>
          <button class="mm-btn mm-btn-quiet" type="button" data-skip="${esc(label)}">Not for me</button>${hint ? `<br><span class="mm-hint">${esc(hint)}</span>` : ""}</li>`).join("")}</ul>
  </details>`;
}

// ---------------------------------------------------------------- Milwaukee prices to compare (database #3, 11/14/2026)
// Published Milwaukee prices for this level (HUD, MIT, USDA, MCTS, We Energies, Milwaukee Water Works, IRS, ALICE ...), from
// mirror_cost_benchmarks(). They never change the person's numbers: "Use this amount" only fills in the form, and they save it.
const BENCH_LEVELS = ["survival", "stability", "aspirational"];
const BENCH_SIZES = [["", "Every household size"], ["1 adult", "1 adult"], ["1 adult + 1 child", "1 adult + 1 child"], ["2 adults", "2 adults"],
  ["2 adults + 2 children", "2 adults + 2 children"], ["larger households", "Larger households"]];
/** @type {any} */ let BENCH = null;
const benchFits = (/** @type {string} */ hh, /** @type {string} */ size) => !size || hh === size || hh.startsWith(size + " (") || /^(all|average) household/.test(hh);
function benchPrice(/** @type {any} */ b) {
  if (b.amount == null) return "";
  const amt = /^dollars(,|$)/.test(b.unit || "dollars") ? money(b.amount) : String(b.amount);
  const unit = b.unit && b.unit !== "dollars" ? " " + b.unit.replace(/^dollars,?\s*/, "").replace(/^per /, "per ") : "";
  const freq = b.frequency && !["per unit"].includes(b.frequency) ? ", " + b.frequency : "";
  return (b.unit && /^share/.test(b.unit) ? (Number(b.amount) * 100).toLocaleString("en-US") + "% " + b.unit.replace(/^share of /, "of ") : amt + unit) + freq;
}
async function benchPanel(/** @type {HTMLElement} */ el, /** @type {string} */ lv, /** @type {(x: any) => void} */ use) {
  if (!BENCH) { try { BENCH = await rpc("mirror_cost_benchmarks", {}); } catch { el.innerHTML = ""; return; } }
  const all = BENCH.rows.filter((/** @type {any} */ b) => b.level === lv && (BENCH.office || b.amount != null));
  if (!all.length) { el.innerHTML = ""; return; }
  const n = Number(D.household_size) || 0;
  let size = n === 1 ? "1 adult" : "";
  let cat = "";
  const render = () => {
    const rows = all.filter((/** @type {any} */ b) => benchFits(String(b.household), size) && (!cat || b.category === cat));
    const cats = CATEGORIES.filter(([k]) => all.some((/** @type {any} */ b) => b.category === k));
    const src = (/** @type {string[]} */ ids) => ids.map((s) => BENCH.sources[s]).filter(Boolean)
      .map((s) => s.url ? `<a href="${esc(s.url)}" rel="noopener" target="_blank">${esc(s.title)}</a>` : esc(s.title)).join("; ");
    el.querySelector("#bnRows").innerHTML = rows.length ? `<div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Milwaukee prices</caption>
      <thead><tr><th scope="col">Cost</th><th scope="col">Price as published</th><th scope="col" class="mm-num">A month</th><th scope="col" class="mm-num">A day</th><th scope="col"><span class="mm-sr">Use</span></th></tr></thead>
      <tbody>${rows.map((/** @type {any} */ b) => `<tr><td data-label="Cost"><strong>${esc(b.label)}</strong> <span class="mm-muted mm-small">(${esc(b.household)})</span>
          ${b.status === "Verified - Limited" ? ' <span class="mm-tag mm-tag-info">Older or partial source</span>' : ""}${!/^Verified/.test(b.status) ? ` <span class="mm-tag mm-tag-suggested">${esc(b.status)} (office only)</span>` : ""}
          ${b.poverty_premium ? ' <span class="mm-tag mm-tag-suggested">Costs more when money is tight</span>' : ""}
          <br><span class="mm-muted mm-small">${esc(b.item.replace(/\s+DERIVED$/, ""))}${b.as_of ? ` · as of ${esc(b.as_of)}` : ""}${b.geography ? ` · ${esc(b.geography)}` : ""}</span>
          ${b.cheaper ? `<br><span class="mm-small">Cheaper way: ${esc(b.cheaper)}</span>` : ""}
          ${b.sources.length ? `<br><span class="mm-small">Source: ${src(b.sources)}</span>` : ""}</td>
        <td data-label="Price as published">${esc(benchPrice(b)) || '<span class="mm-muted">Not published</span>'}</td>
        <td class="mm-num" data-label="A month">${b.per_month != null ? money(b.per_month) : b.one_time != null ? esc(money(b.one_time) + " once") : "—"}</td>
        <td class="mm-num" data-label="A day">${b.per_day != null ? money(b.per_day) : "—"}</td>
        <td data-label="">${b.per_month != null || b.one_time != null ? `<button class="mm-btn mm-btn-quiet" type="button" data-bench="${esc(b.id)}">Use this amount</button>` : ""}</td></tr>`).join("")}</tbody></table></div>`
      : '<p class="mm-muted">No published price for this household size here. Choose "Every household size" to see them all.</p>';
    el.querySelector("#bnCatWrap").innerHTML = `<label for="bnCat">Kind of cost</label>${sel("bnCat", [["", "All kinds"], ...cats.map(([k, t]) => [k, t])], cat)}`;
    el.querySelector("#bnCat").addEventListener("change", (e) => { cat = /** @type {HTMLSelectElement} */ (e.target).value; render(); });
    el.querySelectorAll("[data-bench]").forEach((btn) => btn.addEventListener("click", () => {
      const b = all.find((/** @type {any} */ x) => x.id === /** @type {HTMLElement} */ (btn).dataset.bench);
      const once = b.per_month == null;
      use({ id: "", category: b.category, label: b.label.slice(0, 120), amount: once ? b.one_time : Math.round(b.per_month * 100) / 100,
        frequency: once ? "one_time" : "monthly", paid_by: "self", note: `Milwaukee price ${b.id} (${b.household}), as of ${b.as_of || "date not given"}. Change it to what you really pay.`.slice(0, 500) });
    }));
  };
  el.innerHTML = `<details class="mm-card" style="margin:var(--mm-space-5) 0">
    <summary style="cursor:pointer;font-weight:700">Milwaukee prices to compare (${all.length})</summary>
    <p class="mm-hint" style="margin-top:var(--mm-space-3)">What these costs are in Milwaukee, from published sources (HUD, MIT, USDA, MCTS, We Energies, the City and others), for ${esc(LEVEL[lv].short)}. They are only for comparing: your own numbers stay yours. "Use this amount" fills in the form below; change it to what you really pay, then save.</p>
    <p class="mm-hint"><strong>Rent already includes utilities</strong> in the HUD rents (they are gross rents). Add a utility only if you pay that bill yourself.</p>
    <div class="mm-row" style="align-items:flex-end;gap:var(--mm-space-4)">
      <div class="mm-field" style="max-width:18rem"><label for="bnSize">Household</label>${sel("bnSize", BENCH_SIZES, size)}</div>
      <div class="mm-field" style="max-width:18rem" id="bnCatWrap"></div></div>
    <div id="bnRows"></div>
    ${BENCH.office && BENCH.conflicts.length ? `<p class="mm-hint">Office note: ${BENCH.conflicts.length} sources disagree on a figure (${esc([...new Set(BENCH.conflicts.map((/** @type {any} */ c) => c.benchmark_id))].join(", "))}); the figure in effect is shown. Benchmarks ${esc(BENCH.version || "")}.</p>` : ""}
  </details>`;
  el.querySelector("#bnSize").addEventListener("change", (e) => { size = /** @type {HTMLSelectElement} */ (e.target).value; render(); });
  render();
}

function expenseForm(el, lv, x, after = lv) {
  const editing = !!(x && x.id);
  el.innerHTML = `<form class="mm-card mm-read" id="exForm" novalidate>
    <h2 style="margin-top:0">${editing ? "Change this cost" : "Add a cost"}</h2>
    <div class="mm-field"><label for="exCat">Category</label>${sel("exCat", CATEGORIES.map(([k, t, ex]) => [k, `${t} (${ex})`]), x ? x.category : "housing")}</div>
    <div class="mm-field"><label for="exLabel">What is it?</label><input class="mm-input" id="exLabel" maxlength="120" value="${esc(x ? x.label : "")}" placeholder="For example: Rent, bus pass, laundromat"></div>
    <div class="mm-field" style="max-width:14rem"><label for="exAmt">Amount</label><div class="mm-money"><span aria-hidden="true">$</span><input class="mm-input" id="exAmt" inputmode="decimal" data-mm-no-voice value="${esc(x ? x.amount : "")}"></div></div>
    ${freqFields("ex", x)}
    <p class="mm-hint" id="exDaily" aria-live="polite"></p>
    ${dateFields("ex", x)}
    <div class="mm-field"><label for="exPaid">Who pays it?</label>${sel("exPaid", PAID_BY, x ? x.paid_by : "self")}</div>
    <div class="mm-field" id="exMemberWrap"><label for="exMember">Who in your household?</label>${memberSel("exMember", x ? x.household_member_id : "")}</div>
    <div class="mm-field"><label for="exPoorKind">Does this cost more because money is tight?</label>
      <span class="mm-hint">People with little money often pay more for the same things. Marking it shows a cheaper way on "The gap".</span>
      ${sel("exPoorKind", [["", "No"], ...PREMIUMS.map((p) => [p[0], p[1]])], x ? (x.premium_kind || (x.poverty_premium ? "other" : "")) : "")}</div>
    <div class="mm-field"><label for="exNote">Note <span class="mm-muted">(optional)</span></label><input class="mm-input" id="exNote" maxlength="500" value="${esc(x && x.note ? x.note : "")}"></div>
    <div id="exMsg" aria-live="assertive"></div>
    <div class="mm-row"><button class="mm-btn" type="submit">${editing ? "Save the change" : "Add this cost"}</button>
      ${x ? '<button class="mm-btn mm-btn-secondary" type="button" id="exCancel">Cancel</button>' : ""}${editing ? '<button class="mm-btn mm-btn-quiet" type="button" id="exDel">Remove</button>' : ""}</div>
  </form>`;
  const f = el.querySelector("#exForm");
  const calc = liveDaily(f, "ex", "#exDaily");
  wireFreq(f, "ex", calc);
  const paid = /** @type {HTMLSelectElement} */ (f.querySelector("#exPaid"));
  const syncPaid = () => { /** @type {HTMLElement} */ (f.querySelector("#exMemberWrap")).hidden = paid.value !== "household"; };
  paid.addEventListener("change", syncPaid); syncPaid();
  voiceAll(f);
  f.querySelector("#exCancel")?.addEventListener("click", () => expenseForm(el, lv, null, after));
  f.querySelector("#exDel")?.addEventListener("click", async (e) => {
    const b = /** @type {HTMLButtonElement} */ (e.target);
    if (!b.dataset.sure) { b.dataset.sure = "1"; b.textContent = "Press again to remove"; return; }
    try { await rpc("mirror_dn_delete", { p_kind: "expense", p_id: x.id }); reload(after, "Removed."); } catch (err) { errBox(f.querySelector("#exMsg"), err); }
  });
  f.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await rpc("mirror_dn_save", { p_kind: "expense", p: { id: editing ? x.id : "", level: lv, category: v(f, "exCat"), label: v(f, "exLabel"), amount: v(f, "exAmt"),
        frequency: v(f, "exFreq"), times_per_year: v(f, "exTimes"), spread_months: v(f, "exSpread"), paid_by: v(f, "exPaid"), household_member_id: v(f, "exMember"),
        premium_kind: v(f, "exPoorKind"), poverty_premium: !!v(f, "exPoorKind"), note: v(f, "exNote"),
        start_on: v(f, "exStart") || (v(f, "exFreq") === "one_time" ? asOf() : ""), end_on: v(f, "exEnd") } });
      reload(after, editing ? "Saved." : "Added.");
    } catch (err) { errBox(f.querySelector("#exMsg"), err); }
  });
}

// ---------------------------------------------------------------- income, help that isn't cash, goals, settings
function income(body) {
  const I = D.inputs, R = D.results;
  const list = (kind, rows, labelOf) => rows.length ? `<div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">${esc(kind)}</caption>
      <thead><tr><th scope="col">What</th><th scope="col">How much</th><th scope="col" class="mm-num">Per day</th><th scope="col"><span class="mm-sr">Change</span></th></tr></thead>
      <tbody>${rows.map((x) => `<tr><td data-label="What">${esc(x.label)}${dateTag(x)}<br><span class="mm-muted mm-small">${esc(labelOf(x))}</span></td><td data-label="How much">${esc(fmtLine(x))}</td>
        <td class="mm-num" data-label="Per day">${perDayCell(x)}</td><td data-label=""><button class="mm-btn mm-btn-quiet" type="button" data-${kind}="${esc(x.id)}">Change</button></td></tr>`).join("")}</tbody></table></div>`
    : `<p class="mm-muted">None yet.</p>`;
  const IK = Object.fromEntries(INCOME_KINDS), NK = Object.fromEntries(NONCASH_KINDS), GK = Object.fromEntries(GOAL_KINDS);
  body.innerHTML = `
    <div class="mm-read"><h1>Income and support</h1>
      <p class="mm-lead">Cash income, help that isn't cash, and savings are kept apart: SNAP or donated food lowers what food costs you, but it isn't income.
        You don't have to earn every dollar of your Daily Number; affordable housing, coverage, benefits and community help all lower the cash you need.</p></div>
    <h2>Cash income <span class="mm-muted" style="font-size:1rem">${money(R.income.daily)} a day · ${money(R.income.monthly)} a month</span></h2>
    <p class="mm-muted mm-small">Use what you actually receive (take-home), not pay before taxes.</p>
    ${list("income", I.income, (x) => [IK[x.kind] || x.kind, isTaxable(x) ? "taxed" : "not taxed", appliesText(x)].filter(Boolean).join(" · "))}
    <div id="incForm"></div>
    <h2>Help that isn't cash <span class="mm-muted" style="font-size:1rem">${money(R.noncash.daily)} a day</span></h2>
    <p class="mm-muted mm-small">Each kind of help only lowers costs in its own category (SNAP lowers food, not rent).</p>
    ${list("noncash", I.noncash, (x) => [(NK[x.kind] || x.kind) + " · covers " + (CAT[x.category] || x.category), appliesText(x)].filter(Boolean).join(" · "))}
    <div id="ncForm"></div>
    <h2>Savings and goals</h2>
    ${D.goals.length ? D.goals.map((g) => `<div class="mm-card" style="margin-bottom:var(--mm-space-3)"><div class="mm-row" style="justify-content:space-between">
        <div><strong>${esc(g.label)}</strong> <span class="mm-muted mm-small">${esc(GK[g.kind] || g.kind)}${g.target_date ? " · by " + esc(new Date(g.target_date + "T12:00:00").toLocaleDateString("en-US", { month: "short", year: "numeric" })) : ""}</span></div>
        <button class="mm-btn mm-btn-quiet" type="button" data-goal="${esc(g.id)}">Change</button></div>
        ${g.target_amount ? countBar(Math.round(Number(g.current_amount)), Math.round(Number(g.target_amount)), "dollars saved") : `<p class="mm-small">${money(Number(g.current_amount))} saved</p>`}
        <p class="mm-small" style="margin:0">${goalText(g)}</p></div>`).join("") : `<p class="mm-muted">None yet: an emergency reserve is a good first one.</p>`}
    <div id="goalForm"></div>
    <h2>About taxes and your household</h2>
    <form class="mm-card mm-read" id="setForm" novalidate>
      <div class="mm-field" style="max-width:14rem"><label for="setTax">Tax rate on taxed income (%)</label>
        <span class="mm-hint">Used for "income needed before taxes". Untaxed income (SSI, gifts) is left out of it. Nothing is assumed.</span>
        <input class="mm-input" id="setTax" inputmode="decimal" data-mm-no-voice value="${esc(D.results.tax_rate_pct || 0)}"></div>
      <p class="mm-small"><button class="mm-btn mm-btn-quiet" type="button" id="setRough" style="padding:0;min-height:auto">Not sure? Use a rough estimate</button></p>
      <p class="mm-hint" id="setRoughText" aria-live="polite"></p>
      <p class="mm-hint">For a real figure, free tax help (VITA) is available every year: call 2-1-1 to find a site near you.</p>
      <div class="mm-field" style="max-width:14rem"><label for="setHh">People in your household <span class="mm-muted">(optional)</span></label>
        <input class="mm-input" id="setHh" inputmode="numeric" data-mm-no-voice value="${esc(D.household_size || "")}"></div>
      <div id="setMsg"></div><button class="mm-btn" type="submit">Save</button></form>`;
  const incomeForm = (x) => simpleForm(body.querySelector("#incForm"), "income", x, "Add cash income",
    `${sel("inKind", INCOME_KINDS, x ? x.kind : "wages")}
    <div class="mm-field" style="margin-top:var(--mm-space-3)"><label for="inTax">Is this income taxed?</label>
      <span class="mm-hint">Pay from a job, your own work and most pensions are taxed. SSI, gifts from family and most other help are not. Not sure? Leave "The usual way".</span>
      ${sel("inTax", [["", "The usual way for this kind"], ["true", "Yes, it is taxed"], ["false", "No, it isn't taxed"]], x && x.taxable !== null && x.taxable !== undefined ? String(x.taxable) : "")}</div>
    <div class="mm-field" style="margin-top:var(--mm-space-3)"><label for="inMember">From someone in your household? <span class="mm-muted">(optional)</span></label>${memberSel("inMember", x ? x.household_member_id : "")}</div>`,
    (f) => ({ kind: v(f, "inKind"), taxable: v(f, "inTax"), household_member_id: v(f, "inMember") }));
  const ncForm = (x) => simpleForm(body.querySelector("#ncForm"), "noncash", x, "Add help that isn't cash",
    `${sel("inKind", NONCASH_KINDS, x ? x.kind : "snap")}<div class="mm-field" style="margin-top:var(--mm-space-3)"><label for="inCat">Which cost does it lower?</label>${sel("inCat", CATEGORIES.map(([k, t]) => [k, t]), x ? x.category : "food")}</div>`,
    (f) => ({ kind: v(f, "inKind"), category: v(f, "inCat") }), "Estimated value");
  incomeForm(null); ncForm(null); goalForm(body.querySelector("#goalForm"), null);
  body.querySelectorAll("[data-income]").forEach((b) => b.addEventListener("click", () => incomeForm(I.income.find((x) => x.id === b.dataset.income))));
  body.querySelectorAll("[data-noncash]").forEach((b) => b.addEventListener("click", () => ncForm(I.noncash.find((x) => x.id === b.dataset.noncash))));
  body.querySelectorAll("[data-goal]").forEach((b) => b.addEventListener("click", () => goalForm(body.querySelector("#goalForm"), D.goals.find((g) => g.id === b.dataset.goal))));
  body.querySelector("#setRough").addEventListener("click", () => {
    // rough guide from the taxed income in the Stability number (or today's when Stability has none)
    const taxed = (lv) => I.income.filter((x) => inEffect(x, asOf()) && appliesTo(x, lv) && isTaxable(x)).reduce((sum, x) => sum + annualOf(x) / 12, 0);
    const monthly = taxed("stability") || taxed("current");
    const rate = roughTaxRate(monthly);
    /** @type {HTMLInputElement} */ (body.querySelector("#setTax")).value = String(rate);
    body.querySelector("#setRoughText").textContent = `Rough estimate: ${rate}% for about ${money(monthly)} a month of taxed income (Social Security and Medicare take 7.65% of pay, plus some income tax). Press Save to use it.`;
  });
  body.querySelector("#setForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    try { await rpc("mirror_dn_save", { p_kind: "settings", p: { tax_rate_pct: v(body, "setTax"), household_size: v(body, "setHh") } }); reload("income", "Saved."); }
    catch (err) { errBox(body.querySelector("#setMsg"), err); }
  });
}

function simpleForm(el, kind, x, title, kindHtml, extra, amountLabel = "Amount") {
  el.innerHTML = `<form class="mm-card mm-read" novalidate>
    <h3 style="margin-top:0">${x ? "Change" : esc(title)}</h3>
    <div class="mm-field"><label for="inKind">Kind</label>${kindHtml}</div>
    <div class="mm-field"><label for="inLabel">Name</label><input class="mm-input" id="inLabel" maxlength="120" value="${esc(x ? x.label : "")}"></div>
    <div class="mm-field" style="max-width:14rem"><label for="inAmt">${esc(amountLabel)}</label><div class="mm-money"><span aria-hidden="true">$</span><input class="mm-input" id="inAmt" inputmode="decimal" data-mm-no-voice value="${esc(x ? x.amount : "")}"></div></div>
    ${freqFields("in", x)}
    <p class="mm-hint" id="inDaily" aria-live="polite"></p>
    ${appliesFields(x)}
    ${dateFields("in", x)}
    <div id="inMsg" aria-live="assertive"></div>
    <div class="mm-row"><button class="mm-btn" type="submit">${x ? "Save the change" : "Add"}</button>
      ${x ? '<button class="mm-btn mm-btn-secondary" type="button" data-cancel>Cancel</button><button class="mm-btn mm-btn-quiet" type="button" data-del>Remove</button>' : ""}</div></form>`;
  const f = el.querySelector("form");
  const calc = liveDaily(f, "in", "#inDaily");
  wireFreq(f, "in", calc);
  voiceAll(f);
  f.querySelector("[data-cancel]")?.addEventListener("click", () => reload("income"));
  f.querySelector("[data-del]")?.addEventListener("click", async (e) => {
    const b = /** @type {HTMLButtonElement} */ (e.target);
    if (!b.dataset.sure) { b.dataset.sure = "1"; b.textContent = "Press again to remove"; return; }
    try { await rpc("mirror_dn_delete", { p_kind: kind, p_id: x.id }); reload("income", "Removed."); } catch (err) { errBox(f.querySelector("#inMsg"), err); }
  });
  f.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await rpc("mirror_dn_save", { p_kind: kind, p: { id: x ? x.id : "", label: v(f, "inLabel"), amount: v(f, "inAmt"), frequency: v(f, "inFreq"),
        times_per_year: v(f, "inTimes"), spread_months: v(f, "inSpread"), start_on: v(f, "inStart") || (v(f, "inFreq") === "one_time" ? asOf() : ""), end_on: v(f, "inEnd"), applies_to: readApplies(f), ...extra(f) } });
      reload("income", x ? "Saved." : "Added.");
    } catch (err) { errBox(f.querySelector("#inMsg"), err); }
  });
}

/** What a goal means for the Daily Number. @param {any} g */
function goalText(g) {
  const where = g.level === "aspirational" ? "The life I want" : "Stability";
  if ((Number(g.target_amount) || 0) <= (Number(g.current_amount) || 0) && g.target_amount) return "Reached. Well done.";
  if (g.level === "none") return "Not counted in your Daily Number.";
  if (!g.target_amount || !g.target_date) return "Add a goal amount and a date, and the Mirror works out what to save each month.";
  const m = goalMonthly(g, asOf());
  if (m <= 0) return "The date has passed. Choose a new date to plan again.";
  return `Saving ${esc(money(m))} a month until ${esc(shortDate(g.target_date))}, counted in ${where}.`;
}

function goalForm(el, g) {
  el.innerHTML = `<form class="mm-card mm-read" novalidate>
    <h3 style="margin-top:0">${g ? "Change this goal" : "Add a savings goal"}</h3>
    <div class="mm-field"><label for="gKind">Kind</label>${sel("gKind", GOAL_KINDS, g ? g.kind : "emergency_reserve")}</div>
    <div class="mm-field"><label for="gLabel">Name</label><input class="mm-input" id="gLabel" maxlength="120" value="${esc(g ? g.label : "")}" placeholder="For example: Emergency fund"></div>
    <div class="mm-field"><label for="gLevel">Count the monthly saving in</label>
      <span class="mm-hint">With an amount and a date, the Mirror works out what to save each month and adds it to that number.</span>
      ${sel("gLevel", [["stability", "My Stability Number"], ["aspirational", "The life I want"], ["none", "Don't count it"]], g ? g.level : "stability")}</div>
    <div class="mm-row">
      <div class="mm-field" style="max-width:12rem"><label for="gTarget">Goal ($)</label><input class="mm-input" id="gTarget" inputmode="decimal" data-mm-no-voice value="${esc(g && g.target_amount ? g.target_amount : "")}"></div>
      <div class="mm-field" style="max-width:12rem"><label for="gNow">Saved so far ($)</label><input class="mm-input" id="gNow" inputmode="decimal" data-mm-no-voice value="${esc(g ? g.current_amount : "0")}"></div>
      <div class="mm-field" style="max-width:14rem"><label for="gDate">By when <span class="mm-muted">(optional)</span></label><input class="mm-input" type="date" id="gDate" value="${esc(g && g.target_date ? g.target_date : "")}"></div></div>
    <div id="gMsg" aria-live="assertive"></div>
    <div class="mm-row"><button class="mm-btn" type="submit">${g ? "Save the change" : "Add goal"}</button>
      ${g ? '<button class="mm-btn mm-btn-quiet" type="button" data-del>Remove</button>' : ""}</div></form>`;
  const f = el.querySelector("form");
  f.querySelector("[data-del]")?.addEventListener("click", async (e) => {
    const b = /** @type {HTMLButtonElement} */ (e.target);
    if (!b.dataset.sure) { b.dataset.sure = "1"; b.textContent = "Press again to remove"; return; }
    try { await rpc("mirror_dn_delete", { p_kind: "goal", p_id: g.id }); reload("income", "Removed."); } catch (err) { errBox(f.querySelector("#gMsg"), err); }
  });
  f.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await rpc("mirror_dn_save", { p_kind: "goal", p: { id: g ? g.id : "", kind: v(f, "gKind"), label: v(f, "gLabel"), level: v(f, "gLevel"), target_amount: v(f, "gTarget").replace(/[$,]/g, ""),
        current_amount: v(f, "gNow").replace(/[$,]/g, ""), target_date: v(f, "gDate") } });
      reload("income", g ? "Saved." : "Added.");
    } catch (err) { errBox(f.querySelector("#gMsg"), err); }
  });
}

// ---------------------------------------------------------------- the gap
function gap(body) {
  const R = D.results, L = R.levels;
  const row = (k, label) => `<tr><td data-label="Level"><strong>${esc(label)}</strong></td>
    <td class="mm-num" data-label="Costs a day">${money(L[k].cost.daily)}</td>
    <td class="mm-num" data-label="Resources a day">${money(L[k].resources.daily)}</td>
    <td class="mm-num" data-label="Short a day">${money(L[k].shortfall.daily)}</td>
    <td class="mm-num" data-label="Short a month">${money(L[k].shortfall.monthly)}</td>
    <td class="mm-num" data-label="Taxed income needed, a month">${money(L[k].gross_needed.monthly)}</td></tr>`;
  // Benefits that count today but not higher up, and benefits still counted higher up although earnings rise there.
  const BENEFIT_NONCASH = ["snap", "wic", "healthcare_coverage"];
  const live = (x) => inEffect(x, asOf());
  const benefits = [...D.inputs.income.filter((x) => live(x) && x.kind === "cash_benefit"), ...D.inputs.noncash.filter((x) => live(x) && BENEFIT_NONCASH.includes(x.kind))];
  const earned = (lv) => D.inputs.income.filter((x) => live(x) && appliesTo(x, lv) && ["wages", "self_employment"].includes(x.kind)).reduce((sum, x) => sum + annualOf(x), 0);
  const dropped = benefits.filter((x) => appliesTo(x, "current") && (!appliesTo(x, "stability") || !appliesTo(x, "aspirational")));
  const atRisk = ["stability", "aspirational"].filter((lv) => earned(lv) > earned("current")).flatMap((lv) => benefits.filter((x) => appliesTo(x, lv)).map((x) => [lv, x]));
  const riskNames = [...new Set(atRisk.map(([, x]) => x.label))];
  const poor = D.inputs.expenses.filter((x) => x.poverty_premium);
  body.innerHTML = `
    <div class="mm-read"><h1>The gap</h1>
      <p class="mm-lead">For each level: what life costs, the resources you'd have, what's still missing, and the taxed income that would cover it.</p></div>
    <div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">The gap at each level</caption>
      <thead><tr><th scope="col">Level</th><th scope="col" class="mm-num">Costs a day</th><th scope="col" class="mm-num">Resources a day</th>
        <th scope="col" class="mm-num">Short a day</th><th scope="col" class="mm-num">Short a month</th><th scope="col" class="mm-num">Taxed income needed, a month</th></tr></thead>
      <tbody>${row("current", "Today")}${row("survival", "Survival")}${row("stability", "Stability")}${row("aspirational", "The life I want")}</tbody></table></div>
    <p class="mm-muted mm-small">Resources = cash income + help that isn't cash used for your costs + costs paid for you. "Taxed income needed" is what you'd need to earn
      before taxes (at the ${esc(R.tax_rate_pct)}% you entered on <a href="${BASE}income/">Income and support</a>) to pay your cash costs, after your untaxed income.</p>
    ${dropped.length ? notice("info", `<p>Not counted at every level: ${dropped.map((x) => `<strong>${esc(x.label)}</strong> (${esc(appliesText(x) || "")})`).join(", ")}. The gap at those levels already leaves them out.</p>`) : ""}
    ${riskNames.length ? notice("caution", `<p><strong>Benefits can go down as earnings go up.</strong> Your Stability or The life I want numbers include more earned income than today,
      and still count ${riskNames.map((n) => "<strong>" + esc(n) + "</strong>").join(", ")}. SNAP, SSI, BadgerCare and similar help often shrink or stop when pay rises.
      Ask your coordinator whether they will continue, and untick those levels on <a href="${BASE}income/">Income and support</a> if not.</p>`) : ""}
    <h2>Costs that could go down</h2>
    <p>People with little money often pay more for the same things. As life gets more stable, these costs can shrink.</p>
    ${poor.length ? `<p><strong>${money(L.current.poverty_premium.daily)} a day</strong> (${money(L.current.poverty_premium.monthly)} a month) of today's costs are marked as costs that could go down:</p>
      <ul class="mm-cheaper">${poor.map((x) => `<li><strong>${esc(x.label)}</strong> (${esc(LEVEL[x.level].short)}): ${esc(fmtLine(x))}
        <br><span class="mm-small">A cheaper way: ${esc((PREMIUM[x.premium_kind || "other"] || PREMIUM.other)[4])}</span></li>`).join("")}</ul>`
      : notice("info", "<p>None marked yet. Do any of these sound like you? Press one to add it to Today.</p>")}
    <details class="mm-card mm-read" style="margin-top:var(--mm-space-4)"${poor.length ? "" : " open"}><summary style="cursor:pointer;font-weight:700">Common costs of being poor</summary>
      <ul class="mm-checklist" style="margin-top:var(--mm-space-3)">${PREMIUMS.filter((p) => p[0] !== "other").map((p) => `<li><button class="mm-btn mm-btn-secondary" type="button" data-premium="${p[0]}">Add: ${esc(p[1])}</button>
        <br><span class="mm-hint">A cheaper way: ${esc(p[4])}</span></li>`).join("")}</ul></details>
    <div id="dnForm"></div>`;
  body.querySelectorAll("[data-premium]").forEach((b) => b.addEventListener("click", () => {
    const p = PREMIUM[b.dataset.premium];
    expenseForm(body.querySelector("#dnForm"), "current", { id: "", category: p[2], label: p[1], frequency: p[3], times_per_year: p[3] === "irregular" ? 4 : null, paid_by: "self", premium_kind: p[0] }, "gap");
    body.querySelector("#dnForm").scrollIntoView({ block: "start" });
    /** @type {HTMLElement|null} */ (body.querySelector("#exAmt"))?.focus();
  }));
}

// ---------------------------------------------------------------- history: saved numbers and what changed
async function history(body) {
  body.innerHTML = `<div class="mm-read"><h1>How my Daily Number has changed</h1><p class="mm-lead">Each save keeps the date, the numbers and what they were made of.
    The Mirror also saves on its own: the first time you change something on a new day, it first keeps your numbers as they were. Moving, a new job, a car, or health coverage can all change them.</p></div>
    <div id="helpChanges"></div><div id="hist"><p role="status">Loading…</p></div>`;
  helperChanges(/** @type {HTMLElement} */ (body.querySelector("#helpChanges")));
  let H;
  try { H = await rpc("mirror_dn_history", {}); } catch (e) { errBox(body.querySelector("#hist"), e); return; }
  const el = /** @type {HTMLElement} */ (body.querySelector("#hist"));
  if (!H.length) { el.innerHTML = notice("info", `<p>Nothing saved yet. Press "Save today's numbers" on <a href="${BASE}">My Daily Number</a>.</p>`); return; }
  const L = (s) => s.results.levels || {};
  const day = (s, k) => (L(s)[k] && L(s)[k].cost ? L(s)[k].cost.daily : 0);
  el.innerHTML = (H.length >= 2 ? chart([...H].reverse()) : "") + H.map((snap, i) => {
    const older = H[i + 1];
    const diff = older ? changes(snap, older) : [];
    const gap = L(snap).current && L(snap).current.shortfall ? L(snap).current.shortfall.daily : 0;
    return `<div class="mm-card" style="margin-bottom:var(--mm-space-4)">
      <h2 style="margin-top:0;font-size:1.2rem">${esc(new Date(snap.taken_at).toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }))}${snap.note ? ` · ${esc(snap.note)}` : ""}</h2>
      <p>Today ${money(day(snap, "current"))} a day · Survival ${money(day(snap, "survival"))} · Stability ${money(day(snap, "stability"))} · The life I want ${money(day(snap, "aspirational"))} · Daily gap ${money(gap)}</p>
      ${older ? (diff.length ? `<p class="mm-small"><strong>What changed since ${esc(new Date(older.taken_at).toLocaleDateString("en-US", { month: "short", day: "numeric" }))}:</strong></p><ul class="mm-small">${diff.map((d) => `<li>${esc(d)}</li>`).join("")}</ul>` : '<p class="mm-muted mm-small">No changes from the save before.</p>') : '<p class="mm-muted mm-small">First save.</p>'}
    </div>`;
  }).join("");
  wireChart(el);
}

// ---------------------------------------------------------------- changes made by someone helping the person (mirror_dn_changes, step 5)
const CH_LIST = { living_expenses: "Cost", income_sources: "Income", noncash_resources: "Help that isn't cash", financial_goals: "Savings goal",
  daily_number_settings: "Settings", household_members: "Household", benefit_records: "Benefit", income_opportunities: "Plan item" };
const CH_FIELD = { label: "Name", amount: "Amount", frequency: "How often", level: "List", category: "Kind of cost", paid_by: "Who pays", start_on: "Starts",
  end_on: "Ends", note: "Note", times_per_year: "Times a year", spread_months: "Spread over (months)", poverty_premium: "Could go down", premium_kind: "Could go down (kind)",
  active: "Counted", applies_to: "Counts toward", taxable: "Taxed", kind: "Kind", household_member_id: "Household member", tax_rate_pct: "Tax rate",
  household_size: "Household size", program: "Program", agency: "Agency", status: "Where it stands", applied_on: "Applied", approved_on: "Approved", renewal_on: "Renewal due",
  appeal_by: "Appeal by", ends_on: "Ends", income_source_id: "Linked income line", noncash_id: "Linked help line", expense_id: "Linked cost line", relationship: "Relationship",
  lives_with: "Lives with me", target_amount: "Goal amount", current_amount: "Saved so far", target_date: "Goal date", amount_is_gross: "Amount is before taxes",
  expected_on: "Could start", next_step: "Next step" };
const CH_MONEY = ["amount", "target_amount", "current_amount"];
/** One value as words. @param {string} field @param {any} v */
function chValue(field, v) {
  if (v === null || v === undefined || v === "") return "(empty)";
  if (v === "true") return "Yes";
  if (v === "false") return "No";
  if (CH_MONEY.includes(field)) return money(Number(v));
  if (field === "tax_rate_pct") return Number(v) + "%";
  if (field === "household_member_id") return memberName(v) || "(someone since removed)";
  if (/_id$/.test(field)) return "a line on your lists";
  if (field === "level") return (LEVEL[v] || { short: v }).short;
  if (/_on$|_date$/.test(field) && /^\d{4}-\d\d-\d\d$/.test(v)) return shortDate(v);
  return String(v).replace(/_/g, " ").replace(/[{}"[\]]/g, "");
}
/** An added or removed line in one phrase: its amount and how often, when it has them. @param {string} json */
function chRow(json) {
  try { const r = JSON.parse(json || "{}"); return r.amount !== undefined ? `${money(Number(r.amount))}${r.frequency ? " " + String(r.frequency).replace(/_/g, " ") : ""}` : ""; }
  catch { return ""; }
}
async function helperChanges(el) {
  let C;
  try { C = await rpc("mirror_dn_changes", {}); } catch { return; }   // the snapshots below still show; this list is extra
  if (!C.length) return;
  const when = (t) => new Date(t).toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
  const what = (c) => c.action === "changed" ? `${esc(CH_FIELD[c.field] || c.field)}: ${esc(chValue(c.field, c.from))} → ${esc(chValue(c.field, c.to))}`
    : c.action === "added" ? `Added${chRow(c.to) ? " (" + esc(chRow(c.to)) + ")" : ""}` : `Removed${chRow(c.from) ? " (" + esc(chRow(c.from)) + ")" : ""}`;
  el.innerHTML = `<section aria-labelledby="hHelpCh" style="margin-bottom:var(--mm-space-5)"><h2 id="hHelpCh">Changes made by someone helping you</h2>
    <p class="mm-small">Every change someone you share your money topic with makes to these lists is written down here, one item at a time. Your own changes are not listed here; your saves below keep them.
      If something here is wrong, change it back, or stop sharing on <a href="/mirror/my-mirror/settings/">Settings</a>.</p>
    <div class="mm-table-wrap"><table class="mm-table"><caption class="mm-sr">Changes made by someone helping you, newest first</caption>
      <thead><tr><th scope="col">When</th><th scope="col">Who</th><th scope="col">Where</th><th scope="col">What changed</th></tr></thead>
      <tbody>${C.map((c) => `<tr><td>${esc(when(c.at))}</td><td>${esc(c.who)}${c.organization && c.who.indexOf(c.organization) < 0 ? `<br><span class="mm-muted mm-small">${esc(c.organization)}</span>` : ""}</td>
        <td>${esc(CH_LIST[c.list] || c.list)}${c.label && c.label !== CH_LIST[c.list] ? ": " + esc(c.label) : ""}</td><td>${what(c)}</td></tr>`).join("")}</tbody></table></div></section>`;
}

/** Everything that differs between two saves: costs, income, help that isn't cash, goals, tax rate. */
function changes(newer, older) {
  const out = [];
  const lists = [["expenses", "cost", (x) => `${x.label} (${(LEVEL[x.level] || { short: x.level }).short})`, (x) => [x.level, x.category, String(x.label).toLowerCase()].join("|")],
    ["income", "income", (x) => x.label, (x) => ["i", x.kind, String(x.label).toLowerCase()].join("|")],
    ["noncash", "help that isn't cash", (x) => x.label, (x) => ["n", x.kind, x.category, String(x.label).toLowerCase()].join("|")]];
  for (const [key, what, name, id] of lists) {
    const a = new Map(((older.inputs || {})[key] || []).map((x) => [id(x), x])), b = new Map(((newer.inputs || {})[key] || []).map((x) => [id(x), x]));
    for (const [k, x] of b) {
      const o = a.get(k);
      if (!o) out.push(`Added ${what}: ${name(x)}, ${fmtLine(x)}`);
      else if (annualOf(o) !== annualOf(x) || o.paid_by !== x.paid_by || o.start_on !== x.start_on || o.end_on !== x.end_on
        || JSON.stringify(o.applies_to || null) !== JSON.stringify(x.applies_to || null)) out.push(`Changed ${what}: ${name(x)}, ${fmtLine(o)} → ${fmtLine(x)}`);
    }
    for (const [k, x] of a) if (!b.has(k)) out.push(`Removed ${what}: ${name(x)}`);
  }
  const ga = new Map(((older.inputs || {}).goals || []).map((g) => [String(g.label).toLowerCase(), g]));
  for (const g of ((newer.inputs || {}).goals || [])) {
    const o = ga.get(String(g.label).toLowerCase());
    if (!o) out.push(`Added goal: ${g.label}`);
    else if (Number(o.current_amount) !== Number(g.current_amount)) out.push(`Goal ${g.label}: saved ${money(Number(o.current_amount))} → ${money(Number(g.current_amount))}`);
    else if (Number(o.target_amount) !== Number(g.target_amount) || o.target_date !== g.target_date || o.level !== g.level) out.push(`Changed goal: ${g.label}`);
  }
  const ta = Number((older.inputs || {}).tax_rate_pct || 0), tb = Number((newer.inputs || {}).tax_rate_pct || 0);
  if (ta !== tb) out.push(`Tax rate: ${ta}% → ${tb}%`);
  return out;
}

// ---------------------------------------------------------------- the chart: Today and Stability per day, over time
// Change over time = a line chart (two series, one axis in dollars a day starting at 0). Colors: the dataviz reference blue and orange,
// validated (light on white, dark on #1D242B: all checks pass). Legend + direct end labels, so identity is never color alone; hover or
// focus shows the values; the save cards below are the table view.
const SERIES = [["current", "Today", "--mm-viz-1"], ["stability", "Stability", "--mm-viz-2"]];
function chart(asc) {
  const W = 640, H = 220, padL = 56, padR = 118, padT = 14, padB = 34;
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
  return `<figure class="mm-card mm-viz" style="margin:0 0 var(--mm-space-5)">
    <figcaption><strong>Cost per day over time</strong></figcaption>
    <div class="mm-viz-legend">${SERIES.map(([, name, c]) => `<span><i style="background:var(${c})"></i>${esc(name)}</span>`).join("")}</div>
    <div class="mm-viz-wrap">
    <svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Line chart: cost per day for Today and Stability at each save, from ${esc(fmtD(t0))} to ${esc(fmtD(t1))}. The saves below list every value.">
      ${ticks.map((v) => `<line x1="${padL}" x2="${W - padR}" y1="${y(v)}" y2="${y(v)}" class="mm-viz-grid"/><text x="${padL - 8}" y="${y(v) + 4}" text-anchor="end" class="mm-viz-axis">${esc(money(v).replace(".00", ""))}</text>`).join("")}
      <text x="${padL}" y="${H - 10}" class="mm-viz-axis">${esc(fmtD(t0))}</text>
      <text x="${W - padR}" y="${H - 10}" text-anchor="end" class="mm-viz-axis">${esc(fmtD(t1))}</text>
      ${SERIES.map(([k, name, c]) => { const p = pts(k); const lp = p[p.length - 1];
        return `<polyline fill="none" stroke="var(${c})" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" points="${p.map((q) => q.join(",")).join(" ")}"/>
          ${p.map((q) => `<circle cx="${q[0]}" cy="${q[1]}" r="4" fill="var(${c})" stroke="var(--mm-surface)" stroke-width="2"/>`).join("")}
          <text x="${lp[0] + 10}" y="${lp[1] + 4}" class="mm-viz-label">${esc(name)} ${esc(money(last.results.levels[k] ? last.results.levels[k].cost.daily : 0))}</text>`; }).join("")}
      <line class="mm-viz-cross" style="display:none" y1="${padT}" y2="${H - padB}" x1="-10" x2="-10"/>
      ${asc.map((snap, i) => { const cx = x(Date.parse(snap.taken_at)); const w = asc.length > 1 ? Math.max(14, (W - padL - padR) / (asc.length - 1)) : 40;
        return `<rect class="mm-viz-hit" x="${cx - w / 2}" y="${padT}" width="${w}" height="${H - padT - padB}" tabindex="0" data-i="${i}"
          aria-label="${esc(fmtD(Date.parse(snap.taken_at)))}: ${SERIES.map(([k, n]) => n + " " + money(snap.results.levels[k] ? snap.results.levels[k].cost.daily : 0) + " a day").join(", ")}"/>`; }).join("")}
    </svg>
    <div class="mm-viz-tip" hidden></div></div>
    <script type="application/json" class="mm-viz-data">${JSON.stringify(asc.map((snap) => ({ x: x(Date.parse(snap.taken_at)), d: fmtD(Date.parse(snap.taken_at)),
      v: SERIES.map(([k]) => (snap.results.levels[k] ? snap.results.levels[k].cost.daily : 0)) }))).replace(/</g, "\\u003c")}</script>
  </figure>`;
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
    cross.setAttribute("x1", p.x); cross.setAttribute("x2", p.x); cross.style.display = "";
    tip.innerHTML = `<strong>${esc(p.d)}</strong>${SERIES.map(([, n, c], j) => `<span><i style="background:var(${c})"></i>${esc(n)} ${esc(money(p.v[j]))} a day</span>`).join("")}`;
    tip.hidden = false;
    const box = svg.getBoundingClientRect();
    tip.style.left = Math.min(box.width - 180, Math.max(0, (p.x / 640) * box.width - 90)) + "px";
  };
  const hide = () => { tip.hidden = true; cross.style.display = "none"; };
  fig.querySelectorAll(".mm-viz-hit").forEach((r) => {
    const i = Number(r.getAttribute("data-i"));
    r.addEventListener("pointerenter", () => show(i)); r.addEventListener("focus", () => show(i));
    r.addEventListener("pointerleave", hide); r.addEventListener("blur", hide);
  });
}

// ---------------------------------------------------------------- the six Daily Number reflections (Stephen's paper, section 6)
async function reflect(body) {
  const key = new URLSearchParams(location.search).get("s") || "";
  let sets;
  try { sets = (await rpc("mirror_sets", { p_kind: "module" })).filter((x) => /^dn_/.test(x.key)); }
  catch (e) { errBox(body, e); return; }
  const set = sets.find((x) => x.key === key);
  if (!set) {
    body.innerHTML = `<div class="mm-read"><h1>Think it through</h1>
      <p class="mm-lead">Six short reflections on money and your life, in your own words. Speak or type; skip anything. Your numbers are on the other tabs; these are the story behind them.</p></div>
      <div class="mm-grid">${sets.map((x, i) => `<a class="mm-card" href="${BASE}reflect/?s=${encodeURIComponent(x.key)}">
        <div class="mm-card-num">${i + 1}</div><h3>${esc(x.title)}</h3><p class="mm-muted">${esc(x.intro || "")}</p>
        ${countBar(x.answered, x.questions, "answered")}</a>`).join("")}</div>`;
    return;
  }
  const i = sets.indexOf(set);
  const nxt = sets.slice(i + 1).find((x) => x.answered < x.questions) || sets.find((x) => x !== set && x.answered < x.questions);
  body.innerHTML = `<div class="mm-read"><p class="mm-eyebrow"><a href="${BASE}reflect/">Think it through</a> · ${i + 1} of ${sets.length}</p>
    <h1>${esc(set.title)}</h1><p class="mm-lead">${esc(set.intro || "")}</p></div><div id="dnSet"></div>`;
  runSet(/** @type {HTMLElement} */ (body.querySelector("#dnSet")), set.key, {
    nextLink: nxt ? { href: `${BASE}reflect/?s=${encodeURIComponent(nxt.key)}`, label: "Next: " + nxt.title } : { href: BASE, label: "Back to My Daily Number" } });
}

// ---------------------------------------------------------------- Phase 4 step 4: benefits, household, my plan, what if

const BENEFIT_KINDS = [["food", "Food (FoodShare / SNAP, WIC)"], ["cash", "Cash (SSI, SSDI, W-2, unemployment)"], ["health", "Health coverage (BadgerCare, Medicaid, Medicare)"],
  ["housing", "Housing (voucher, rent help)"], ["childcare", "Child care (Wisconsin Shares)"], ["energy", "Energy help (heating, electric)"], ["phone", "Phone or internet discount"], ["other", "Other"]];
const BENEFIT_STATUS = [["considering", "Thinking about applying"], ["applied", "Applied, waiting"], ["active", "Getting it now"], ["denied", "Denied"], ["appealing", "Appealing"], ["ended", "Ended"]];
const RELATIONS = [["partner", "Partner or spouse"], ["child", "Child"], ["parent", "Parent"], ["sibling", "Brother or sister"], ["other_family", "Other family"],
  ["friend", "Friend"], ["roommate", "Roommate"], ["other", "Other"]];
const OPP_KINDS = [["job", "A job"], ["more_hours", "More hours where I work"], ["raise", "A raise"], ["side_work", "Side work (my own skills or business)"],
  ["benefit", "A benefit I may qualify for"], ["training", "Training that leads to better pay"], ["family", "Help from family"], ["other", "Other"]];
const OPP_STATUS = [["idea", "An idea"], ["working_on", "Working on it"], ["dropped", "Not going ahead"]];
const EARNED_OPP = ["job", "more_hours", "raise", "side_work"];
const BENEFIT_NONCASH_KINDS = ["snap", "wic", "healthcare_coverage"];

/** Date warnings for benefit records: renewal passed or within 60 days, appeal deadline within 30. [notice kind, html] */
function benefitAlerts() {
  const today = asOf(), out = [];
  for (const b of (D.plan && D.plan.benefits) || []) {
    if (b.renewal_on && ["active", "appealing"].includes(b.status)) {
      const d = daysBetween(today, b.renewal_on);
      if (d < 0) out.push(["urgent", `<strong>${esc(b.program)}</strong>: the renewal date (${esc(shortDate(b.renewal_on))}) has passed. If it isn't renewed, it can stop. Call the agency or your coordinator.`]);
      else if (d <= 60) out.push([d <= 14 ? "urgent" : "caution", `<strong>${esc(b.program)}</strong>: renewal due ${esc(shortDate(b.renewal_on))} (in ${d} ${d === 1 ? "day" : "days"}).`]);
    }
    if (b.appeal_by && ["denied", "appealing", "active"].includes(b.status)) {
      const d = daysBetween(today, b.appeal_by);
      if (d >= 0 && d <= 30) out.push(["urgent", `<strong>${esc(b.program)}</strong>: the last day to appeal is ${esc(shortDate(b.appeal_by))} (in ${d} ${d === 1 ? "day" : "days"}).`]);
    }
  }
  return out;
}
const alertsHtml = () => benefitAlerts().map(([k, t]) => notice(k, `<p>${t}</p>`)).join("");

/** Benefits counted today: cash benefits, SNAP / WIC / coverage, and records marked "getting it now". */
function liveBenefitNames() {
  const live = (x) => inEffect(x, asOf());
  return [...new Set([...D.inputs.income.filter((x) => live(x) && x.kind === "cash_benefit").map((x) => x.label),
    ...D.inputs.noncash.filter((x) => live(x) && BENEFIT_NONCASH_KINDS.includes(x.kind)).map((x) => x.label),
    ...((D.plan && D.plan.benefits) || []).filter((b) => b.status === "active").map((b) => b.program)])];
}
const cliffNote = (names) => names.length ? notice("caution", `<p><strong>Benefits can go down as earnings go up.</strong> More pay may lower or stop
  ${names.map((n) => "<strong>" + esc(n) + "</strong>").join(", ")}. These numbers keep them as they are. Before you count on both, ask the agency or your coordinator what would change.</p>`) : "";

/** The money line a benefit record points to, as text. @param {any} b */
function benefitLine(b) {
  const find = (rows, id) => rows.find((x) => x.id === id);
  const l = b.income_source_id ? find(D.inputs.income, b.income_source_id) : b.noncash_id ? find(D.inputs.noncash, b.noncash_id) : b.expense_id ? find(D.inputs.expenses, b.expense_id) : null;
  return l ? `${l.label}: ${fmtLine(l)} (${money(annualOf(l) / 12)} a month)` : "";
}
/** Press-twice remove button handler. */
function removeTwice(btn, label, go) {
  btn?.addEventListener("click", async (e) => {
    const x = /** @type {HTMLButtonElement} */ (e.target);
    if (!x.dataset.sure) { x.dataset.sure = "1"; x.textContent = label; return; }
    await go();
  });
}

// ---- Benefits
function benefits(body) {
  const list = (D.plan && D.plan.benefits) || [];
  const BK = Object.fromEntries(BENEFIT_KINDS), BS = Object.fromEntries(BENEFIT_STATUS);
  const date = (label, d) => d ? `${label} ${esc(shortDate(d))}` : "";
  body.innerHTML = `
    <div class="mm-read"><h1>Benefits and subsidies</h1>
      <p class="mm-lead">Keep track of each program: where it stands, when it must be renewed, and the last day to appeal. A missed renewal date is one of the most common reasons help stops.</p>
      <p class="mm-muted mm-small">The amount itself lives on its line (Income and support, or a cost paid for you), so it is never counted twice. Don't write case numbers or Social Security numbers here.</p></div>
    ${alertsHtml()}
    ${list.length ? list.map((b) => `<div class="mm-card" style="margin-bottom:var(--mm-space-3)"><div class="mm-row" style="justify-content:space-between">
        <div><strong>${esc(b.program)}</strong> <span class="mm-tag${b.status === "active" ? " mm-tag-info" : ""}">${esc(BS[b.status] || b.status)}</span>
          <br><span class="mm-muted mm-small">${esc([BK[b.kind] || b.kind, b.agency].filter(Boolean).join(" · "))}</span></div>
        <button class="mm-btn mm-btn-quiet" type="button" data-benefit="${esc(b.id)}">Change</button></div>
        <p class="mm-small" style="margin:var(--mm-space-2) 0 0">${[date("Applied", b.applied_on), date("Approved", b.approved_on), date("Renewal due", b.renewal_on), date("Appeal by", b.appeal_by), date("Ends", b.ends_on)].filter(Boolean).join(" · ") || "No dates yet."}</p>
        ${benefitLine(b) ? `<p class="mm-small" style="margin:0">Amount: ${esc(benefitLine(b))}</p>` : ""}
        ${b.note ? `<p class="mm-muted mm-small" style="margin:0">${esc(b.note)}</p>` : ""}</div>`).join("")
      : notice("info", "<p>No programs yet. Add the help you get now, or one you are applying for.</p>")}
    <div id="bfForm"></div>`;
  const form = (b) => benefitForm(body.querySelector("#bfForm"), b);
  form(null);
  body.querySelectorAll("[data-benefit]").forEach((x) => x.addEventListener("click", () => { form(list.find((b) => b.id === x.dataset.benefit)); body.querySelector("#bfForm").scrollIntoView({ block: "start" }); }));
}

function benefitForm(el, b) {
  const link = b ? (b.income_source_id ? "inc:" + b.income_source_id : b.noncash_id ? "nc:" + b.noncash_id : b.expense_id ? "ex:" + b.expense_id : "") : "";
  const opts = [["", "Not linked"], ...D.inputs.income.map((x) => ["inc:" + x.id, "Income: " + x.label]), ...D.inputs.noncash.map((x) => ["nc:" + x.id, "Help that isn't cash: " + x.label]),
    ...D.inputs.expenses.filter((x) => x.paid_by !== "self").map((x) => ["ex:" + x.id, "Cost paid for you: " + x.label + " (" + LEVEL[x.level].short + ")"])];
  const dateField = (id, label, val) => `<div class="mm-field" style="max-width:14rem"><label for="${id}">${esc(label)} <span class="mm-muted">(optional)</span></label><input class="mm-input" type="date" id="${id}" value="${esc(val || "")}"></div>`;
  el.innerHTML = `<form class="mm-card mm-read" novalidate>
    <h2 style="margin-top:0">${b ? "Change this program" : "Add a program"}</h2>
    <div class="mm-field"><label for="bfProgram">Program</label><input class="mm-input" id="bfProgram" maxlength="120" value="${esc(b ? b.program : "")}" placeholder="For example: FoodShare"></div>
    <div class="mm-field"><label for="bfKind">Kind</label>${sel("bfKind", BENEFIT_KINDS, b ? b.kind : "food")}</div>
    <div class="mm-field"><label for="bfAgency">Agency <span class="mm-muted">(optional)</span></label><input class="mm-input" id="bfAgency" maxlength="120" value="${esc(b && b.agency ? b.agency : "")}"></div>
    <div class="mm-field"><label for="bfStatus">Where it stands</label>${sel("bfStatus", BENEFIT_STATUS, b ? b.status : "active")}</div>
    <div class="mm-row">${dateField("bfApplied", "Applied on", b && b.applied_on)}${dateField("bfApproved", "Approved on", b && b.approved_on)}</div>
    <div class="mm-row">${dateField("bfRenewal", "Renewal due", b && b.renewal_on)}${dateField("bfAppeal", "Last day to appeal", b && b.appeal_by)}${dateField("bfEnds", "Ends on", b && b.ends_on)}</div>
    <div class="mm-field"><label for="bfLink">Which amount is it?</label><span class="mm-hint">Link the line that holds the amount, so the Daily Number counts it once. Add the amount on Income and support first if it isn't there.</span>${sel("bfLink", opts, link)}</div>
    <div class="mm-field"><label for="bfNote">Note <span class="mm-muted">(optional; no case or Social Security numbers)</span></label><input class="mm-input" id="bfNote" maxlength="500" value="${esc(b && b.note ? b.note : "")}"></div>
    <div id="bfMsg" aria-live="assertive"></div>
    <div class="mm-row"><button class="mm-btn" type="submit">${b ? "Save the change" : "Add program"}</button>
      ${b ? '<button class="mm-btn mm-btn-secondary" type="button" data-cancel>Cancel</button><button class="mm-btn mm-btn-quiet" type="button" data-del>Remove</button>' : ""}</div></form>`;
  const f = el.querySelector("form");
  voiceAll(f);
  f.querySelector("[data-cancel]")?.addEventListener("click", () => reload("benefits"));
  removeTwice(f.querySelector("[data-del]"), "Press again to remove", async () => {
    try { await rpc("mirror_dn_delete", { p_kind: "benefit", p_id: b.id }); reload("benefits", "Removed. The amount line is kept."); } catch (err) { errBox(f.querySelector("#bfMsg"), err); }
  });
  f.addEventListener("submit", async (e) => {
    e.preventDefault();
    const [lk, lid] = v(f, "bfLink").split(":");
    try {
      await rpc("mirror_dn_save", { p_kind: "benefit", p: { id: b ? b.id : "", program: v(f, "bfProgram"), kind: v(f, "bfKind"), agency: v(f, "bfAgency"), status: v(f, "bfStatus"),
        applied_on: v(f, "bfApplied"), approved_on: v(f, "bfApproved"), renewal_on: v(f, "bfRenewal"), appeal_by: v(f, "bfAppeal"), ends_on: v(f, "bfEnds"),
        income_source_id: lk === "inc" ? lid : "", noncash_id: lk === "nc" ? lid : "", expense_id: lk === "ex" ? lid : "", note: v(f, "bfNote") } });
      reload("benefits", b ? "Saved." : "Added.");
    } catch (err) { errBox(f.querySelector("#bfMsg"), err); }
  });
}

// ---- Household
function household(body) {
  const members = MEMBERS(), RL = Object.fromEntries(RELATIONS);
  const W = whoPays(D.inputs, "current");
  const gives = (id) => D.inputs.income.filter((x) => x.household_member_id === id);
  const pays = (id) => D.inputs.expenses.filter((x) => x.paid_by === "household" && x.household_member_id === id);
  const row = (label, m) => m > 0 ? `<tr><td data-label="Who pays">${esc(label)}</td><td class="mm-num" data-label="A month">${money(m)}</td><td class="mm-num" data-label="A day">${money(m * 12 / 365)}</td></tr>` : "";
  const any = W.self + W.household + W.subsidy + W.assistance + W.donated > 0;
  body.innerHTML = `
    <div class="mm-read"><h1>My household</h1>
      <p class="mm-lead">Who lives with you or helps you, what each person pays, and what they give. Use a first name or how they're related.</p></div>
    <h2>Who pays what today</h2>
    ${any ? `<div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Who pays today's costs</caption>
      <thead><tr><th scope="col">Who pays</th><th scope="col" class="mm-num">A month</th><th scope="col" class="mm-num">A day</th></tr></thead>
      <tbody>${row("You", W.self)}${Object.entries(W.members).map(([id, m]) => row((memberName(id) || "Someone in your household") + " (household)", m)).join("")}
        ${row("A housing subsidy or voucher", W.subsidy)}${row("A program, agency or family outside the household", W.assistance)}${row("Donated or free", W.donated)}</tbody></table></div>`
      : notice("info", `<p>No costs on <a href="${BASE}today/">Today</a> yet.</p>`)}
    <h2>People</h2>
    ${members.length ? members.map((m) => `<div class="mm-card" style="margin-bottom:var(--mm-space-3)"><div class="mm-row" style="justify-content:space-between">
        <div><strong>${esc(m.label)}</strong> <span class="mm-muted mm-small">${esc(RL[m.relationship] || m.relationship)}${m.lives_with ? " · lives with me" : " · doesn't live with me"}</span></div>
        <button class="mm-btn mm-btn-quiet" type="button" data-member="${esc(m.id)}">Change</button></div>
        ${pays(m.id).length ? `<p class="mm-small" style="margin:var(--mm-space-2) 0 0">Pays: ${pays(m.id).map((x) => esc(x.label) + " (" + esc(LEVEL[x.level].short) + ", " + esc(fmtLine(x)) + ")").join("; ")}</p>` : ""}
        ${gives(m.id).length ? `<p class="mm-small" style="margin:0">Gives: ${gives(m.id).map((x) => esc(x.label) + " (" + esc(fmtLine(x)) + ")").join("; ")}</p>` : ""}
        ${m.note ? `<p class="mm-muted mm-small" style="margin:0">${esc(m.note)}</p>` : ""}</div>`).join("")
      : notice("info", "<p>No one listed. If you live alone and pay everything yourself, there's nothing to add.</p>")}
    <p class="mm-muted mm-small">To show a cost someone pays, choose "Someone in my household pays it" on the cost. To show money they give you, add it on <a href="${BASE}income/">Income and support</a> and choose them.</p>
    <div id="hhForm"></div>`;
  const form = (m) => memberForm(body.querySelector("#hhForm"), m);
  form(null);
  body.querySelectorAll("[data-member]").forEach((x) => x.addEventListener("click", () => { form(members.find((m) => m.id === x.dataset.member)); body.querySelector("#hhForm").scrollIntoView({ block: "start" }); }));
}

function memberForm(el, m) {
  el.innerHTML = `<form class="mm-card mm-read" novalidate>
    <h2 style="margin-top:0">${m ? "Change" : "Add a person"}</h2>
    <div class="mm-field"><label for="hhLabel">First name or how they're related</label><input class="mm-input" id="hhLabel" maxlength="80" value="${esc(m ? m.label : "")}" placeholder="For example: My sister"></div>
    <div class="mm-field"><label for="hhRel">Relationship</label>${sel("hhRel", RELATIONS, m ? m.relationship : "other_family")}</div>
    <label class="mm-choice"><input type="checkbox" id="hhLives"${!m || m.lives_with ? " checked" : ""}> Lives with me</label>
    <div class="mm-field" style="margin-top:var(--mm-space-3)"><label for="hhNote">Note <span class="mm-muted">(optional)</span></label><input class="mm-input" id="hhNote" maxlength="500" value="${esc(m && m.note ? m.note : "")}"></div>
    <div id="hhMsg" aria-live="assertive"></div>
    <div class="mm-row"><button class="mm-btn" type="submit">${m ? "Save the change" : "Add"}</button>
      ${m ? '<button class="mm-btn mm-btn-secondary" type="button" data-cancel>Cancel</button><button class="mm-btn mm-btn-quiet" type="button" data-del>Remove</button>' : ""}</div></form>`;
  const f = el.querySelector("form");
  voiceAll(f);
  f.querySelector("[data-cancel]")?.addEventListener("click", () => reload("household"));
  removeTwice(f.querySelector("[data-del]"), "Press again to remove (their costs and money stay, without the name)", async () => {
    try { await rpc("mirror_dn_delete", { p_kind: "member", p_id: m.id }); reload("household", "Removed. Their costs and money are kept, without the name."); } catch (err) { errBox(f.querySelector("#hhMsg"), err); }
  });
  f.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await rpc("mirror_dn_save", { p_kind: "member", p: { id: m ? m.id : "", label: v(f, "hhLabel"), relationship: v(f, "hhRel"),
        lives_with: /** @type {HTMLInputElement} */ (f.querySelector("#hhLives")).checked, note: v(f, "hhNote") } });
      reload("household", m ? "Saved." : "Added.");
    } catch (err) { errBox(f.querySelector("#hhMsg"), err); }
  });
}

// ---- My plan: income opportunities and "How will I generate my Daily Number?"
function plan(body) {
  const opps = (D.plan && D.plan.opportunities) || [];
  const open = openOpportunities(opps);
  const tax = Number(D.results.tax_rate_pct) || 0;
  const E = planEffect(D.inputs, opps);
  const OK = Object.fromEntries(OPP_KINDS), OS = Object.fromEntries([...OPP_STATUS, ["started", "Started"]]);
  const noTax = !tax && open.some((o) => o.amount_is_gross !== false && opportunityTaxable(o));
  const row = (k, label) => `<tr><td data-label="Level"><strong>${esc(label)}</strong></td>
    <td class="mm-num" data-label="Short a month now">${money(E[k].gap_now)}</td>
    <td class="mm-num" data-label="If these came true">${money(E[k].gap_plan)}</td>
    <td class="mm-num" data-label="Covered">${money(E[k].covered)}</td></tr>`;
  body.innerHTML = `
    <div class="mm-read"><h1>How will I generate my Daily Number?</h1>
      <p class="mm-lead">Ways more money could come in: a job, more hours, a raise, your own skills, a benefit you may qualify for, training. They aren't counted in your Daily Number until they start; here you can see what they would do.</p></div>
    ${open.length ? `<h2>If these came true</h2>
      <div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">The gap now and with the plan</caption>
        <thead><tr><th scope="col">Level</th><th scope="col" class="mm-num">Short a month now</th><th scope="col" class="mm-num">If these came true</th><th scope="col" class="mm-num">Covered</th></tr></thead>
        <tbody>${row("current", "Today")}${row("survival", "Survival")}${row("stability", "Stability")}${row("aspirational", "The life I want")}</tbody></table></div>
      <p class="mm-muted mm-small">Counts ${open.length} ${open.length === 1 ? "opportunity" : "opportunities"} (ideas and ones you're working on): about ${money(E.current.added_income)} a month after taxes${tax ? ` at the ${esc(tax)}% you entered` : ""}, where it counts. Nothing is saved; your Daily Number is unchanged.</p>
      ${noTax ? notice("caution", `<p>No tax rate entered, so pay before taxes is counted in full. Set it on <a href="${BASE}income/">Income and support</a> for a truer picture.</p>`) : ""}
      ${open.some((o) => EARNED_OPP.includes(o.kind)) ? cliffNote(liveBenefitNames()) : ""}` : ""}
    <h2>My opportunities</h2>
    ${opps.length ? opps.map((o) => `<div class="mm-card" style="margin-bottom:var(--mm-space-3)"><div class="mm-row" style="justify-content:space-between">
        <div><strong>${esc(o.label)}</strong> <span class="mm-tag${o.status === "started" ? " mm-tag-info" : ""}">${esc(OS[o.status] || o.status)}</span>
          <br><span class="mm-muted mm-small">${esc(OK[o.kind] || o.kind)} · ${esc(fmtLine(o))}${o.amount_is_gross !== false && opportunityTaxable(o) ? " before taxes" : ""}${o.expected_on ? " · may start " + esc(shortDate(o.expected_on)) : ""}</span></div>
        <div class="mm-row">${o.status !== "started" ? `<button class="mm-btn mm-btn-secondary" type="button" data-start="${esc(o.id)}">It started</button>
          <button class="mm-btn mm-btn-quiet" type="button" data-opp="${esc(o.id)}">Change</button>` : ""}</div></div>
        <p class="mm-small" style="margin:var(--mm-space-2) 0 0">${o.status === "started" ? "Now counted as income on Income and support." : `About ${esc(money(annualOf(opportunityAsIncome(o, tax)) / 12))} a month after taxes.`}</p>
        ${o.next_step ? `<p class="mm-small" style="margin:0"><strong>Next step:</strong> ${esc(o.next_step)}</p>` : ""}
        ${o.note ? `<p class="mm-muted mm-small" style="margin:0">${esc(o.note)}</p>` : ""}</div>`).join("")
      : notice("info", `<p>Nothing yet. What could bring in more money? Even a small idea counts. <a href="${BASE}reflect/?s=dn_generate">Think it through</a> first if you like.</p>`)}
    <div id="opForm"></div>`;
  const form = (o) => oppForm(body.querySelector("#opForm"), o);
  form(null);
  body.querySelectorAll("[data-opp]").forEach((x) => x.addEventListener("click", () => { form(opps.find((o) => o.id === x.dataset.opp)); body.querySelector("#opForm").scrollIntoView({ block: "start" }); }));
  body.querySelectorAll("[data-start]").forEach((x) => x.addEventListener("click", async () => {
    const o = opps.find((y) => y.id === x.dataset.start);
    const b = /** @type {HTMLButtonElement} */ (x);
    if (!b.dataset.sure) { b.dataset.sure = "1"; b.textContent = `Press again: add ${money(takeHome(o, tax))} ${(FREQ[o.frequency] || "").toLowerCase()} as income from today`; return; }
    b.disabled = true;
    try { await rpc("mirror_dn_save", { p_kind: "opportunity_start", p: { id: o.id, start_on: asOf() } }); reload("plan", "Well done. It is now counted as income (see Income and support)."); }
    catch (err) { toast(err instanceof Error ? err.message : String(err)); b.disabled = false; }
  }));
}

function oppForm(el, o) {
  el.innerHTML = `<form class="mm-card mm-read" novalidate>
    <h2 style="margin-top:0">${o ? "Change this opportunity" : "Add an opportunity"}</h2>
    <div class="mm-field"><label for="opKind">Kind</label>${sel("opKind", OPP_KINDS, o ? o.kind : "job")}</div>
    <div class="mm-field"><label for="opLabel">What is it?</label><input class="mm-input" id="opLabel" maxlength="120" value="${esc(o ? o.label : "")}" placeholder="For example: Warehouse job, 20 hours a week"></div>
    <div class="mm-field" style="max-width:14rem"><label for="opAmt">Amount</label><div class="mm-money"><span aria-hidden="true">$</span><input class="mm-input" id="opAmt" inputmode="decimal" data-mm-no-voice value="${esc(o ? o.amount : "")}"></div></div>
    ${freqFields("op", o)}
    <p class="mm-hint" id="opDaily" aria-live="polite"></p>
    <div class="mm-field"><label for="opGross">Is that before taxes?</label>${sel("opGross", [["true", "Yes, pay before taxes"], ["false", "No, it's what I'd take home"]], o ? String(o.amount_is_gross !== false) : "true")}</div>
    <div class="mm-field"><label for="opTax">Is it taxed?</label>${sel("opTax", [["", "The usual way for this kind"], ["true", "Yes"], ["false", "No"]], o && o.taxable !== null && o.taxable !== undefined ? String(o.taxable) : "")}</div>
    ${appliesFields(o)}
    <div class="mm-row">
      <div class="mm-field" style="max-width:14rem"><label for="opWhen">May start <span class="mm-muted">(optional)</span></label><input class="mm-input" type="date" id="opWhen" value="${esc(o && o.expected_on ? o.expected_on : "")}"></div>
      <div class="mm-field" style="max-width:16rem"><label for="opStatus">Where it stands</label>${sel("opStatus", OPP_STATUS, o ? o.status : "idea")}</div></div>
    <div class="mm-field"><label for="opNext">Next step <span class="mm-muted">(optional)</span></label><input class="mm-input" id="opNext" maxlength="300" value="${esc(o && o.next_step ? o.next_step : "")}" placeholder="For example: call back Monday"></div>
    <div class="mm-field"><label for="opNote">Note <span class="mm-muted">(optional)</span></label><input class="mm-input" id="opNote" maxlength="500" value="${esc(o && o.note ? o.note : "")}"></div>
    <div id="opMsg" aria-live="assertive"></div>
    <div class="mm-row"><button class="mm-btn" type="submit">${o ? "Save the change" : "Add"}</button>
      ${o ? '<button class="mm-btn mm-btn-secondary" type="button" data-cancel>Cancel</button><button class="mm-btn mm-btn-quiet" type="button" data-del>Remove</button>' : ""}</div></form>`;
  const f = el.querySelector("form");
  const calc = liveDaily(f, "op", "#opDaily");
  wireFreq(f, "op", calc);
  voiceAll(f);
  f.querySelector("[data-cancel]")?.addEventListener("click", () => reload("plan"));
  removeTwice(f.querySelector("[data-del]"), "Press again to remove", async () => {
    try { await rpc("mirror_dn_delete", { p_kind: "opportunity", p_id: o.id }); reload("plan", "Removed."); } catch (err) { errBox(f.querySelector("#opMsg"), err); }
  });
  f.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await rpc("mirror_dn_save", { p_kind: "opportunity", p: { id: o ? o.id : "", kind: v(f, "opKind"), label: v(f, "opLabel"), amount: v(f, "opAmt"), frequency: v(f, "opFreq"),
        times_per_year: v(f, "opTimes"), spread_months: v(f, "opSpread"), amount_is_gross: v(f, "opGross"), taxable: v(f, "opTax"), applies_to: readApplies(f),
        expected_on: v(f, "opWhen"), status: v(f, "opStatus"), next_step: v(f, "opNext"), note: v(f, "opNote") } });
      reload("plan", o ? "Saved." : "Added.");
    } catch (err) { errBox(f.querySelector("#opMsg"), err); }
  });
}

// ---- What if: change things and see the numbers; nothing is saved
function whatIfPage(body) {
  const I = D.inputs, tax = Number(D.results.tax_rate_pct) || 0;
  const open = openOpportunities((D.plan && D.plan.opportunities) || []);
  const live = (x) => inEffect(x, asOf());
  const lineRow = (x, kind) => `<li><label class="mm-choice"><input type="checkbox" data-stop="${esc(x.id)}"> ${kind === "expense" ? "Gone" : "Stops"}: ${esc(x.label)}</label>
    ${kind !== "noncash" ? `<div class="mm-row" style="align-items:center"><div class="mm-money" style="max-width:9rem"><span aria-hidden="true">$</span><input class="mm-input" inputmode="decimal" data-mm-no-voice data-amt="${esc(x.id)}" value="${esc(x.amount)}" aria-label="New amount for ${esc(x.label)}"></div>
      <span class="mm-muted mm-small">${esc((FREQ[x.frequency] || x.frequency).toLowerCase())}</span></div>` : `<span class="mm-muted mm-small">${esc(fmtLine(x))}</span>`}</li>`;
  const byLevel = Object.keys(LEVEL).map((lv) => [lv, I.expenses.filter((x) => x.level === lv && live(x))]).filter(([, xs]) => xs.length);
  body.innerHTML = `
    <div class="mm-read"><h1>What if?</h1>
      <p class="mm-lead">Try a change and see what it does: a rent change, a job, a benefit that stops. <strong>Nothing here is saved</strong>; your Daily Number stays as it is until you change it on the other tabs.</p></div>
    <div id="wiResult" aria-live="polite"></div>
    <form class="mm-card mm-read" id="wiForm" novalidate>
      ${open.length ? `<fieldset class="mm-choices"><legend class="mm-legend">From my plan</legend>${open.map((o) => `<label class="mm-choice"><input type="checkbox" data-opp="${esc(o.id)}"> ${esc(o.label)} (${esc(money(takeHome(o, tax)))} ${esc((FREQ[o.frequency] || "").toLowerCase())} after taxes)</label>`).join("")}</fieldset>` : ""}
      ${I.income.filter(live).length || I.noncash.filter(live).length ? `<h2 style="font-size:1.2rem">Income and help</h2><ul class="mm-checklist">${I.income.filter(live).map((x) => lineRow(x, "income")).join("")}${I.noncash.filter(live).map((x) => lineRow(x, "noncash")).join("")}</ul>` : ""}
      ${byLevel.map(([lv, xs]) => `<details><summary style="cursor:pointer;font-weight:700">Costs: ${esc(LEVEL[lv].short)} (${xs.length})</summary><ul class="mm-checklist">${xs.map((x) => lineRow(x, "expense")).join("")}</ul></details>`).join("")}
      <h2 style="font-size:1.2rem">Add something</h2>
      <div class="mm-row">
        <div class="mm-field" style="max-width:12rem"><label for="wiInc">New income a month (take-home)</label><div class="mm-money"><span aria-hidden="true">$</span><input class="mm-input" id="wiInc" inputmode="decimal" data-mm-no-voice></div></div>
        <div class="mm-field" style="max-width:12rem"><label for="wiCost">New cost a month</label><div class="mm-money"><span aria-hidden="true">$</span><input class="mm-input" id="wiCost" inputmode="decimal" data-mm-no-voice></div></div>
        <div class="mm-field" style="max-width:14rem"><label for="wiCostLv">In which number</label>${sel("wiCostLv", Object.keys(LEVEL).map((k) => [k, LEVEL[k].short]), "current")}</div></div>
      <button class="mm-btn mm-btn-secondary" type="reset">Start over</button>
    </form>`;
  const f = /** @type {HTMLFormElement} */ (body.querySelector("#wiForm"));
  const num = (s) => Number(String(s).replace(/[$,]/g, ""));
  const draw = () => {
    const w = { stop: [...f.querySelectorAll("[data-stop]:checked")].map((x) => /** @type {HTMLElement} */ (x).dataset.stop), amounts: {}, add_income: [], add_expenses: [] };
    f.querySelectorAll("[data-amt]").forEach((x) => {
      const el = /** @type {HTMLInputElement} */ (x), orig = [...I.expenses, ...I.income].find((y) => y.id === el.dataset.amt), n = num(el.value);
      if (orig && el.value.trim() !== "" && !Number.isNaN(n) && n !== Number(orig.amount)) w.amounts[el.dataset.amt] = n;
    });
    const inc = num(v(f, "wiInc")) || 0, cost = num(v(f, "wiCost")) || 0;
    if (inc > 0) w.add_income.push({ id: "wi-inc", kind: "other", label: "New income", amount: inc, frequency: "monthly", taxable: false });
    if (cost > 0) w.add_expenses.push({ id: "wi-cost", level: v(f, "wiCostLv"), category: "household", label: "New cost", amount: cost, frequency: "monthly", paid_by: "self" });
    const chosen = [...f.querySelectorAll("[data-opp]:checked")].map((x) => /** @type {HTMLElement} */ (x).dataset.opp);
    const opps = open.filter((o) => chosen.includes(o.id));
    const now = D.results.levels, S = dailyNumber(whatIf(withPlan(I, opps), w)).levels;
    const changed = w.stop.length || Object.keys(w.amounts).length || inc || cost || opps.length;
    const cell = (a, b, label) => `<td class="mm-num" data-label="${esc(label)}">${money(b)}${changed && Math.abs(b - a) >= 0.005 ? `<br><span class="mm-small mm-muted">was ${money(a)}</span>` : ""}</td>`;
    const row = (k) => `<tr><td data-label="Level"><strong>${esc(LEVEL[k].short)}</strong></td>${cell(now[k].cost.daily, S[k].cost.daily, "Costs a day")}
      ${cell(now[k].shortfall.monthly, S[k].shortfall.monthly, "Short a month")}${cell(now[k].gross_needed.monthly, S[k].gross_needed.monthly, "Taxed income needed, a month")}</tr>`;
    const earnedUp = opps.some((o) => EARNED_OPP.includes(o.kind)) || inc > 0;
    const stopped = [...I.income, ...I.noncash].filter((x) => w.stop.includes(x.id)).map((x) => x.label);
    body.querySelector("#wiResult").innerHTML = `<div class="mm-table-wrap mm-stack"><table class="mm-table"><caption class="mm-sr">Your numbers with these changes</caption>
      <thead><tr><th scope="col">Level</th><th scope="col" class="mm-num">Costs a day</th><th scope="col" class="mm-num">Short a month</th><th scope="col" class="mm-num">Taxed income needed, a month</th></tr></thead>
      <tbody>${Object.keys(LEVEL).map(row).join("")}</tbody></table></div>
      ${changed ? "" : `<p class="mm-muted mm-small">These are your numbers now. Tick or change something below.</p>`}
      ${earnedUp ? cliffNote(liveBenefitNames().filter((n) => !stopped.includes(n))) : ""}`;
  };
  f.addEventListener("input", draw); f.addEventListener("change", draw);
  f.addEventListener("reset", () => setTimeout(draw, 0));
  draw();
}
