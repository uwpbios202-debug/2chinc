// LOCAL CHECK ONLY: stands in for /mirror/assets/mirror-client.js with made-up data (served by dn-stub-server.mjs, never deployed).
import { dailyNumber, takeHome, OPPORTUNITY_INCOME_KIND, opportunityTaxable } from "/mirror/assets/daily-number.js?v=20261113e";
export const client = null;
export async function whoami() { return { kind: "individual", name: "Test Person" }; }
export function homeFor() { return "/mirror/my-mirror/"; }
export async function signOut() {}
export function signInBox() {}
export async function requireArea() { return { kind: "individual" }; }
const today = new Date().toISOString().slice(0, 10);
const plus = (d) => new Date(Date.now() + d * 86400000).toISOString().slice(0, 10);
let n = 0; const id = () => "id" + (++n);
const S = {
  inputs: { as_of: today, tax_rate_pct: 10, goals: [],
    expenses: [
      { id: "rent", level: "stability", category: "housing", label: "Rent", amount: 1200, frequency: "monthly", paid_by: "self" },
      { id: "food", level: "stability", category: "food", label: "Food", amount: 400, frequency: "monthly", paid_by: "self" },
      { id: "share", level: "current", category: "housing", label: "Rent share", amount: 600, frequency: "monthly", paid_by: "household", household_member_id: "sis" },
      { id: "bus", level: "current", category: "transportation", label: "Bus", amount: 20, frequency: "weekly", paid_by: "self" },
      { id: "fd2", level: "current", category: "food", label: "Groceries", amount: 300, frequency: "monthly", paid_by: "self" }],
    income: [{ id: "ssi", kind: "cash_benefit", label: "SSI", amount: 943, frequency: "monthly" },
      { id: "gift", kind: "family_support", label: "From my sister", amount: 100, frequency: "monthly", household_member_id: "sis" }],
    noncash: [{ id: "snap", kind: "snap", category: "food", label: "FoodShare", amount: 250, frequency: "monthly" }] },
  plan: { members: [{ id: "sis", label: "My sister", relationship: "sibling", lives_with: true }],
    benefits: [{ id: "b1", program: "FoodShare", kind: "food", status: "active", renewal_on: plus(20), noncash_id: "snap" },
      { id: "b2", program: "SSI", kind: "cash", status: "denied", appeal_by: plus(10) }],
    opportunities: [{ id: "o1", kind: "job", label: "Warehouse job", amount: 300, frequency: "weekly", amount_is_gross: true, status: "working_on", next_step: "Call back Monday", expected_on: plus(14) }] },
};
const get = () => ({ can_edit: true, categories: [], inputs: S.inputs, household_size: 2, goals: [], results: dailyNumber(S.inputs), plan: S.plan, snapshots: [] });
const LIST = { expense: ["inputs", "expenses"], income: ["inputs", "income"], noncash: ["inputs", "noncash"], member: ["plan", "members"], benefit: ["plan", "benefits"], opportunity: ["plan", "opportunities"] };
export async function rpc(fn, a = {}) {
  console.log("[stub rpc]", fn, JSON.stringify(a));
  if (fn === "mirror_dn_get") return get();
  if (fn === "mirror_sets") return [];
  if (fn === "mirror_dn_history") return [];
  if (fn === "mirror_dn_changes") return [
    { at: new Date().toISOString(), who: "Pat Coordinator", organization: "Example Agency", role: "coordinator", list: "living_expenses", label: "Food", action: "removed", field: null, from: '{"amount":"400.00","frequency":"monthly"}', to: null },
    { at: new Date().toISOString(), who: "Pat Coordinator", organization: "Example Agency", role: "coordinator", list: "daily_number_settings", label: "Settings", action: "changed", field: "tax_rate_pct", from: "10.00", to: "12.00" },
    { at: new Date().toISOString(), who: "Pat Coordinator", organization: "Example Agency", role: "coordinator", list: "income_sources", label: "SSI", action: "added", field: null, from: null, to: '{"amount":"943.00","frequency":"monthly"}' },
    { at: new Date().toISOString(), who: "Pat Coordinator", organization: "Example Agency", role: "coordinator", list: "living_expenses", label: "Rent share", action: "changed", field: "household_member_id", from: null, to: "sis" },
    { at: new Date().toISOString(), who: "Pat Coordinator", organization: "Example Agency", role: "coordinator", list: "living_expenses", label: "Rent", action: "changed", field: "amount", from: "1200.00", to: "1150.00" }];
  if (fn === "mirror_dn_save") {
    const p = { ...a.p };
    if (a.p_kind === "settings") { S.inputs.tax_rate_pct = Number(p.tax_rate_pct) || 0; return get().results; }
    if (a.p_kind === "opportunity_start") {
      const o = S.plan.opportunities.find((x) => x.id === p.id); if (o.status === "started") throw new Error("It has already started.");
      const inc = { id: id(), kind: OPPORTUNITY_INCOME_KIND[o.kind], label: o.label, amount: takeHome(o, S.inputs.tax_rate_pct), frequency: o.frequency, start_on: p.start_on, taxable: opportunityTaxable(o) };
      S.inputs.income.push(inc); o.status = "started"; o.income_source_id = inc.id; return get().results;
    }
    const [g, k] = LIST[a.p_kind]; const rows = S[g][k];
    for (const f of ["amount"]) if (f in p) p[f] = Number(String(p[f]).replace(/[$,]/g, ""));
    if (p.lives_with !== undefined) p.lives_with = p.lives_with === true || p.lives_with === "true";
    if (p.amount_is_gross !== undefined) p.amount_is_gross = String(p.amount_is_gross) !== "false";
    if ((p.label === "" && a.p_kind !== "benefit") || (a.p_kind === "benefit" && !p.program)) throw new Error("Give it a short name.");
    if (p.id) Object.assign(rows.find((x) => x.id === p.id), p); else rows.push({ ...p, id: id() });
    return get().results;
  }
  if (fn === "mirror_dn_delete") { const [g, k] = LIST[a.p_kind]; S[g][k] = S[g][k].filter((x) => x.id !== a.p_id); return get().results; }
  throw new Error("stub: " + fn);
}
