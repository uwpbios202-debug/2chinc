// Builds the self-guided researcher course:
//   site/probate-help/course/index.html            (the deck; same engine as /probate-help/ and the walkthrough)
//   site/probate-help/course/materials/*.html      (printable handouts, source register, inventory, open items, transcript)
//   docs/course-narration.txt                      (the narration, one paragraph per slide, for recording)
// The family in the examples is FICTIONAL. Run: node tools/build-course.mjs
// Keep the spoken text (`say`) free of digits: it is also the caption text and the transcript.
import fs from "fs";
import { slides, MODULES, css, script, esc, CHECKED } from "./course/lib.mjs";
import "./course/m1.mjs"; import "./course/m2.mjs"; import "./course/m3.mjs"; import "./course/m4.mjs"; import "./course/m5.mjs"; import "./course/m6.mjs";
import { buildMaterials } from "./course/materials.mjs";

const root = new URL("../", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const N = slides.length;
const modName = Object.fromEntries(MODULES);
const first = {}; const count = {};
slides.forEach((s, i) => { if (first[s.m] === undefined) first[s.m] = i; count[s.m] = (count[s.m] || 0) + 1; });
const contentsAt = slides.findIndex((s) => s.kind === "contents") + 1;

const pills = (cur, i) => `<div class="mods" role="navigation" aria-label="Modules">${MODULES.filter(([id]) => id !== "S").map(([id, name]) => {
  const st = id === cur ? "cur" : first[id] < i ? "done" : "";
  return `<button type="button" class="${st}" data-goto="${first[id] + 1}" aria-label="Go to module ${id}: ${esc(name)}"${id === cur ? ' aria-current="true"' : ""}>${id}</button>`; }).join("")}</div>`;
const strip = (s, i) => { const pos = i - first[s.m] + 1; return `<div class="mp" aria-hidden="true"><i style="width:${Math.round((100 * pos) / count[s.m])}%"></i></div>`; };

const slideHtml = (s, i) => {
  const mn = s.m === "S" ? "Start here" : `Module ${s.m} · ${modName[s.m]}`;
  const eyebrow = `<div class="eyebrow">${esc(mn)} · ${i + 1} of ${N}</div>`;
  const head = pills(s.m, i) + strip(s, i);
  let inner;
  if (s.kind === "cover") inner = `<div class="brand"><img src="/logo.png" alt="2nd Chance Housing logo"><div><b>2nd Chance Housing Inc</b><span>Researcher training</span></div></div><div class="eyebrow">Self-guided course · ${N} slides · twelve modules</div><h1>${s.h}</h1><p class="lede">${esc(s.sub)}</p><p class="small">Press <b>Play</b> for narration, or use the arrows. Space plays and pauses; C shows captions; F goes full screen. Fictional practice family throughout. Not legal advice.</p>`;
  else if (s.kind === "contents") inner = `${eyebrow}<h2>${s.h}</h2><p class="lede">${esc(s.sub)}</p><div class="modcard contents">${MODULES.filter(([id]) => id !== "S").map(([id, name]) => `<button type="button" class="modbtn" data-goto="${first[id] + 1}"><span class="l">${id}</span><span><b>${esc(name)}</b><small>slide ${first[id] + 1}, ${count[id]} slides</small></span></button>`).join("")}</div><p class="fine">Handouts: <a href="/probate-help/course/materials/">printable checklists, matrix, handoff templates, practice case, sources</a> · <a href="/probate-help/course/materials/transcript.html">transcript</a></p>`;
  else if (s.kind === "mod") inner = `${head}${eyebrow}<h1 style="font-size:clamp(2rem,5vw,3.2rem)"><span class="gold">${s.m}.</span> ${esc(s.h)}</h1><p class="lede">${esc(s.sub)}</p>${s.bullets.length ? `<div class="box"><h3>In this module</h3><ul class="ls">${s.bullets.map((b) => `<li>${b}</li>`).join("")}</ul></div>` : ""}`;
  else if (s.left) inner = `${head}${eyebrow}<h2>${s.h}</h2><div class="wt"><div class="rep">${s.left}</div>${s.right}</div>`;
  else inner = `${head}${eyebrow}<h2>${s.h}</h2>${s.body || ""}`;
  return `<!-- ${i + 1} -->\n<section class="slide" data-say="${esc(s.say)}"><div class="card">\n${inner}\n</div></section>`;
};

let h = fs.readFileSync(root + "site/probate-help/index.html", "utf8");
h = h.replace("</style>", css + "</style>");
const a = h.indexOf("<main"), b = h.indexOf("</main>");
h = h.slice(0, a) + `<main id="deck" aria-live="polite">\n\n` + slides.map(slideHtml).join("\n\n") + "\n\n" + h.slice(b);
h = h.replace("</main>", `<div id="cc" role="status" aria-live="off"></div>\n</main>\n<button type="button" class="tocbtn" id="tocBtn">☰ Contents</button>\n<button type="button" class="resume" id="resumeBtn" hidden></button>\n<script type="application/json" id="modmap">${JSON.stringify({ contents: contentsAt })}</script>`);
const rep = (x, y) => { if (!h.includes(x)) throw new Error("missing " + x.slice(0, 60)); h = h.split(x).join(y); };
rep(`/probate-help/audio/`, `/probate-help/course/audio/`);
rep(`/probate-help/img/`, `/probate-help/course/img/`);
rep(`<meta name="robots" content="index, follow">`, `<meta name="robots" content="noindex, follow">`);
h = h.replace(/<link rel="canonical"[^>]*>/, `<link rel="canonical" href="https://2ndchinc.org/probate-help/course/">`);
h = h.replace(/<script type="application\/ld\+json">[\s\S]*?<\/script>\n?/, "");
h = h.replace(/<meta property="og:[^>]*>\n?/g, "");
h = h.replace(/<meta name="description" content="[^"]*">/, `<meta name="description" content="Self-guided training for 2nd Chance Housing researchers: finding a potential case, family outreach and consent, intake, ownership evidence, the preparation system, the attorney package and what happens after filing. A fictional practice family; not legal advice.">`);
h = h.replace(/<title>[^<]*<\/title>/, `<title>Researcher Training Course · 2nd Chance Housing</title>`);
h = h.replace(/<div class="banner">[\s\S]*?<\/div>/, `<div class="banner">Researcher training with a fictional practice family. 2nd Chance Housing Inc is not a law firm; nothing here is legal advice. Law and pages checked ${CHECKED}.</div>`);
h = h.replace(/<span class="count" id="count">[^<]*<\/span>/, `<span class="count" id="count">1 / ${N}</span>`);
h = h.replace("</body>", script + "\n</body>");

fs.mkdirSync(root + "site/probate-help/course/materials", { recursive: true });
fs.writeFileSync(root + "site/probate-help/course/index.html", h);
for (const [f, html] of Object.entries(buildMaterials(slides))) fs.writeFileSync(root + "site/probate-help/course/materials/" + f, html);
fs.writeFileSync(root + "docs/course-narration.txt", slides.map((s, i) => `[${i + 1}] ${s.say.trim()}`).join("\n\n") + "\n");

const words = slides.reduce((x, s) => x + s.say.split(/\s+/).length, 0);
const digits = slides.map((s, i) => [i + 1, s.say]).filter(([, t]) => /\d/.test(t)).map(([i]) => i);
console.log("slides:", N, "words:", words, "~minutes:", (words / 150).toFixed(1), "modules:", JSON.stringify(count));
console.log("say-with-digits (fix these):", digits.join(",") || "none");
