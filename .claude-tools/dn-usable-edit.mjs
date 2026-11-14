// One-off edit (Stephen 11/13/2026, Daily Number step 3 "make it usable") of site/mirror/assets/daily-number-page.js.
import fs from "node:fs";
const f = "site/mirror/assets/daily-number-page.js";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (!s.includes(a)) throw new Error("miss: " + a.slice(0, 90)); s = s.split(a).join(b); };

rep(`import { voiceAll } from "/mirror/assets/mirror-voice.js?v=20261113c";`,
  `import { voiceAll } from "/mirror/assets/mirror-voice.js?v=20261113c";
import { runSet } from "/mirror/assets/assessment-engine.js?v=20261113h";`);
rep(`  ["aspirational", "aspirations/", "The life I want"], ["income", "income/", "Income and support"], ["gap", "gap/", "The gap"], ["history", "history/", "History"],
];`, `  ["aspirational", "aspirations/", "The life I want"], ["income", "income/", "Income and support"], ["gap", "gap/", "The gap"], ["history", "history/", "History"],
  ["reflect", "reflect/", "Reflect"],
];

// Suggested costs per list (Stephen's Daily Number paper: what each level includes). [category, label, how often, hint]
const SUGGEST = {
  current: [["housing", "Where I stay", "monthly", "Rent, a room, a shelter fee, or what you give family. If someone else pays, choose who pays."],
    ["food", "Food and drinking water", "weekly"], ["communication", "Phone", "monthly"], ["transportation", "Getting around", "weekly", "Bus fares, a pass, gas, rides."],
    ["healthcare", "Medicine and health care", "monthly"], ["personal_care", "Hygiene and toiletries", "monthly"], ["clothing", "Clothing and shoes", "monthly"],
    ["household", "Laundry and cleaning", "weekly"], ["financial", "Debts and fees", "monthly", "Payments on debts, bank or check-cashing fees, late fees."]],
  survival: [["housing", "Safe place to stay", "monthly", "A shelter bed, a room, or a safe temporary place. If it's free, choose \"It's donated or free\"."],
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
  ["overdraft", "Overdraft fees", "financial", "monthly", "A bank account with no overdraft fees (look for \"Bank On\" accounts)."],
  ["check_cashing", "Check-cashing fees", "financial", "monthly", "A free checking account with direct deposit."],
  ["payday_loan", "Payday or title loan costs", "financial", "monthly", "Credit-union small loans or interest-free emergency loans; ask your coordinator."],
  ["rent_to_own", "Rent-to-own furniture or appliances", "household", "monthly", "Donated furniture programs, or saving to buy outright."],
  ["no_reserve", "No savings for surprises (costs that pile up)", "financial", "irregular", "A small emergency reserve, built a little at a time (add it as a savings goal)."],
  ["other", "Something else that costs more because money is tight", "household", "monthly", "Talk it over with your coordinator; there may be a cheaper way."],
];
const PREMIUM = Object.fromEntries(PREMIUMS.map((p) => [p[0], p]));
const SKIP_KEY = (lv) => "mm-dn-skip-" + lv;   // per-device convenience: suggestions the person said don't apply
const skipped = (lv) => { try { return JSON.parse(localStorage.getItem(SKIP_KEY(lv)) || "[]"); } catch { return []; } };
const skip = (lv, label) => { try { localStorage.setItem(SKIP_KEY(lv), JSON.stringify([...new Set([...skipped(lv), label])])); } catch { /* blocked */ } };`);

// router
rep(`  else if (page === "history") history(body);`, `  else if (page === "history") history(body);
  else if (page === "reflect") reflect(body);`);

// ---------------------------------------------------------------- level page: suggested costs
rep(`    \${others.length ? \`<p class="mm-row"><span class="mm-muted mm-small">Start from another list:</span>`,
  `    \${suggestPanel(lv, own)}
    \${others.length ? \`<p class="mm-row"><span class="mm-muted mm-small">Start from another list:</span>`);
rep(`  body.querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", async () => {`,
  `  body.querySelectorAll("[data-suggest]").forEach((b) => b.addEventListener("click", () => {
    const [cat, label, freq] = SUGGEST[lv][Number(b.dataset.suggest)];
    form({ id: "", category: cat, label, frequency: freq, paid_by: "self" });
    body.querySelector("#dnForm").scrollIntoView({ block: "start" });
    /** @type {HTMLElement|null} */ (body.querySelector("#exAmt"))?.focus();
  }));
  body.querySelectorAll("[data-skip]").forEach((b) => b.addEventListener("click", () => { skip(lv, b.dataset.skip); reload(lv); }));
  body.querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", async () => {`);

