// @ts-check
// The Human Mirror T4.1: the Daily Number calculation. Pure functions, no page or database code, so the same arithmetic can be
// checked by hand (tools/mirror-checks/daily-number-fixtures.mjs) and is repeated exactly in SQL (mirror.daily_number()).
//
// Sources: the prompt (Part 4) and Stephen's Daily Number paper ("Assisted living" email, 11/12/2026). Arithmetic: decision D-08.
//   Daily = Annual / 365.  Weekly = Daily x 7.  Monthly = Annual / 12.  Calculated in full precision, rounded only for display.
//
// Four numbers: current (today's real costs), survival, stability, aspirational (= stability lines + aspirational lines).
// Seven figures per number (prompt Part 4 "distinguish carefully"):
//   1 cost            total cost of living (every line, whoever pays)
//   2 cash_expenses   costs the person pays in cash
//   3 paid_by_others  costs paid directly by a subsidy, an assistance program, or donated
//   4 noncash         non-cash support (SNAP, donated goods, coverage): only lowers costs in its own category, never "income"
//   5 income          cash income available (take-home)
//   6 shortfall       cash still needed after cash income: max(0, cash_needed - income)
//   7 gross_needed    income needed before taxes to pay cash_needed: cash_needed / (1 - tax rate). No tax rate is assumed.
// Also: cash_needed = cash_expenses - noncash applied; poverty_premium = lines marked "cost of being poor" (T4.4).

export const METHOD_VERSION = 4;   // 2: start/end dates and savings goals; 3: resources per level, untaxed income; 4: one-time cost = amount / months, only during those months (11/13/2026)

export const CATEGORIES = [
  ["housing", "Housing", "Rent, mortgage, property costs"],
  ["utilities", "Utilities", "Electricity, gas, water"],
  ["food", "Food", "Groceries, meals, drinking water"],
  ["transportation", "Transportation", "Transit, fuel, vehicle costs"],
  ["healthcare", "Healthcare", "Insurance, medication, appointments"],
  ["personal_care", "Personal care", "Hygiene, haircuts, toiletries"],
  ["clothing", "Clothing", "Everyday clothing, shoes, replacement"],
  ["communication", "Communication", "Phone, internet, devices"],
  ["household", "Household", "Cleaning, laundry, furnishings"],
  ["financial", "Financial", "Banking, debt payments, fees"],
  ["development", "Personal development", "Education, training, recreation"],
  ["future", "Future security", "Savings, emergency fund, retirement"],
];

export const FREQUENCIES = [
  ["daily", "Every day"], ["weekly", "Every week"], ["biweekly", "Every 2 weeks"], ["twice_month", "Twice a month"],
  ["monthly", "Every month"], ["quarterly", "Every 3 months"], ["annual", "Once a year"],
  ["irregular", "A number of times a year"], ["one_time", "One time (spread over months)"],
];

export const LEVELS = ["current", "survival", "stability", "aspirational"];

/**
 * How much one line comes to in a year.
 * @param {{amount: number|string, frequency: string, times_per_year?: number|string|null, spread_months?: number|string|null}} l
 */
export function annualOf(l) {
  const a = Number(l.amount) || 0;
  switch (l.frequency) {
    case "daily": return a * 365;
    case "weekly": return a * 365 / 7;
    case "biweekly": return a * 365 / 14;
    case "twice_month": return a * 24;
    case "monthly": return a * 12;
    case "quarterly": return a * 4;
    case "annual": return a;
    case "irregular": return a * (Number(l.times_per_year) || 0);
    // A one-time cost spread over m months: a/m each month, so a year's rate is a x 12 / m; it counts only during those m months (endOn).
    case "one_time": return a * 12 / Math.max(Number(l.spread_months) || 12, 1);
    default: return 0;
  }
}

/** {annual, daily, weekly, monthly} from an annual amount. @param {number} annual */
export function per(annual) {
  const daily = annual / 365;
  return { annual, daily, weekly: daily * 7, monthly: annual / 12 };
}

/** @param {number} n */
export const cents = (n) => Math.round((n + Number.EPSILON) * 100) / 100;

