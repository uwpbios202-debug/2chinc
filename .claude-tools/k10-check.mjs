// K-10 local check: runs the printable copy's dailyNumberPrint on made-up data (nothing live).
import fs from "node:fs";
import { pathToFileURL } from "node:url";
const dnmod = await import(pathToFileURL("site/mirror/assets/daily-number.js").href);
const src = fs.readFileSync("site/mirror/my-mirror/settings/index.html", "utf8");
const a = src.indexOf("function dailyNumberPrint"), b = src.indexOf("/** A readable copy for printing");
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const fn = new Function("esc", "planEffect", "takeHome", "openOpportunities", src.slice(a, b) + "\nreturn dailyNumberPrint;")(esc, dnmod.planEffect, dnmod.takeHome, dnmod.openOpportunities);
const inputs = { as_of: "2026-11-13", tax_rate_pct: 10, goals: [],
  expenses: [{ id: "rent", level: "stability", category: "housing", label: "Rent", amount: 1200, frequency: "monthly", paid_by: "self" },
    { id: "food", level: "stability", category: "food", label: "Food", amount: 400, frequency: "monthly", paid_by: "self" },
    { id: "share", level: "current", category: "housing", label: "Rent share", amount: 600, frequency: "monthly", paid_by: "household", household_member_id: "sis" }],
  income: [{ id: "ssi", kind: "cash_benefit", label: "SSI", amount: 943, frequency: "monthly" },
    { id: "gift", kind: "family_support", label: "From my sister", amount: 100, frequency: "monthly", household_member_id: "sis" }],
  noncash: [] };
const plan = { members: [{ id: "sis", label: "My sister", relationship: "sibling", lives_with: true }],
  benefits: [{ id: "b2", program: "SSI", kind: "cash", status: "denied", appeal_by: "2026-11-23" }],
  opportunities: [{ id: "o1", kind: "job", label: "Warehouse job", amount: 300, frequency: "weekly", amount_is_gross: true, status: "working_on", next_step: "Call back Monday", expected_on: "2026-11-27" }] };
const out = fn({ inputs, results: dnmod.dailyNumber(inputs), plan });
console.log(out.replace(/<(li|h3|p|br)>/g, "\n").replace(/<[^>]+>/g, ""));
console.log("\nempty plan, no lines:", JSON.stringify(fn({ inputs: { ...inputs, expenses: [], income: [] }, results: dnmod.dailyNumber(inputs), plan: { members: [], benefits: [], opportunities: [] } })));
console.log("old export without plan:", fn({ inputs, results: dnmod.dailyNumber(inputs) }).includes("My household") ? "BAD" : "ok");