// expense form: prefill without being an edit; the cost-of-being-poor pick-list
rep(`function expenseForm(el, lv, x) {`, `/** Suggested costs for a list, with the ones already added ticked and "doesn't apply" ones hidden. */
function suggestPanel(lv, own) {
  const have = own.map((x) => String(x.label).toLowerCase());
  const gone = skipped(lv);
  const items = (SUGGEST[lv] || []).map((it, i) => [it, i]).filter(([it]) => !gone.includes(it[1]));
  if (!items.length) return "";
  const done = items.filter(([it]) => have.includes(it[1].toLowerCase())).length;
  return \`<details class="mm-card mm-read" style="margin:var(--mm-space-5) 0"\${done < items.length ? " open" : ""}>
    <summary style="cursor:pointer;font-weight:700">Checklist: costs most people have here (\${done} of \${items.length} added)</summary>
    <p class="mm-hint" style="margin-top:var(--mm-space-3)">Press one to add it; you only type the amount. If it doesn't apply to you, press "Not for me".</p>
    <ul class="mm-checklist">\${items.map(([[, label, , hint], i]) => have.includes(label.toLowerCase())
      ? \`<li class="mm-done"><span aria-hidden="true">✓</span> \${esc(label)} <span class="mm-muted mm-small">added</span></li>\`
      : \`<li><button class="mm-btn mm-btn-secondary" type="button" data-suggest="\${i}">Add: \${esc(label)}</button>
          <button class="mm-btn mm-btn-quiet" type="button" data-skip="\${esc(label)}">Not for me</button>\${hint ? \`<br><span class="mm-hint">\${esc(hint)}</span>\` : ""}</li>\`).join("")}</ul>
  </details>\`;
}

function expenseForm(el, lv, x, after = lv) {
  const editing = !!(x && x.id);`);
rep(`    <h2 style="margin-top:0">\${x ? "Change this cost" : "Add a cost"}</h2>`, `    <h2 style="margin-top:0">\${editing ? "Change this cost" : "Add a cost"}</h2>`);
rep(`    <label class="mm-choice" style="margin-bottom:var(--mm-space-2)"><input type="checkbox" id="exPoor" \${x && x.poverty_premium ? "checked" : ""}> This costs more because money is tight (a cost that could go down)</label>
    <p class="mm-hint">\${esc(POOR_HELP)}</p>`,
  `    <div class="mm-field"><label for="exPoorKind">Does this cost more because money is tight?</label>
      <span class="mm-hint">People with little money often pay more for the same things. Marking it shows a cheaper way on "The gap".</span>
      \${sel("exPoorKind", [["", "No"], ...PREMIUMS.map((p) => [p[0], p[1]])], x ? (x.premium_kind || (x.poverty_premium ? "other" : "")) : "")}</div>`);
rep(`    <div class="mm-row"><button class="mm-btn" type="submit">\${x ? "Save the change" : "Add this cost"}</button>
      \${x ? '<button class="mm-btn mm-btn-secondary" type="button" id="exCancel">Cancel</button><button class="mm-btn mm-btn-quiet" type="button" id="exDel">Remove</button>' : ""}</div>`,
  `    <div class="mm-row"><button class="mm-btn" type="submit">\${editing ? "Save the change" : "Add this cost"}</button>
      \${x ? '<button class="mm-btn mm-btn-secondary" type="button" id="exCancel">Cancel</button>' : ""}\${editing ? '<button class="mm-btn mm-btn-quiet" type="button" id="exDel">Remove</button>' : ""}</div>`);
rep(`  f.querySelector("#exCancel")?.addEventListener("click", () => expenseForm(el, lv, null));`, `  f.querySelector("#exCancel")?.addEventListener("click", () => expenseForm(el, lv, null, after));`);
rep(`    try { await rpc("mirror_dn_delete", { p_kind: "expense", p_id: x.id }); reload(lv, "Removed."); } catch (err) { errBox(f.querySelector("#exMsg"), err); }`,
  `    try { await rpc("mirror_dn_delete", { p_kind: "expense", p_id: x.id }); reload(after, "Removed."); } catch (err) { errBox(f.querySelector("#exMsg"), err); }`);
rep(`      await rpc("mirror_dn_save", { p_kind: "expense", p: { id: x ? x.id : "", level: lv, category: v(f, "exCat"), label: v(f, "exLabel"), amount: v(f, "exAmt"),`,
  `      await rpc("mirror_dn_save", { p_kind: "expense", p: { id: editing ? x.id : "", level: lv, category: v(f, "exCat"), label: v(f, "exLabel"), amount: v(f, "exAmt"),`);
rep(`        poverty_premium: /** @type {HTMLInputElement} */ (f.querySelector("#exPoor")).checked, note: v(f, "exNote"),`,
  `        premium_kind: v(f, "exPoorKind"), poverty_premium: !!v(f, "exPoorKind"), note: v(f, "exNote"),`);