/**
 * @typedef {{ level: string, category: string, amount: number, frequency: string, times_per_year?: number|null, spread_months?: number|null,
 *   paid_by: "self"|"subsidy"|"assistance"|"donated", poverty_premium?: boolean, active?: boolean }} Expense
 * @typedef {{ amount: number, frequency: string, times_per_year?: number|null, spread_months?: number|null, active?: boolean }} Income
 * @typedef {{ category: string, amount: number, frequency: string, times_per_year?: number|null, spread_months?: number|null, active?: boolean }} Noncash
 * @param {{ expenses: Expense[], income: Income[], noncash: Noncash[], tax_rate_pct?: number }} input
 */
export function dailyNumber(input) {
  // Method 2 (11/13/2026): lines count only while in effect on the "as of" day (start_on / end_on), and savings goals with an amount
  // and a date become a monthly saving in the level the person chose.
  // Method 3 (11/13/2026): income and help that isn't cash count only in the levels they apply to (applies_to; empty = all), so the
  // gap at Stability can leave out SNAP that would stop or include a job that will start; per level: resources = cash income + help
  // that isn't cash used + costs paid for the person (the paper's "$75 cost, $25 resources, $50 short"); income needed before taxes
  // = (cash needed - untaxed income) / (1 - tax rate), because SSI, gifts and similar income are not taxed.
  const asOf = input.as_of || todayISO();
  const on = (/** @type {any} */ x) => inEffect(x, asOf);
  const applies = (/** @type {{applies_to?: string[]|null}} */ x, /** @type {string} */ lv) => !x.applies_to || !x.applies_to.length || x.applies_to.includes(lv);
  const tax = Math.min(Math.max(Number(input.tax_rate_pct) || 0, 0), 90) / 100;
  const incomeLines = (input.income || []).filter(on);
  const noncashLines = (input.noncash || []).filter(on);

  // Savings goals: (target - saved) / months left, as a monthly cost paid by the person, in the level chosen (never "none").
  const goalLines = (input.goals || []).map((g) => ({ level: g.level || "stability", category: "future", amount: goalMonthly(g, asOf),
    frequency: "monthly", paid_by: "self", goal: true })).filter((g) => g.amount > 0 && g.level !== "none");

  /** @param {any[]} lines @param {string} lv */
  const figures = (lines, lv) => {
    const inc = incomeLines.filter((x) => applies(x, lv));
    const incomeAnnual = inc.reduce((sum, x) => sum + annualOf(x), 0);
    const untaxed = inc.filter((x) => !isTaxable(x)).reduce((sum, x) => sum + annualOf(x), 0);
    /** @type {Record<string, number>} */ const noncashByCat = {};
    for (const n of noncashLines.filter((x) => applies(x, lv))) noncashByCat[n.category] = (noncashByCat[n.category] || 0) + annualOf(n);
    const noncashTotal = Object.values(noncashByCat).reduce((sum, v) => sum + v, 0);
    let cost = 0, cash = 0, others = 0, premium = 0, goals = 0;
    /** @type {Record<string, number>} */ const cashByCat = {};
    for (const l of lines) {
      const y = annualOf(l);
      cost += y;
      if (l.paid_by === "self") { cash += y; cashByCat[l.category] = (cashByCat[l.category] || 0) + y; } else others += y;
      if (l.poverty_premium) premium += y;
      if (l.goal) goals += y;
    }
    // Non-cash support only covers cash costs in its own category (SNAP pays for food, not rent).
    const applied = Object.entries(cashByCat).reduce((sum, [c, y]) => sum + Math.min(y, noncashByCat[c] || 0), 0);
    const cashNeeded = cash - applied;
    return {
      lines: lines.filter((l) => !l.goal).length,
      cost: per(cost), cash_expenses: per(cash), paid_by_others: per(others), noncash_applied: per(applied),
      cash_needed: per(cashNeeded), shortfall: per(Math.max(0, cashNeeded - incomeAnnual)),
      gross_needed: per(Math.max(0, cashNeeded - untaxed) / (1 - tax)), poverty_premium: per(premium), goals: per(goals),
      income: per(incomeAnnual), untaxed_income: per(untaxed), noncash: per(noncashTotal),
      resources: per(incomeAnnual + applied + others),
    };
  };
  const ex = [...(input.expenses || []).filter(on), ...goalLines];
  const at = (/** @type {string} */ lv) => ex.filter((l) => l.level === lv);
  const levels = {
    current: figures(at("current"), "current"),
    survival: figures(at("survival"), "survival"),
    stability: figures(at("stability"), "stability"),
    aspirational: figures([...at("stability"), ...at("aspirational")], "aspirational"),
  };
  return {
    method: METHOD_VERSION,
    as_of: asOf,
    tax_rate_pct: tax * 100,
    income: levels.current.income,       // today's figures, kept at the top for the dashboard
    noncash: levels.current.noncash,
    levels,
  };
}

