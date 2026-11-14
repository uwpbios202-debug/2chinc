// Shared pieces for the researcher course deck (tools/build-course.mjs). Everything in the examples is FICTIONAL.
// The deck engine, header and controls come from site/probate-help/index.html (same engine as the other decks).
// Keep the spoken text (`say`) free of digits and abbreviations a voice would misread: it is also the caption text and the transcript.
export const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

export const CHECKED = "10/29/2026"; // the day statutes and official pages were read for this course

export const MODULES = [
  ["S", "Start here"], ["A", "Why this work matters"], ["B", "Finding a potential case"], ["C", "Family outreach and consent"],
  ["D", "Intake and urgent issues"], ["E", "Ownership and possible routes"], ["F", "Building the family evidence"], ["G", "Documents and financial facts"],
  ["H", "Using our system, field by field"], ["I", "The attorney's opening package"], ["J", "Quality control and handoff"], ["K", "What happens after filing"], ["L", "Practice and readiness"],
];

export const slides = [];
export const add = (s) => { slides.push(s); return s; };
export const modTitle = (m, h, sub, say, bullets = []) => add({ m, kind: "mod", h, sub, bullets, say });

// ---- small building blocks (course look; the dark deck theme is in the template) ----------------------------------------
export const TAG = {
  sys: `<span class="tg2 sys" title="Read in the page's own code on ${CHECKED}">In the system</span>`,
  man: `<span class="tg2 man" title="Not in the system: done by hand">By hand, outside the system</span>`,
  cns: `<span class="tg2 cns" title="Counsel, the court or the title company decides">Counsel decides</span>`,
  unv: `<span class="tg2 unv" title="Not verified">Not verified</span>`,
  ill: `<span class="tg2 ill" title="A drawing built from the page's labels, not a photograph of a real case">Illustration</span>`,
};
export const LIST = (items, cls = "") => `<ul class="ls ${cls}">${items.map((t) => `<li>${t}</li>`).join("")}</ul>`;
export const CHECKS = (items) => `<ul class="ls chk">${items.map((t) => `<li><span class="bx" aria-hidden="true"></span>${t}</li>`).join("")}</ul>`;
export const BOX = (title, inner, c = "var(--leaf)") => `<div class="box top" style="--c:${c}"><h3>${title}</h3>${inner}</div>`;
export const G2B = (...b) => `<div class="grid2">${b.join("")}</div>`;
export const G3B = (...b) => `<div class="grid3">${b.join("")}</div>`;
export const NOTE = (t) => `<div class="note">${t}</div>`;
export const SCRIPT = (who, text) => `<div class="script"><span class="who">${esc(who)}</span><p>${text}</p></div>`;
export const TBL = (head, rows, o = {}) => `<table class="tbl${o.small ? " sm" : ""}"><tr>${head.map((h, i) => `<th${o.w && o.w[i] ? ` style="width:${o.w[i]}"` : ""}>${h}</th>`).join("")}</tr>${rows.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join("")}</tr>`).join("")}</table>`;
export const CMP = (lt, li, rt, ri) => `<div class="grid2"><div class="box top" style="--c:var(--leaf)"><h3>${lt}</h3>${LIST(li)}</div><div class="box top" style="--c:var(--gold)"><h3>${rt}</h3>${LIST(ri)}</div></div>`;
// Why > Where > Ask > Enter > Evidence > Verify > Done > Escalate: the required teaching pattern for each substantive task
export const PAT = (o, labels = ["Why", "Where", "Ask", "Enter", "Evidence", "Verify", "Done means", "Escalate"]) => {
  const v = [o.why, o.where, o.ask, o.enter, o.evidence, o.verify, o.done, o.escalate];
  const rows = labels.map((k, i) => [k, v[i]]);
  return `<div class="pat">${rows.map(([k, v], i) => `<div class="pc3${i === 7 ? " esc" : ""}"><b><i>${i + 1}</i>${k}</b><span>${v}</span></div>`).join("")}</div>`;
};
export const QUIZ = (q, a) => `<div class="quiz"><p class="q"><b>What would you do next?</b> ${q}</p><details><summary>Show the answer</summary><div class="ans">${a}</div></details></div>`;

// ---- the practice family: one master fact sheet, used by every slide and every handout ----------------------------------
export const FACTS = {
  decedent: "Delia Ann Marsh", deedName: "Delia A. Marsh", born: "06/02/1941", died: "03/14/2026", diedWhere: "Chicago, Cook County, Illinois",
  address: "4410 S Example Ave, Chicago, IL 60609", pin1: "20-00-000-001-0000", pin2: "20-00-000-002-0000",
  certNo: "EXAMPLE-0001", certIssued: "03/30/2026", copies: "3 certified copies, held by Marcus", marital: "Widowed (husband Robert Marsh died 2011)",
  deed1: "Warranty Deed, Doc 0000000000 (names \"Delia A. Marsh\")", searched: "04/05/2026", indexThrough: "04/03/2026",
  realValue: "$380,000", personal: "$6,500", income: "$21,600", incomeCalc: "two apartments at $900 a month, times 12 months, is $21,600",
  consult: "06/10/2026", hearing: "09/15/2026",
  kids: [
    ["Marcus Andre Marsh", "oldest son", "100 N Example St, Apt 4, Chicago, IL 60601", "312-555-0101", "informant; proposed administrator"],
    ["Renee Holloway (née Marsh)", "daughter", "200 Sample Ln, Atlanta, GA 30301", "404-555-0102", "lives out of state"],
    ["Terrence Eugene Marsh", "second son", "55 Sample Ct, Gary, IN 46402", "219-555-0103", "branch 2: will not sign a waiver"],
    ["Naomi Joy Marsh", "youngest daughter", "address not yet found", "none known", "branch 1: missing address"],
  ],
};
export const BRANCHES = [
  ["1", "Missing address", "Naomi Joy Marsh: no current address or phone is known."],
  ["2", "Refuses to waive notice", "Terrence Eugene Marsh says he will not sign anything."],
  ["3", "Name discrepancy", "The recorded deed says \"Delia A. Marsh\"; the death certificate says \"Delia Ann Marsh\"."],
  ["4", "A later death", "Renee Holloway dies 05/20/2026, after her mother. (Contrast: a child who died before 03/14/2026.)"],
  ["5", "Possible surviving spouse", "A 2023 church certificate naming \"Lamar Greene\" is found, but the death certificate says widowed."],
  ["6", "A lien", "A 2009 mortgage to Example Savings Bank, Doc 0000000001, has no recorded release."],
  ["7", "Different title interests", "PIN 20-00-000-002-0000 is deeded to \"Delia A. Marsh and Robert Marsh, as joint tenants\"; Robert died 2011."],
];

// ---- the deck's replica of the staff page (labelled as an illustration) ------------------------------------------------
const B = (n) => (n ? `<i class="bd">${n}</i>` : "");
export const F = (n, label, value = "", o = {}) => `<label class="fl hl">${B(n)}<span class="lb">${esc(label)}</span><span class="in${o.area ? " ar" : ""}${value ? "" : " empty"}">${esc(value || o.ph || "")}</span></label>`;
export const SEL = (n, label, value) => `<label class="fl hl">${B(n)}<span class="lb">${esc(label)}</span><span class="in sl">${esc(value)}<b>▾</b></span></label>`;
export const CHK = (n, label, on = true) => `<label class="fl hl ck">${B(n)}<span class="cbx${on ? " on" : ""}">${on ? "✓" : ""}</span><span class="lb">${esc(label)}</span></label>`;
export const BTN = (n, label, kind = "") => `<span class="bt hl ${kind}">${B(n)}${esc(label)}</span>`;
export const G2 = (a, b) => `<div class="g2">${a}${b}</div>`;
export const CARD = (title, inner, meta = "") => `<div class="pc"><h4>${esc(title)}</h4>${meta ? `<p class="mt">${esc(meta)}</p>` : ""}${inner}</div>`;
export const FRAME = (inner) => `<div class="fr"><div class="bar2"><span></span><span></span><span></span><em>2ndchinc.org/staff/deeds/transfer/ &nbsp;·&nbsp; drawn from the page's labels (illustration, fictional data)</em></div><div class="pg">${inner}</div></div>`;
export const ROOM = (items, head = "What to do") => `<div class="room"><h4>${head}</h4><ol>${items.map((t) => `<li>${t}</li>`).join("")}</ol></div>`;
export const SCREEN = (frame, items, head) => ({ left: frame, right: ROOM(items, head) });

