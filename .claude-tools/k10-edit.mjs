// K-10: adds household, benefits and the plan to the printable copy's Daily Number part.
// Usage: node .claude-tools/k10-edit.mjs <file>   (applies the same replacements to any copy of settings/index.html)
import fs from "node:fs";
const f = process.argv[2];
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (s.split(a).length !== 2) { console.error("not found once: " + a.slice(0, 60)); process.exit(1); } s = s.replace(a, () => b); };

rep(`import { voiceSettings } from "/mirror/assets/mirror-voice.js?v=20261113c";`,
`import { voiceSettings } from "/mirror/assets/mirror-voice.js?v=20261113c";
import { planEffect, takeHome, openOpportunities } from "/mirror/assets/daily-number.js?v=20261113e";`);

rep(`/** The Daily Number part of the printable copy. */
function dailyNumberPrint(dn) {
  if (!dn || !dn.inputs || (!dn.inputs.expenses.length && !dn.inputs.income.length)) return "";
  const m = (n) => (Number(n) || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
  const L = dn.results.levels, NAME = { current: "Today", survival: "Survival", stability: "Stability", aspirational: "The life I want" };
  const line = (x) => esc(x.label) + ": " + m(x.amount) + " " + esc(String(x.frequency).replace("_", " ")) + (x.start_on ? " from " + esc(x.start_on) : "") + (x.end_on ? " until " + esc(x.end_on) : "");`,
`/** The Daily Number part of the printable copy (with household, benefits and the plan: K-10). */
function dailyNumberPrint(dn) {
  const P = (dn && dn.plan) || { members: [], benefits: [], opportunities: [] };
  if (!dn || !dn.inputs || (!dn.inputs.expenses.length && !dn.inputs.income.length && !P.members.length && !P.benefits.length && !P.opportunities.length)) return "";
  const m = (n) => (Number(n) || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
  const L = dn.results.levels, NAME = { current: "Today", survival: "Survival", stability: "Stability", aspirational: "The life I want" };
  const who = Object.fromEntries(P.members.map((x) => [x.id, x.label]));
  const by = (x) => x.paid_by === "household" ? " (paid by " + esc(who[x.household_member_id] || "someone in my household") + ")"
    : x.household_member_id && who[x.household_member_id] ? " (from " + esc(who[x.household_member_id]) + ")" : "";
  const line = (x) => esc(x.label) + ": " + m(x.amount) + " " + esc(String(x.frequency).replace("_", " ")) + (x.start_on ? " from " + esc(x.start_on) : "") + (x.end_on ? " until " + esc(x.end_on) : "") + by(x);
  const REL = { partner: "partner or spouse", child: "child", parent: "parent", sibling: "brother or sister", other_family: "other family", friend: "friend", roommate: "roommate", other: "other" };
  const BST = { considering: "thinking about applying", applied: "applied, waiting", active: "getting it now", denied: "denied", appealing: "appealing", ended: "ended" };
  const OST = { idea: "an idea", working_on: "working on it", started: "started", dropped: "not going ahead" };
  const dates = (b) => [["applied", b.applied_on], ["approved", b.approved_on], ["renewal due", b.renewal_on], ["appeal by", b.appeal_by], ["ends", b.ends_on]]
    .filter((d) => d[1]).map((d) => d[0] + " " + esc(d[1])).join(", ");
  const tax = Number(dn.inputs.tax_rate_pct) || 0;
  const opp = (o) => esc(o.label) + ": " + m(o.amount) + " " + esc(String(o.frequency).replace("_", " ")) + (o.amount_is_gross !== false && takeHome(o, tax) !== Number(o.amount) ? " before taxes (" + m(takeHome(o, tax)) + " take-home)" : "")
    + " · " + esc(OST[o.status] || o.status) + (o.expected_on ? " · could start " + esc(o.expected_on) : "") + (o.next_step ? " · next step: " + esc(o.next_step) : "");
  const eff = openOpportunities(P.opportunities).length ? planEffect(dn.inputs, P.opportunities) : null;
  const planHtml = (P.members.length ? "<h3>My household</h3><ul>" + P.members.map((x) => "<li>" + esc(x.label) + " (" + esc(REL[x.relationship] || x.relationship) + (x.lives_with ? ", lives with me" : ", doesn't live with me") + ")" + (x.note ? ": " + esc(x.note) : "") + "</li>").join("") + "</ul>" : "")
    + (P.benefits.length ? "<h3>My benefits</h3><ul>" + P.benefits.map((b) => "<li>" + esc(b.program) + (b.agency ? " (" + esc(b.agency) + ")" : "") + ": " + esc(BST[b.status] || b.status) + (dates(b) ? "; " + dates(b) : "") + (b.note ? ". " + esc(b.note) : "") + "</li>").join("") + "</ul>" : "")
    + (P.opportunities.length ? "<h3>My plan: how I will generate my Daily Number</h3><ul>" + P.opportunities.map((o) => "<li>" + opp(o) + "</li>").join("") + "</ul>" : "")
    + (eff ? "<p>If the plan items that are ideas or being worked on came true, the monthly gap would be: " + Object.keys(NAME).map((k) => NAME[k] + " " + m(eff[k].gap_now) + " now, " + m(eff[k].gap_plan) + " then").join("; ") + ".</p>" : "");`);

rep(`    \${dn.inputs.goals.length ? "<h3>Savings goals</h3><ul>" + dn.inputs.goals.map((g) => "<li>" + esc(g.label) + ": " + m(g.current_amount) + " of " + m(g.target_amount) + (g.target_date ? " by " + esc(g.target_date) : "") + "</li>").join("") + "</ul>" : ""}\`;`,
`    \${dn.inputs.goals.length ? "<h3>Savings goals</h3><ul>" + dn.inputs.goals.map((g) => "<li>" + esc(g.label) + ": " + m(g.current_amount) + " of " + m(g.target_amount) + (g.target_date ? " by " + esc(g.target_date) : "") + "</li>").join("") + "</ul>" : ""}
    \${planHtml}\`;`);

fs.writeFileSync(f, s);
console.log("ok " + f);