/** Income kinds that are taxed unless the person says otherwise (SSI, gifts from family and similar are not). */
export const TAXABLE_KINDS = ["wages", "self_employment", "pension"];
/** @param {{kind?: string, taxable?: boolean|null}} x */
export const isTaxable = (x) => x.taxable === true || (x.taxable !== false && (!x.kind || TAXABLE_KINDS.includes(x.kind)));

/** A rough before-tax estimate for people who don't know their tax rate: Social Security and Medicare (7.65%) plus a little income
 * tax that grows with pay. Labeled "rough" on the page; free tax help (VITA) gives a real figure. @param {number} monthlyWages */
export function roughTaxRate(monthlyWages) {
  if (monthlyWages <= 1500) return 8;
  if (monthlyWages <= 3000) return 12;
  if (monthlyWages <= 5000) return 16;
  return 20;
}

/** Today as YYYY-MM-DD in the person's own time zone. */
export function todayISO() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** Days from one YYYY-MM-DD to another. @param {string} from @param {string} to */
export const daysBetween = (from, to) => Math.round((Date.parse(to + "T00:00:00Z") - Date.parse(from + "T00:00:00Z")) / 86400000);

/**
 * Monthly saving a goal needs: what is left divided by the months left (rounded up). 0 without an amount and a future date.
 * Months left = ceil(days x 12 / 365). The SQL version (mirror.goal_monthly) is the same.
 * @param {{target_amount?: number|string|null, current_amount?: number|string|null, target_date?: string|null}} g @param {string} asOf
 */
export function goalMonthly(g, asOf) {
  const left = (Number(g.target_amount) || 0) - (Number(g.current_amount) || 0);
  if (left <= 0 || !g.target_date) return 0;
  const days = daysBetween(asOf, g.target_date);
  if (days <= 0) return 0;
  return left / Math.ceil(days * 12 / 365);
}

/** Money for people: $75.62 @param {number} n */
export const money = (n) => (Number(n) || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });

/**
 * The last day a line counts: its end date; a one-time cost with a start date also ends after its months
 * (start + m months - 1 day, a short month keeps its last day, as in Postgres). Same as mirror.dn_end_on(). @param {any} l
 * @returns {string|null}
 */
export function endOn(l) {
  const end = l.end_on || null;
  if (l.frequency !== "one_time" || !l.start_on) return end;
  const m = Math.max(Number(l.spread_months) || 12, 1);
  const [y, mo, da] = String(l.start_on).split("-").map(Number);
  const t = mo - 1 + Math.trunc(m), ty = y + Math.floor(t / 12), tm = t % 12;
  const last = new Date(Date.UTC(ty, tm + 1, 0)).getUTCDate();
  const spreadEnd = new Date(Date.UTC(ty, tm, Math.min(da, last)) - 86400000).toISOString().slice(0, 10);
  return end && end < spreadEnd ? end : spreadEnd;
}

/** Is a line counted on this day? (active, and between its start and end dates when it has them) @param {any} l @param {string} asOf */
export const inEffect = (l, asOf) => { const end = endOn(l); return l.active !== false && (!l.start_on || l.start_on <= asOf) && (!end || end >= asOf); };

