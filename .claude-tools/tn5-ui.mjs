import fs from "node:fs";
const f = "site/assets/portal/nav-common.js";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (s.split(a).length !== 2) { console.log("MISS or not unique:", a.slice(0, 80)); process.exit(1); } s = s.replace(a, b); };
rep(`  const plan = s === "moved_in" ? \`<div class="banner"><b>Check-in plan:</b>`,
`  // TN.5 (migration 20261119650000): check-ins can start at the first meeting, once the housing consent is signed.
  const canPlan = s === "moved_in" || (s !== "closed" && r.consent_on && !r.consent_withdrawn_on);
  const plan = canPlan && s !== "moved_in" && !r.next_checkin_on ? \`<div class="banner"><b>Check-ins:</b> none planned yet. You can start them now, before housing: meeting regularly from the first meeting helps the whole plan, not only the housing search.
      <div class="row" style="margin-top:6px"><button class="btn small" data-act="plan-edit">Start check-ins</button></div></div>\`
    : canPlan ? \`<div class="banner"><b>Check-in plan:</b>`);
rep(`Recording a check-in puts the next one on the calendar. The 90-day and 12-month stability reviews stay fixed.</div></div>\` : "";`,
`Recording a check-in puts the next one on the calendar. \${s === "moved_in" ? "The 90-day and 12-month stability reviews stay fixed." : "At move-in the plan continues and the 90-day and 12-month stability reviews are added."}</div></div>\` : "";`);
rep(`\${f.note ? \`<div class="sub">\${esc(f.note)}</div>\` : ""}<div class="sub">\${fmtDate(f.done_on)}</div>\``,
`\${f.note ? \`<div class="sub">\${esc(f.note)}</div>\` : ""}<div class="sub">\${fmtDate(f.done_on)}\${f.mirror_need_id ? " · linked to a need in their Mirror" : ""}</div>\``);
rep(`      : s === "moved_in" ? \`<div class="furow" data-fu="\${esc(f.id)}">`, `      : s !== "closed" ? \`<div class="furow" data-fu="\${esc(f.id)}">`);
rep(`          <label class="chk"><input type="checkbox" checked> Rent current</label><input class="field" placeholder="Short note">`,
`          \${s === "moved_in" ? '<label class="chk"><input type="checkbox" checked> Rent current</label>' : ""}<input class="field" placeholder="Short note">`);
rep(`      <div class="sub">The Mirror has its own sign-in at https://2ndchinc.org/mirror/sign-in/ with an authenticator app.</div>\` : ""}</div>\`;`,
`      <a class="btn small" href="https://2ndchinc.org/mirror/workspace/checkins/?id=\${encodeURIComponent(m.individual_id)}&org=\${encodeURIComponent(m.organization_id)}" target="_blank" rel="noopener">Check-ins and their Mirror needs</a>
      <div class="sub">The Mirror has its own sign-in at https://2ndchinc.org/mirror/sign-in/ with an authenticator app.</div>\` : ""}</div>\`;`);
fs.writeFileSync(f, s);
for (const p of ["site/navigator/index.html", "site/navigator/unit/index.html", "site/staff/navigators/index.html"]) {
  let x = fs.readFileSync(p, "utf8"); const n = x.split("nav-common.js?v=20261113c").length - 1;
  x = x.replaceAll("nav-common.js?v=20261113c", "nav-common.js?v=20261113d"); fs.writeFileSync(p, x); console.log(p, n);
}
console.log("ok");
