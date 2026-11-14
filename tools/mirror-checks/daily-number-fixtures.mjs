// T4.1 check: the Daily Number against examples worked out by hand (the source paper's figures first).
// Run: node tools/mirror-checks/daily-number-fixtures.mjs        (prints each case and PASS/FAIL)
// The same FIXTURES are exported so the SQL version (mirror.daily_number) is checked against the very same numbers.
import { dailyNumber, cents, withPlan, whatIf, takeHome, planEffect, whoPays } from "../../site/mirror/assets/daily-number.js";

const e = (level, category, amount, frequency, extra = {}) => ({ level, category, amount, frequency, paid_by: "self", ...extra });

// Step 4 base (hand-worked): Stability rent $1,200 + food $400 = $1,600 a month; SSI $943 a month (not taxed); tax 10%. Gap $657 a month.
const B = { as_of: "2026-11-13", tax_rate_pct: 10, noncash: [],
  expenses: [e("stability", "housing", 1200, "monthly", { id: "rent" }), e("stability", "food", 400, "monthly", { id: "food" })],
  income: [{ id: "ssi", kind: "cash_benefit", label: "SSI", amount: 943, frequency: "monthly" }] };
const job300 = { id: "o1", kind: "job", label: "Warehouse job", amount: 300, frequency: "weekly", amount_is_gross: true, status: "working_on" };
const hours100 = { id: "o4", kind: "more_hours", label: "More hours", amount: 100, frequency: "weekly", status: "idea" };