/** "Mar 5, 2027" from YYYY-MM-DD. @param {string} d */
export const shortDate = (d) => new Date(d + "T12:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });

// ---------------------------------------------------------------- Phase 4 step 4: the plan and "what if" (nothing here is saved)

/** Opportunity kinds whose pay is taxed unless the person says otherwise. */
export const OPPORTUNITY_TAXED = ["job", "more_hours", "raise", "side_work"];
/** The income kind an opportunity becomes when it starts (same as mirror_dn_save 'opportunity_start'). */
export const OPPORTUNITY_INCOME_KIND = { job: "wages", more_hours: "wages", raise: "wages", side_work: "self_employment", benefit: "cash_benefit", family: "family_support", training: "other", other: "other" };
/** Is an opportunity's pay taxed? (its own choice, or by kind) @param {any} o */
export const opportunityTaxable = (o) => o.taxable === true || (o.taxable !== false && OPPORTUNITY_TAXED.includes(o.kind));
/**
 * What the person would receive each time: pay before taxes x (1 - tax rate) when the amount is before taxes and taxed,
 * otherwise the amount itself; rounded to cents, as the database does when it starts. @param {any} o @param {number} taxPct
 */
export function takeHome(o, taxPct) {
  const a = Number(o.amount) || 0;
  const t = Math.min(Math.max(Number(taxPct) || 0, 0), 90);
  return o.amount_is_gross !== false && opportunityTaxable(o) ? cents(a * (1 - t / 100)) : a;
}
/** An opportunity as the cash income line it would be. @param {any} o @param {number} taxPct */
export const opportunityAsIncome = (o, taxPct) => ({
  id: "plan-" + (o.id || o.label), kind: OPPORTUNITY_INCOME_KIND[o.kind] || "other", label: o.label, amount: takeHome(o, taxPct),
  frequency: o.frequency, times_per_year: o.times_per_year ?? null, spread_months: o.spread_months ?? null,
  applies_to: o.applies_to ?? null, taxable: opportunityTaxable(o), planned: true });
/** Opportunities still open (an idea or being worked on) count in the plan; started ones are already income, dropped ones never count. */
export const openOpportunities = (opps) => (opps || []).filter((o) => o.status === "idea" || o.status === "working_on");

/**
 * The Daily Number input "if these came true": the person's own input plus the open opportunities as income (no dates,
 * so they count today). @param {any} input @param {any[]} opps
 */
export function withPlan(input, opps) {
  const tax = Number(input.tax_rate_pct) || 0;
  return { ...input, income: [...(input.income || []), ...openOpportunities(opps).map((o) => opportunityAsIncome(o, tax))] };
}

/**
 * "What if": a changed copy of the input. w.stop: ids of costs, income or help that stop; w.amounts: {id: new amount};
 * w.add_income / w.add_expenses / w.add_noncash: extra lines. The person's input is never changed. @param {any} input @param {any} w
 */
export function whatIf(input, w) {
  const stop = new Set(w.stop || []);
  const amt = w.amounts || {};
  const keep = (rows) => (rows || []).filter((x) => !stop.has(x.id)).map((x) => (x.id in amt ? { ...x, amount: Number(amt[x.id]) || 0 } : x));
  return { ...input, expenses: [...keep(input.expenses), ...(w.add_expenses || [])], income: [...keep(input.income), ...(w.add_income || [])],
    noncash: [...keep(input.noncash), ...(w.add_noncash || [])] };
}

/**
 * "How will I generate my Daily Number?": for each level, the monthly gap today, the gap if the open opportunities came true,
 * and how much of the gap they would cover. @param {any} input @param {any[]} opps
 */
export function planEffect(input, opps) {
  const now = dailyNumber(input).levels, plan = dailyNumber(withPlan(input, opps)).levels;
  /** @type {Record<string, {gap_now: number, gap_plan: number, covered: number, added_income: number}>} */ const out = {};
  for (const lv of ["current", "survival", "stability", "aspirational"]) {
    out[lv] = { gap_now: now[lv].shortfall.monthly, gap_plan: plan[lv].shortfall.monthly,
      covered: now[lv].shortfall.monthly - plan[lv].shortfall.monthly, added_income: plan[lv].income.monthly - now[lv].income.monthly };
  }
  return out;
}

/**
 * Who pays what at one level (lines counted on the "as of" day; The life I want includes Stability, as in dailyNumber):
 * monthly amounts by payer, and by household member for costs someone in the household pays ("" = not named).
 * @param {any} input @param {string} lv
 */
export function whoPays(input, lv) {
  const asOf = input.as_of || todayISO();
  const levels = lv === "aspirational" ? ["stability", "aspirational"] : [lv];
  /** @type {{self: number, subsidy: number, assistance: number, donated: number, household: number, members: Record<string, number>}} */
  const out = { self: 0, subsidy: 0, assistance: 0, donated: 0, household: 0, members: {} };
  for (const l of (input.expenses || []).filter((x) => levels.includes(x.level) && inEffect(x, asOf))) {
    const m = annualOf(l) / 12;
    const k = /** @type {"self"|"subsidy"|"assistance"|"donated"|"household"} */ (l.paid_by in out ? l.paid_by : "self");
    out[k] += m;
    if (k === "household") { const id = l.household_member_id || ""; out.members[id] = (out.members[id] || 0) + m; }
  }
  return out;
}
