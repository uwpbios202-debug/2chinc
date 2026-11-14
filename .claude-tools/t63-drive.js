// TEMPORARY driver for the T6.3 headless check (copied into site/mirror/_t63/, deleted after).
const out = [];
const errs = [];
window.addEventListener("error", (e) => errs.push(e.message));
window.addEventListener("unhandledrejection", (e) => errs.push(String(e.reason)));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const last = (fn) => (window.__calls.filter((c) => c[0] === fn).pop() || [0, {}])[1];
const dupIds = () => { const ids = $$("[id]").map((x) => x.id); return ids.length - new Set(ids).size; };
const kind = document.body.dataset.plan;
(async () => {
  await wait(700);
  if (kind === "plan") {
    out.push("P1 load: h3=" + $$("#mmBox h3").map((h) => h.textContent.trim().replace(/\s+/g, " ")).join(" / ") + " | coord-note=" + $("#mmBox").textContent.includes("added by your coordinator") + " dupIds=" + dupIds());
    const f = $('[data-goal-form="new"]');
    f.requestSubmit(); await wait(50);
    out.push("P2 empty refused: " + f.querySelector("[data-err]").textContent.trim());
    f.querySelector("#gt-new").value = "A place of my own"; f.querySelector("#gd-new").value = "housing";
    f.querySelector('input[name="gs-new"][value="3"]').checked = true; f.querySelector("#gh-new").value = "2027-03-01";
    f.requestSubmit(); await wait(300);
    out.push("P3 added: " + JSON.stringify(last("mirror_goal_save")) + " goals=" + $$("[data-goal]").length);
    $('[data-goal="g1"] [data-goal-step]').click(); await wait(50);
    const sf = $('[data-goal="g1"] [data-step-form]');
    out.push("P4 step form for goal: hidden-for=" + sf.querySelector('input[type=hidden]').value + " dupIds=" + dupIds());
    sf.querySelector('[id^="st-"]').value = "Book the written test"; sf.requestSubmit(); await wait(300);
    out.push("P5 step saved: " + JSON.stringify(last("mirror_action_save")) + " g1-steps=" + $$('[data-goal="g1"] [data-step]').length);
    $('[data-goal="g1"] [data-step="s1"] [data-step-done]').click(); await wait(300);
    out.push("P6 step done: status=" + last("mirror_action_save").status + " text=" + $('[data-step="s1"]').textContent.trim().slice(0, 30));
    $('[data-goal="g1"] [data-goal-reached]').click(); await wait(300);
    out.push("P7 reached: " + last("mirror_goal_save").status + " reached-heading=" + $$("#mmBox h2").some((h) => h.textContent.startsWith("Reached")));
    $('[data-goal="g2"] [data-goal-edit]').click(); await wait(50);
    const ef = $('[data-goal="g2"] [data-goal-form]');
    ef.querySelector("#gu-g2").value = "paused"; ef.querySelector('input[name="gs-g2"][value="1"]').checked = true; ef.requestSubmit(); await wait(300);
    out.push("P8 edit: " + JSON.stringify(last("mirror_goal_save")));
    $('[data-goal="g2"] [data-goal-del]').click(); await wait(50);
    $('[data-goal="g2"] [data-yes]').click(); await wait(300);
    out.push("P9 removed: " + JSON.stringify(last("mirror_plan_delete")) + " g2-gone=" + !$('[data-goal="g2"]'));
  }
  if (kind === "actions") {
    out.push("A1 load: h2=" + $$("#mmBox h2").map((h) => h.textContent).join(" / ") + " helper-tag=" + $("#mmBox").textContent.includes("My sister") + " need=" + $("#mmBox").textContent.includes("for the need: Dentist") + " goal=" + $("#mmBox").textContent.includes("for the goal: Get a CDL"));
    const f = $('[data-step-form="new"]');
    f.querySelector("#st-new").value = "Ask for a fee waiver"; f.querySelector('input[name="sw-new"][value="helper"]').checked = true; f.requestSubmit(); await wait(50);
    out.push("A2 helper needs a name: " + f.querySelector("[data-err]").textContent.trim());
    f.querySelector("#sh-new").value = "My coordinator"; f.querySelector("#sf-new").value = "n:n1"; f.requestSubmit(); await wait(300);
    out.push("A3 added: " + JSON.stringify(last("mirror_action_save")));
    $('[data-step="s2"] [data-step-drop]').click(); await wait(300);
    out.push("A4 dropped: " + last("mirror_action_save").status + " not-doing-heading=" + $$("#mmBox h2").some((h) => h.textContent.startsWith("Not doing")));
    $('[data-step="s1"] [data-step-edit]').click(); await wait(50);
    const ef = $('[data-step="s1"] form');
    out.push("A5 edit form preselects goal: " + ef.querySelector('[id^="sf-"]').value + " dupIds=" + dupIds());
    ef.querySelector('[id^="st-"]').value = "Get the CDL handbook"; ef.requestSubmit(); await wait(300);
    out.push("A6 saved: " + JSON.stringify(last("mirror_action_save")));
  }
  if (kind === "milestones") {
    out.push("M1 load: items=" + $$("[data-ms]").length + " confirmed-tag=" + $("#mmBox").textContent.includes("Confirmed by an organization") + " date-max=" + !!$("#mo-new").max);
    const f = $('[data-ms-form="new"]');
    f.querySelector("#mt-new").value = "First week at the new job"; f.querySelector("#mg-new").value = "g1"; f.requestSubmit(); await wait(300);
    out.push("M2 added: " + JSON.stringify(last("mirror_milestone_save")) + " items=" + $$("[data-ms]").length);
    $('[data-ms="m1"] [data-ms-edit]').click(); await wait(50);
    const ef = $('[data-ms="m1"] form'); ef.querySelector('[id^="mt-"]').value = "Got my Wisconsin ID"; ef.requestSubmit(); await wait(300);
    out.push("M3 edit: " + JSON.stringify(last("mirror_milestone_save")));
    $('[data-ms="m1"] [data-ms-del]').click(); await wait(50); $('[data-ms="m1"] [data-yes]').click(); await wait(300);
    out.push("M4 removed: items=" + $$("[data-ms]").length);
  }
  out.push("errors=" + JSON.stringify(errs));
  const pre = document.createElement("pre"); pre.id = "T63OUT"; pre.textContent = out.join("\n"); document.body.append(pre);
})();