/** name, input, expected [path, value in dollars] (paths into the result; values rounded to cents) */
export const FIXTURES = [
  ["Paper: $2,300 a month -> $75.62 a day, $27,600 a year", {
    expenses: [e("current", "housing", 1000, "monthly"), e("current", "utilities", 150, "monthly"), e("current", "food", 400, "monthly"),
      e("current", "transportation", 150, "monthly"), e("current", "healthcare", 100, "monthly"), e("current", "communication", 80, "monthly"),
      e("current", "clothing", 120, "monthly"), e("current", "household", 100, "monthly"), e("current", "future", 200, "monthly")],
    income: [], noncash: [] },
    [["levels.current.cost.daily", 75.62], ["levels.current.cost.annual", 27600], ["levels.current.cost.monthly", 2300], ["levels.current.cost.weekly", 529.32]]],
  ["Paper: a $600 yearly insurance premium -> $1.64 a day", { expenses: [e("current", "healthcare", 600, "annual")], income: [], noncash: [] },
    [["levels.current.cost.daily", 1.64]]],
  ["Clothing paper: $90 a month -> $2.96 a day", { expenses: [e("current", "clothing", 90, "monthly")], income: [], noncash: [] },
    [["levels.current.cost.daily", 2.96]]],
  ["Paper: $75 a day cost, $25 a day income -> $50 a day short, $1,520.83 a month", {
    expenses: [e("current", "housing", 75, "daily")], income: [{ amount: 25, frequency: "daily" }], noncash: [] },
    [["levels.current.shortfall.daily", 50], ["levels.current.shortfall.monthly", 1520.83], ["income.daily", 25], ["levels.current.resources.daily", 25], ["levels.current.cost.daily", 75]]],
  ["Every frequency: weekly $70, every 2 weeks $140, twice a month $100, quarterly $300", {
    expenses: [e("current", "food", 70, "weekly"), e("survival", "food", 140, "biweekly"), e("stability", "food", 100, "twice_month"), e("aspirational", "food", 300, "quarterly")],
    income: [], noncash: [] },
    [["levels.current.cost.daily", 10], ["levels.survival.cost.daily", 10], ["levels.stability.cost.annual", 2400], ["levels.stability.cost.daily", 6.58],
     ["levels.aspirational.cost.annual", 3600], ["levels.aspirational.cost.daily", 9.86]]],
  ["Irregular and one-time: car repair $300 three times a year; $1,200 one-time spread over 24 months; $500 one-time over 6 months", {
    expenses: [e("current", "transportation", 300, "irregular", { times_per_year: 3 }), e("survival", "household", 1200, "one_time", { spread_months: 24 }),
      e("stability", "household", 500, "one_time", { spread_months: 6 })], income: [], noncash: [] },
    [["levels.current.cost.annual", 900], ["levels.current.cost.daily", 2.47], ["levels.survival.cost.annual", 600], ["levels.survival.cost.daily", 1.64],
     ["levels.stability.cost.annual", 1000], ["levels.stability.cost.monthly", 83.33], ["levels.stability.cost.daily", 2.74]]],
  ["Housing subsidy: rent $1,000 a month, person pays $300, subsidy pays $700", {
    expenses: [e("current", "housing", 300, "monthly"), e("current", "housing", 700, "monthly", { paid_by: "subsidy" })], income: [], noncash: [] },
    [["levels.current.cost.daily", 32.88], ["levels.current.paid_by_others.daily", 23.01], ["levels.current.cash_expenses.daily", 9.86],
     ["levels.current.cash_needed.monthly", 300]]],
  ["SNAP is not income: food $400 a month, SNAP $250 a month; wages $500 a month", {
    expenses: [e("current", "food", 400, "monthly"), e("current", "housing", 600, "monthly")],
    income: [{ amount: 500, frequency: "monthly" }], noncash: [{ category: "food", amount: 250, frequency: "monthly" }] },
    [["levels.current.cost.monthly", 1000], ["levels.current.noncash_applied.monthly", 250], ["levels.current.cash_needed.monthly", 750],
     ["income.monthly", 500], ["noncash.daily", 8.22], ["levels.current.shortfall.monthly", 250]]],
  ["Non-cash support never covers more than its own category: SNAP $500 a month, food $400 a month", {
    expenses: [e("current", "food", 400, "monthly"), e("current", "housing", 600, "monthly")], income: [], noncash: [{ category: "food", amount: 500, frequency: "monthly" }] },
    [["levels.current.noncash_applied.monthly", 400], ["levels.current.cash_needed.monthly", 600], ["noncash.monthly", 500]]],
  ["Taxes: $2,000 a month needed in cash, 20% tax rate -> $2,500 a month before taxes, $82.19 a day", {
    expenses: [e("current", "housing", 2000, "monthly")], income: [], noncash: [], tax_rate_pct: 20 },
    [["levels.current.gross_needed.monthly", 2500], ["levels.current.gross_needed.daily", 82.19], ["levels.current.cash_needed.daily", 65.75]]],
  ["Levels: survival $600, stability $1,500, aspirational adds $500 to stability", {
    expenses: [e("survival", "food", 600, "monthly"), e("stability", "housing", 1500, "monthly"), e("aspirational", "development", 500, "monthly")],
    income: [], noncash: [] },
    [["levels.survival.cost.daily", 19.73], ["levels.stability.cost.daily", 49.32], ["levels.aspirational.cost.monthly", 2000], ["levels.aspirational.cost.daily", 65.75]]],
  ["Cost of being poor: laundromat $40 a month marked, plus rent $800", {
    expenses: [e("current", "household", 40, "monthly", { poverty_premium: true }), e("current", "housing", 800, "monthly")], income: [], noncash: [] },
    [["levels.current.poverty_premium.monthly", 40], ["levels.current.poverty_premium.daily", 1.32], ["levels.current.cost.monthly", 840]]],
  ["Dates (as of 11/13/2026): rent $800; phone ended 10/31 (not counted); bus starts 12/1 (not yet); gym ends 11/13 (still counts today); job starts 1/5/2027 (not income yet)", {
    as_of: "2026-11-13",
    expenses: [e("current", "housing", 800, "monthly"), e("current", "communication", 50, "monthly", { end_on: "2026-10-31" }),
      e("current", "transportation", 60, "monthly", { start_on: "2026-12-01" }), e("current", "development", 30, "monthly", { end_on: "2026-11-13" })],
    income: [{ amount: 1000, frequency: "monthly", start_on: "2027-01-05" }], noncash: [] },
    [["levels.current.cost.monthly", 830], ["levels.current.lines", 2], ["income.monthly", 0], ["levels.current.shortfall.monthly", 830]]],
  ["Same dates seen from 12/15/2026: phone and gym gone, bus counts", {
    as_of: "2026-12-15",
    expenses: [e("current", "housing", 800, "monthly"), e("current", "communication", 50, "monthly", { end_on: "2026-10-31" }),
      e("current", "transportation", 60, "monthly", { start_on: "2026-12-01" }), e("current", "development", 30, "monthly", { end_on: "2026-11-13" })],
    income: [], noncash: [] },
    [["levels.current.cost.monthly", 860], ["levels.current.lines", 2]]],
  ["Savings goals (as of 11/13/2026): emergency fund $1,000, $250 saved, by 5/12/2027 = 180 days = 6 months = $125/month in Stability; $2,400 by 11/13/2027 = 12 months = $200/month in The life I want; a goal not counted, a goal already due, a goal already reached", {
    as_of: "2026-11-13",
    expenses: [e("stability", "housing", 1000, "monthly")], income: [], noncash: [],
    goals: [{ level: "stability", target_amount: 1000, current_amount: 250, target_date: "2027-05-12" },
      { level: "aspirational", target_amount: 2400, current_amount: 0, target_date: "2027-11-13" },
      { level: "none", target_amount: 500, current_amount: 0, target_date: "2027-03-01" },
      { level: "stability", target_amount: 900, current_amount: 0, target_date: "2026-11-01" },
      { level: "stability", target_amount: 300, current_amount: 300, target_date: "2027-03-01" }] },
    [["levels.stability.goals.monthly", 125], ["levels.stability.cost.monthly", 1125], ["levels.stability.lines", 1],
     ["levels.aspirational.goals.monthly", 325], ["levels.aspirational.cost.monthly", 1325], ["levels.current.cost.monthly", 0],
     ["levels.stability.cash_needed.monthly", 1125]]],
  ["Resources per level (as of 11/13/2026, 10% tax): SSI $943 and SNAP $250 today only; a $1,500 job at Stability and above", {
    as_of: "2026-11-13", tax_rate_pct: 10,
    expenses: [e("current", "housing", 600, "monthly"), e("current", "food", 400, "monthly"), e("stability", "housing", 950, "monthly"), e("stability", "food", 400, "monthly")],
    income: [{ kind: "cash_benefit", amount: 943, frequency: "monthly", applies_to: ["current", "survival"] },
      { kind: "wages", amount: 1500, frequency: "monthly", applies_to: ["stability", "aspirational"] }],
    noncash: [{ category: "food", amount: 250, frequency: "monthly", applies_to: ["current", "survival"] }] },
    [["levels.current.cash_needed.monthly", 750], ["levels.current.shortfall.monthly", 0], ["levels.current.resources.monthly", 1193],
     ["levels.current.untaxed_income.monthly", 943], ["levels.current.gross_needed.monthly", 0], ["income.monthly", 943],
     ["levels.stability.noncash_applied.monthly", 0], ["levels.stability.income.monthly", 1500], ["levels.stability.cash_needed.monthly", 1350],
     ["levels.stability.gross_needed.monthly", 1500], ["levels.stability.resources.monthly", 1500], ["levels.aspirational.income.monthly", 1500]]],
  ["Untaxed income lowers what must be earned: $2,000 cash needed, SSI $800 (not taxed), 20% tax -> ($2,000 - $800) / 0.8 = $1,500 before taxes", {
    expenses: [e("current", "housing", 2000, "monthly")], income: [{ kind: "cash_benefit", amount: 800, frequency: "monthly" }], noncash: [], tax_rate_pct: 20 },
    [["levels.current.gross_needed.monthly", 1500], ["levels.current.shortfall.monthly", 1200], ["levels.current.untaxed_income.monthly", 800]]],
  ["A cash benefit the person marks as taxed counts as taxed", {
    expenses: [e("current", "housing", 2000, "monthly")], income: [{ kind: "cash_benefit", amount: 800, frequency: "monthly", taxable: true }], noncash: [], tax_rate_pct: 20 },
    [["levels.current.gross_needed.monthly", 2500], ["levels.current.untaxed_income.monthly", 0]]],
  ["Lines switched off do not count", {
    expenses: [e("current", "housing", 800, "monthly"), e("current", "food", 300, "monthly", { active: false })], income: [], noncash: [] },
    [["levels.current.cost.monthly", 800], ["levels.current.lines", 1]]],
  // Step 4: the plan ("if these came true") and "what if". The SQL calculation gets the same changed inputs.
  ["Plan: a $300/week job before taxes at 10% = $270/week take-home = $270 x 365 / 7 / 12 = $1,173.21 a month; with SSI $2,116.21 covers the $1,600", withPlan(B, [job300]),
    [["levels.stability.income.monthly", 2116.21], ["levels.stability.shortfall.monthly", 0], ["levels.stability.cost.monthly", 1600]]],
  ["Plan: side work $200 a month already after taxes: income $1,143, gap $1,600 - $1,143 = $457",
    withPlan(B, [{ id: "o2", kind: "side_work", label: "Braiding hair", amount: 200, frequency: "monthly", amount_is_gross: false, status: "idea" }]),
    [["levels.stability.income.monthly", 1143], ["levels.stability.shortfall.monthly", 457]]],
  ["Plan: started and dropped opportunities don't count again: gap stays $657",
    withPlan(B, [{ ...job300, status: "started" }, { id: "o3", kind: "side_work", label: "x", amount: 200, frequency: "monthly", status: "dropped" }]),
    [["levels.stability.income.monthly", 943], ["levels.stability.shortfall.monthly", 657]]],
  ["Plan: $100/week before taxes at 10% = $90/week = $391.07 a month; income $1,334.07; gap $265.93", withPlan(B, [hours100]),
    [["levels.stability.income.monthly", 1334.07], ["levels.stability.shortfall.monthly", 265.93]]],
  ["What if SSI stops and rent drops to $1,000: costs $1,400, income $0, gap $1,400", whatIf(B, { stop: ["ssi"], amounts: { rent: 1000 } }),
    [["levels.stability.cost.monthly", 1400], ["levels.stability.income.monthly", 0], ["levels.stability.shortfall.monthly", 1400]]],
  ["What if utilities $150 are added and a $500 job starts: costs $1,750, income $1,443, gap $307",
    whatIf(B, { add_expenses: [e("stability", "utilities", 150, "monthly", { id: "w1" })], add_income: [{ id: "w2", kind: "wages", label: "Job", amount: 500, frequency: "monthly" }] }),
    [["levels.stability.cost.monthly", 1750], ["levels.stability.income.monthly", 1443], ["levels.stability.shortfall.monthly", 307]]],
  // K-09 option A (Stephen 11/13/2026): a one-time cost counts amount / months each month, only during those months.
  ["One-time $500 over 6 months from Jan 1, 2027: still counted Jun 30 ($500 / 6 = $83.33 a month, $1,000 x / 365 = $2.74 a day)", {
    as_of: "2027-06-30", expenses: [e("current", "household", 500, "one_time", { spread_months: 6, start_on: "2027-01-01" })], income: [], noncash: [] },
    [["levels.current.cost.monthly", 83.33], ["levels.current.cost.daily", 2.74], ["levels.current.lines", 1]]],
  ["The same cost on Jul 1, 2027: its 6 months are over, so $0", {
    as_of: "2027-07-01", expenses: [e("current", "household", 500, "one_time", { spread_months: 6, start_on: "2027-01-01" })], income: [], noncash: [] },
    [["levels.current.cost.monthly", 0], ["levels.current.lines", 0]]],
  ["One-time $100 over 1 month from Jan 31, 2027: Jan 31 + 1 month = Feb 28, so the last day counted is Feb 27", {
    as_of: "2027-02-27", expenses: [e("current", "household", 100, "one_time", { spread_months: 1, start_on: "2027-01-31" })], income: [], noncash: [] },
    [["levels.current.cost.monthly", 100], ["levels.current.lines", 1]]],
  ["The same cost on Feb 28, 2027: $0", {
    as_of: "2027-02-28", expenses: [e("current", "household", 100, "one_time", { spread_months: 1, start_on: "2027-01-31" })], income: [], noncash: [] },
    [["levels.current.cost.monthly", 0], ["levels.current.lines", 0]]],
  ["An earlier end date wins: $600 over 6 months from Jan 1, 2027, ends Mar 31; Apr 1 = $0, Mar 31 = $100 a month", {
    as_of: "2027-04-01", expenses: [e("current", "household", 600, "one_time", { spread_months: 6, start_on: "2027-01-01", end_on: "2027-03-31" }),
      e("survival", "household", 600, "one_time", { spread_months: 6, start_on: "2027-01-01", end_on: "2027-04-01" })], income: [], noncash: [] },
    [["levels.current.cost.monthly", 0], ["levels.survival.cost.monthly", 100]]],
];