rep(`      reload(lv, x ? "Saved." : "Added.");
    } catch (err) { errBox(f.querySelector("#exMsg"), err); }`, `      reload(after, editing ? "Saved." : "Added.");
    } catch (err) { errBox(f.querySelector("#exMsg"), err); }`);

// ---------------------------------------------------------------- the gap: a cheaper way for each marked cost, and the pick-list
rep(`      <ul>\${poor.map((x) => \`<li>\${esc(x.label)} (\${esc(LEVEL[x.level].short)}): \${esc(fmtLine(x))}</li>\`).join("")}</ul>\``,
  `      <ul class="mm-cheaper">\${poor.map((x) => \`<li><strong>\${esc(x.label)}</strong> (\${esc(LEVEL[x.level].short)}): \${esc(fmtLine(x))}
        <br><span class="mm-small">A cheaper way: \${esc((PREMIUM[x.premium_kind || "other"] || PREMIUM.other)[4])}</span></li>\`).join("")}</ul>\``);
rep(`      : notice("info", \`<p>None marked yet. When you add a cost, tick "This costs more because money is tight" for things like \${esc(POOR_HELP.replace(/^For example /, "").replace(/\\.$/, ""))}.</p>\`)}\`;`,
  `      : notice("info", "<p>None marked yet. Do any of these sound like you? Press one to add it to Today.</p>")}
    <details class="mm-card mm-read" style="margin-top:var(--mm-space-4)"\${poor.length ? "" : " open"}><summary style="cursor:pointer;font-weight:700">Common costs of being poor</summary>
      <ul class="mm-checklist" style="margin-top:var(--mm-space-3)">\${PREMIUMS.filter((p) => p[0] !== "other").map((p) => \`<li><button class="mm-btn mm-btn-secondary" type="button" data-premium="\${p[0]}">Add: \${esc(p[1])}</button>
        <br><span class="mm-hint">A cheaper way: \${esc(p[4])}</span></li>\`).join("")}</ul></details>
    <div id="dnForm"></div>\`;
  body.querySelectorAll("[data-premium]").forEach((b) => b.addEventListener("click", () => {
    const p = PREMIUM[b.dataset.premium];
    expenseForm(body.querySelector("#dnForm"), "current", { id: "", category: p[2], label: p[1], frequency: p[3], times_per_year: p[3] === "irregular" ? 4 : null, paid_by: "self", premium_kind: p[0] }, "gap");
    body.querySelector("#dnForm").scrollIntoView({ block: "start" });
    /** @type {HTMLElement|null} */ (body.querySelector("#exAmt"))?.focus();
  }));`);

// ---------------------------------------------------------------- Reflect: the six Daily Number reflections on the question engine
s += `
// ---------------------------------------------------------------- the six Daily Number reflections (Stephen's paper, section 6)
async function reflect(body) {
  const key = new URLSearchParams(location.search).get("s") || "";
  let sets;
  try { sets = (await rpc("mirror_sets", { p_kind: "module" })).filter((x) => /^dn_/.test(x.key)); }
  catch (e) { errBox(body, e); return; }
  const set = sets.find((x) => x.key === key);
  if (!set) {
    body.innerHTML = \`<div class="mm-read"><h1>Think it through</h1>
      <p class="mm-lead">Six short reflections on money and your life, in your own words. Speak or type; skip anything. Your numbers are on the other tabs; these are the story behind them.</p></div>
      <div class="mm-grid">\${sets.map((x, i) => \`<a class="mm-card" href="\${BASE}reflect/?s=\${encodeURIComponent(x.key)}">
        <div class="mm-card-num">\${i + 1}</div><h3>\${esc(x.title)}</h3><p class="mm-muted">\${esc(x.intro || "")}</p>
        \${countBar(x.answered, x.questions, "answered")}</a>\`).join("")}</div>\`;
    return;
  }
  const i = sets.indexOf(set);
  const nxt = sets.slice(i + 1).find((x) => x.answered < x.questions) || sets.find((x) => x !== set && x.answered < x.questions);
  body.innerHTML = \`<div class="mm-read"><p class="mm-eyebrow"><a href="\${BASE}reflect/">Think it through</a> · \${i + 1} of \${sets.length}</p>
    <h1>\${esc(set.title)}</h1><p class="mm-lead">\${esc(set.intro || "")}</p></div><div id="dnSet"></div>\`;
  runSet(/** @type {HTMLElement} */ (body.querySelector("#dnSet")), set.key, {
    nextLink: nxt ? { href: \`\${BASE}reflect/?s=\${encodeURIComponent(nxt.key)}\`, label: "Next: " + nxt.title } : { href: BASE, label: "Back to My Daily Number" } });
}
`;

fs.writeFileSync(f, s);
console.log("ok");