// ---- render --------------------------------------------------------------------------------------------------------
export const css = `
  /* course deck */
  .mods{display:flex; flex-wrap:wrap; gap:4px; margin:0 0 10px;}
  .mods button{min-width:26px; height:24px; padding:0 7px; border-radius:6px; font:800 .7rem/24px var(--sans); background:rgba(255,255,255,.06); color:var(--ink-faint); border:1px solid var(--line);}
  .mods button.done{background:rgba(107,175,46,.18); color:var(--ink-soft);} .mods button.cur{background:var(--gold); color:#17231C; border-color:var(--gold);}
  .mp{height:4px; border-radius:2px; background:var(--line); margin:0 0 12px; overflow:hidden;} .mp i{display:block; height:100%; background:linear-gradient(90deg,var(--green),var(--leaf));}
  .dots{display:none;}
  .tg2{display:inline-block; font:800 .66rem/1 var(--sans); letter-spacing:.06em; text-transform:uppercase; padding:4px 8px; border-radius:999px; margin:0 6px 6px 0; border:1px solid currentColor;}
  .tg2.sys{color:#8FD16A;} .tg2.man{color:#F2B21A;} .tg2.cns{color:#8DB8FF;} .tg2.unv{color:#FF9B8A;} .tg2.ill{color:#C9D6CB;}
  .ls{list-style:none; display:grid; gap:7px; font-size:1rem; line-height:1.45;} .ls li{position:relative; padding-left:20px;} .ls li::before{content:""; position:absolute; left:2px; top:.62em; width:7px; height:7px; border-radius:50%; background:var(--leaf);}
  .ls.chk li{padding-left:32px;} .ls.chk li::before{display:none;} .bx{position:absolute; left:2px; top:.2em; width:18px; height:18px; border:2px solid var(--gold); border-radius:4px;}
  .script{background:var(--paper); color:var(--paper-ink); border-radius:14px; padding:12px 16px; border-left:8px solid var(--leaf); margin:8px 0;}
  .script .who{display:block; font:800 .68rem var(--sans); letter-spacing:.14em; text-transform:uppercase; color:#2E7D1F; margin-bottom:3px;} .script p{margin:0; font-size:1.02rem; line-height:1.5; color:#17231C;}
  .tbl.sm{font-size:.86rem;} .tbl.sm td,.tbl.sm th{padding:6px 9px;} .tbl td b{color:var(--gold);}
  .pat{display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px;} @media (max-width:820px){ .pat{grid-template-columns:1fr;} }
  .pc3{background:var(--surface); border:1px solid var(--line); border-radius:12px; padding:9px 12px; font-size:.9rem; line-height:1.4;} .pc3 b{display:flex; align-items:center; gap:7px; font:800 .72rem var(--sans); letter-spacing:.12em; text-transform:uppercase; color:var(--gold); margin-bottom:3px;}
  .pc3 b i{font-style:normal; width:20px; height:20px; border-radius:50%; background:var(--gold); color:#17231C; text-align:center; line-height:20px; letter-spacing:0;} .pc3.esc{border-color:#8DB8FF;} .pc3.esc b{color:#8DB8FF;} .pc3.esc b i{background:#8DB8FF;}
  .quiz{background:var(--surface-2); border:1px solid var(--line); border-radius:16px; padding:16px 18px;} .quiz .q{font-size:1.12rem; line-height:1.5; margin-bottom:10px;} .quiz .q b{color:var(--gold);}
  .quiz summary{cursor:pointer; font-weight:800; color:var(--leaf); padding:6px 0;} .quiz .ans{margin-top:8px; padding:10px 14px; border-left:5px solid var(--leaf); background:rgba(107,175,46,.1); border-radius:0 10px 10px 0; font-size:1rem; line-height:1.5;}
  .modcard{display:grid; gap:10px; margin-top:6px;} .modbtn{display:flex; gap:12px; align-items:center; text-align:left; width:100%; background:var(--surface); border:1px solid var(--line); border-radius:12px; padding:9px 14px; font-size:1rem;}
  .modbtn:hover{border-color:var(--leaf);} .modbtn .l{flex:0 0 34px; height:34px; border-radius:50%; background:var(--gold); color:#17231C; font:800 1rem/34px var(--sans); text-align:center;} .modbtn small{display:block; color:var(--ink-faint); font-size:.78rem;}
  .contents{grid-template-columns:repeat(2,minmax(0,1fr));} @media (max-width:820px){ .contents{grid-template-columns:1fr;} }
  .resume{position:fixed; right:14px; top:44px; z-index:50; background:var(--gold); color:#17231C; border-radius:999px; padding:8px 16px; font-weight:800; font-size:.85rem; box-shadow:0 4px 14px rgba(0,0,0,.5);} .resume[hidden]{display:none;}
  .tocbtn{position:fixed; left:14px; top:44px; z-index:50; background:var(--surface-2); border:1px solid var(--line); border-radius:999px; padding:7px 14px; font-weight:800; font-size:.8rem;}
  .fine{font-size:.78rem; color:var(--ink-faint); margin-top:10px;}
  .kw{display:grid; grid-template-columns:150px 1fr; gap:6px 14px; font-size:1rem; line-height:1.45;} .kw dt{font-weight:800; color:var(--gold);} @media (max-width:700px){ .kw{grid-template-columns:1fr;} }
  /* replica of the staff page */
  .wt{display:grid; grid-template-columns:minmax(0,1.35fr) minmax(0,.85fr); gap:16px; align-items:start;} @media (max-width:900px){ .wt{grid-template-columns:1fr;} }
  .fr{background:#fff; color:#17231C; border-radius:12px; overflow:hidden; border:1px solid var(--line); box-shadow:0 10px 30px rgba(0,0,0,.35);}
  .bar2{display:flex; align-items:center; gap:6px; padding:8px 12px; background:#E6EBE3;} .bar2 span{width:10px; height:10px; border-radius:50%; background:#B7C2B8;} .bar2 em{margin-left:10px; font:600 .7rem var(--sans); color:#506055; font-style:normal;}
  .pg{padding:12px; background:#F6F7F2; display:grid; gap:10px;}
  .pc{background:#fff; border:1px solid #D4DCD2; border-radius:10px; padding:11px 13px 11px 22px; position:relative; color:#17231C;} .pc h4{font:700 1rem var(--sans); margin:0 0 4px; color:#17231C;} .pc h5{font:700 .86rem var(--sans); margin:10px 0 4px;}
  .pc .mt,.mt{font:400 .8rem/1.45 var(--sans); color:#506055; margin:0 0 8px;}
  .g2{display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-bottom:8px;} @media (max-width:560px){ .g2{grid-template-columns:1fr;} }
  .fl{display:block; position:relative; margin-bottom:8px; font-size:.78rem; color:#506055;} .fl.hl{padding-left:2px;} .fl .lb{display:block; margin-bottom:3px; font-weight:600;}
  .in{display:block; border:1px solid #AEB9AE; border-radius:6px; padding:6px 9px; background:#fff; color:#17231C; font:500 .86rem/1.35 var(--sans); min-height:32px;}
  .in.ar{min-height:62px;} .in.empty{color:#93A598; font-style:italic;} .in.sl{display:flex; justify-content:space-between; gap:8px;} .in.sl b{color:#506055;}
  .bd{position:absolute; left:-17px; top:-3px; z-index:2; min-width:22px; height:22px; border-radius:11px; padding:0 6px; background:var(--gold); color:#17231C; font:800 .78rem/22px var(--sans); text-align:center; font-style:normal; box-shadow:0 1px 4px rgba(0,0,0,.35);}
  .in .bd{left:-14px; top:-9px;} .bt .bd{left:-14px; top:-9px;} .hr .bd{left:-14px; top:3px;}
  .hl .in,.bt.hl,.hr.hl,.hl2{outline:2px solid rgba(242,178,26,.55); outline-offset:1px;}
  .bt{display:inline-block; position:relative; border:1px solid #17231C; border-radius:6px; padding:6px 12px; margin:0 8px 6px 0; font:700 .8rem var(--sans); background:#fff; color:#17231C;} .bt.pri{background:#2E7D1F; border-color:#2E7D1F; color:#fff;}
  .rw{display:flex; flex-wrap:wrap; gap:6px; align-items:center; margin:6px 0; position:relative;}
  .hr{position:relative; border:1px solid #D4DCD2; border-radius:8px; padding:7px 10px; margin:6px 0; font-size:.82rem; background:#FBFCFA; color:#17231C;}
  .ck{display:flex; align-items:flex-start; gap:8px;} .ck .lb{margin:0; font-weight:500;} .ck .bd{left:-17px;}
  .ck .cbx{flex:0 0 auto; width:18px; height:18px; border:2px solid #506055; border-radius:4px; font:800 .8rem/14px var(--sans); text-align:center; color:#fff; background:#fff;} .ck .cbx.on{background:#2E7D1F; border-color:#2E7D1F;}
  .sync{display:inline-block; position:relative; padding:4px 12px; border-radius:6px; background:#EAF4E4; color:#2E7D1F; font:700 .8rem var(--sans);} .sync.bad{background:#FDECEA; color:#A32A1B;} .sync.warn{background:#FFF3D6; color:#8A5A00;}
  .rl{font-size:.8rem; line-height:1.5; color:#17231C;} .rl .ok{color:#2E7D1F; font-weight:800;} .rl .no{color:#93A598;}
  .room{background:var(--surface); border:1px solid var(--line); border-radius:14px; padding:14px 16px;} .room h4{font:700 .72rem var(--sans); letter-spacing:.16em; text-transform:uppercase; color:var(--gold); margin-bottom:8px;}
  .room ol{list-style:none; counter-reset:r; display:grid; gap:9px;} .room li{counter-increment:r; position:relative; padding-left:34px; font-size:.92rem; line-height:1.45; color:var(--ink);}
  .room li::before{content:counter(r); position:absolute; left:0; top:0; min-width:24px; height:24px; border-radius:12px; background:var(--gold); color:#17231C; font:800 .8rem/24px var(--sans); text-align:center;} .room b{color:var(--gold);}
`;

export const script = `
<script>
// Course additions: module buttons and progress, contents, and resume (all keyboard-reachable).
(function(){
  var KEY = "course-resume-v1", mods = JSON.parse(document.getElementById("modmap").textContent);
  function mark(){ try { localStorage.setItem(KEY, String(cur + 1)); } catch (e) {} }
  var oldGo = go;
  go = function(i){ oldGo(i); mark(); };
  var ob = document.getElementById("resumeBtn"), saved = 0;
  try { saved = parseInt(localStorage.getItem(KEY) || "0", 10) || 0; } catch (e) {}
  var hashStart = parseInt((location.hash || "").slice(1), 10);
  if ((!hashStart || hashStart === 1) && saved > 1 && saved <= N) { ob.hidden = false; ob.textContent = "Resume at slide " + saved + " of " + N + " →"; ob.onclick = function(){ ob.hidden = true; go(saved - 1); }; }
  document.getElementById("tocBtn").onclick = function(){ go(mods.contents - 1); };
  document.querySelectorAll("[data-goto]").forEach(function(b){ b.onclick = function(){ go(parseInt(b.getAttribute("data-goto"), 10) - 1); }; });
  setTimeout(function(){ ob.hidden = true; }, 20000);
})();
</script>`;