/** JavaScript-only figures (pages that save nothing): take-home pay and how much of the gap a plan covers. [name, value, expected] */
export const JS_ONLY = [
  ["Take-home: $300 before taxes, taxed, 10% -> $270", takeHome({ kind: "job", amount: 300 }, 10), 270],
  ["Take-home: $300 already after taxes -> $300", takeHome({ kind: "job", amount: 300, amount_is_gross: false }, 10), 300],
  ["Take-home: a benefit is not taxed -> $300", takeHome({ kind: "benefit", amount: 300 }, 10), 300],
  ["Take-home: family money the person marks as taxed, 10% -> $270", takeHome({ kind: "family", amount: 300, taxable: true }, 10), 270],
  ["Take-home: $123.45 at 22.5% = $95.67375 -> $95.67", takeHome({ kind: "raise", amount: 123.45 }, 22.5), 95.67],
  ["Plan covers the whole $657 Stability gap", planEffect(B, [job300]).stability.covered, 657],
  ["Plan: Stability gap after the plan $0", planEffect(B, [job300]).stability.gap_plan, 0],
  ["Plan adds $1,173.21 a month of income", planEffect(B, [job300]).stability.added_income, 1173.21],
  ["Plan: $100/week more hours covers $657 - $265.93 = $391.07 of the gap", planEffect(B, [hours100]).stability.covered, 391.07],
  // Who pays what (Stability): the person $1,600; sister pays a $600 rent share; a subsidy pays $300; an unnamed household member $50.
  ...(() => {
    const H = { ...B, expenses: [...B.expenses, e("stability", "housing", 600, "monthly", { paid_by: "household", household_member_id: "sis" }),
      e("stability", "housing", 300, "monthly", { paid_by: "subsidy" }), e("stability", "food", 50, "monthly", { paid_by: "household" }),
      e("current", "food", 999, "monthly", { paid_by: "household", household_member_id: "sis" })] };
    const W = whoPays(H, "stability"), A = whoPays(H, "aspirational");
    return [["Who pays (Stability): you $1,600", W.self, 1600], ["Who pays: household $650 in all", W.household, 650], ["Who pays: sister $600", W.members.sis, 600],
      ["Who pays: not named $50", W.members[""], 50], ["Who pays: subsidy $300", W.subsidy, 300], ["Who pays: Today's $999 line is not in Stability; The life I want = Stability here, $650", A.household, 650]];
  })(),
];

const get = (o, p) => p.split(".").reduce((x, k) => (x == null ? undefined : x[k]), o);

if (import.meta.url === `file://${process.argv[1].replace(/\\/g, "/")}` || process.argv[1].endsWith("daily-number-fixtures.mjs")) {
  let fail = 0, n = 0;
  for (const [name, input, expect] of FIXTURES) {
    const r = dailyNumber(input);
    const bad = expect.filter(([p, v]) => cents(get(r, p)) !== v).map(([p, v]) => `${p}: got ${cents(get(r, p))}, expected ${v}`);
    n += expect.length; fail += bad.length;
    console.log((bad.length ? "FAIL " : "PASS ") + name + (bad.length ? "\n     " + bad.join("\n     ") : ""));
  }
  for (const [name, got, want] of JS_ONLY) {
    n += 1; const ok = cents(got) === want; if (!ok) fail += 1;
    console.log((ok ? "PASS " : "FAIL ") + name + (ok ? "" : `: got ${cents(got)}, expected ${want}`));
  }
  console.log(`\n${n - fail} of ${n} figures match the hand-worked answers.`);
  process.exit(fail ? 1 : 0);
}
