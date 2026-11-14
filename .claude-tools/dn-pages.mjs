// One-off generator: the 8 Daily Number pages + the public explainer (Stephen 11/13/2026, Phase 4 T4.3).
import fs from "node:fs";
const head = (title) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>${title} | The Human Mirror</title>
<link rel="icon" href="/favicon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&family=Source+Serif+4:opsz,wght@8..60,600&display=swap">
<link rel="stylesheet" href="/mirror/assets/mirror.css?v=20261113l">
</head>`;
const PAGES = [["home", "", "My Daily Number"], ["current", "today/", "Today"], ["survival", "survival/", "Survival"], ["stability", "stability/", "Stability"],
  ["aspirational", "aspirations/", "The Life I Want"], ["income", "income/", "Income and Support"], ["gap", "gap/", "The Gap"], ["history", "history/", "History"], ["reflect", "reflect/", "Think It Through"]];
for (const [key, path, title] of PAGES) {
  const dir = "site/mirror/my-mirror/daily-number/" + path;
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "index.html", `${head(title)}
<body data-area="my" data-dn="${key}">
<!-- Generated from one template (all Daily Number pages are the same apart from data-dn). -->
<main id="main" class="mm-main">
  <div id="mmDn"><p role="status">Loading…</p></div>
</main>
<script type="module" src="/mirror/assets/mirror-ui.js?v=20261113h"></script>
<script type="module">
import { dailyNumberPage } from "/mirror/assets/daily-number-page.js?v=20261113e";
dailyNumberPage();
</script>
</body>
</html>
`);
}

// Public explainer with a calculator that saves nothing (prompt Part 6 /daily-number; the paper's section 4 example).
fs.mkdirSync("site/mirror/daily-number", { recursive: true });
fs.writeFileSync("site/mirror/daily-number/index.html", `${head("The Daily Number")}
<body data-area="public">
<main id="main" class="mm-main" data-mm-listen>
  <div class="mm-read">
    <p class="mm-eyebrow">The Daily Number</p>
    <h1>Know your cost. Understand your resources. Build your future.</h1>
    <p class="mm-lead">365 days. One life. A plan for every day. The Daily Number is what one day of your life costs, on average.</p>
    <p>Every person has a daily cost of living, even with no income, no savings and no home: the cost of living in a city does not become zero
      because income is zero. Thinking one day at a time makes that cost easier to understand, because a day is how we live.</p>
    <p><strong>Daily Number = what your life costs in a year ÷ 365.</strong> A $600 yearly insurance bill is not $600 a month; it adds about $1.64 to each day.</p>
    <h2>Three numbers, not one</h2>
    <ul>
      <li><strong>Survival:</strong> what it costs to stay safe, fed, clean, connected and alive for one day. The immediate minimum.</li>
      <li><strong>Stability:</strong> what it costs to keep a secure, independent life: rent, utilities, food, getting around, phone, health care, savings.</li>
      <li><strong>The life you want:</strong> stability plus your own goals: learning, family, interests, savings, a business, giving back.</li>
    </ul>
    <p class="mm-muted">These are not standards of human worth. They are different money situations, and the possibilities in each.</p>
    <h2>Cost is not the same as income</h2>
    <p>Benefits, housing help, SNAP and donated things lower what you pay, but they are not cash income, and the Mirror keeps them apart.
      If life costs $75 a day after taxes, you may need to earn more than $75 a day before taxes. You don't have to earn every dollar:
      affordable housing, health coverage, benefits and community help all lower the cash you need.</p>
  </div>
  <form class="mm-card" id="calc" novalidate>
    <h2 style="margin-top:0">Try it: a quick example</h2>
    <p class="mm-muted">Enter monthly amounts. Use 0 if something doesn't apply. Nothing you type here is saved or sent anywhere.</p>
    <div class="mm-calc" id="calcFields"></div>
    <div class="mm-grid" style="margin-top:var(--mm-space-5)" aria-live="polite">
      <div><div class="mm-figure-label">Your Daily Number</div><div class="mm-figure" id="cDaily">$0.00</div></div>
      <div><div class="mm-figure-label">A week</div><div class="mm-figure" style="font-size:1.8rem" id="cWeek">$0.00</div></div>
      <div><div class="mm-figure-label">A month</div><div class="mm-figure" style="font-size:1.8rem" id="cMonth">$0.00</div></div>
      <div><div class="mm-figure-label">A year</div><div class="mm-figure" style="font-size:1.8rem" id="cYear">$0.00</div></div>
    </div>
    <p class="mm-row" style="margin-top:var(--mm-space-4)"><button class="mm-btn mm-btn-secondary" type="button" id="cExample">Fill in the example ($2,300 a month)</button>
      <button class="mm-btn mm-btn-quiet" type="button" id="cClear">Clear</button></p>
    <p class="mm-muted mm-small">In your own Mirror, each cost can be daily, weekly, monthly, yearly or now and then, and help from programs is kept apart from cash.</p>
  </form>
  <p class="mm-row" style="margin-top:var(--mm-space-5)"><a class="mm-btn" href="/mirror/how-it-works/">How the Mirror works</a></p>
</main>
<script type="module" src="/mirror/assets/mirror-ui.js?v=20261113h"></script>
<script type="module" src="/mirror/assets/mirror-voice.js?v=20261113c"></script>
<script type="module">
import { dailyNumber, money } from "/mirror/assets/daily-number.js?v=20261113c";
const F = [["housing", "Housing", 1000], ["utilities", "Utilities", 150], ["food", "Food", 400], ["transportation", "Getting around", 150],
  ["healthcare", "Health care", 100], ["communication", "Phone and internet", 80], ["clothing", "Personal care and clothing", 120],
  ["household", "Household and other", 100], ["future", "Savings and emergency reserve", 200], ["financial", "Other monthly costs", 0]];
const box = document.getElementById("calcFields");
box.innerHTML = F.map(([k, l]) => '<div class="mm-field"><label for="c_' + k + '">' + l + '</label><div class="mm-money"><span aria-hidden="true">$</span><input class="mm-input" id="c_' + k + '" inputmode="decimal" data-mm-no-voice value="0"></div></div>').join("");
const run = () => {
  const r = dailyNumber({ expenses: F.map(([k]) => ({ level: "current", category: k, amount: Number(document.getElementById("c_" + k).value.replace(/[$,]/g, "")) || 0, frequency: "monthly", paid_by: "self" })), income: [], noncash: [] });
  const c = r.levels.current.cost;
  document.getElementById("cDaily").textContent = money(c.daily); document.getElementById("cWeek").textContent = money(c.weekly);
  document.getElementById("cMonth").textContent = money(c.monthly); document.getElementById("cYear").textContent = money(c.annual);
};
box.addEventListener("input", run);
document.getElementById("cExample").addEventListener("click", () => { F.forEach(([k, , v]) => { document.getElementById("c_" + k).value = v; }); run(); });
document.getElementById("cClear").addEventListener("click", () => { F.forEach(([k]) => { document.getElementById("c_" + k).value = 0; }); run(); });
run();
</script>
</body>
</html>
`);
console.log("9 pages");
