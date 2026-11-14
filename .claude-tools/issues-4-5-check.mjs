// Read-only headless Edge checks of issues 4 and 5 on the LIVE site. Never submits anything.
// Usage: node .claude-tools/issues-4-5-check.mjs <scratch-dir>
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";

const out = process.argv[2];
mkdirSync(out + "/edgeprof45", { recursive: true });
const EDGE = "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe";
const port = 9341;
const edge = spawn(EDGE, ["--headless=new", "--disable-gpu", `--remote-debugging-port=${port}`, `--user-data-dir=${out}/edgeprof45`, "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ver;
for (let i = 0; i < 40 && !ver; i++) { try { ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); } catch { await sleep(250); } }
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0; const pending = new Map(); const events = [];
ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); } else events.push(d); };
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => (await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true })).result?.result?.value;
const errs = () => events.filter((e) => e.method === "Runtime.exceptionThrown" || (e.method === "Log.entryAdded" && e.params.entry.level === "error"))
  .map((e) => e.method === "Runtime.exceptionThrown" ? e.params.exceptionDetails.exception?.description || e.params.exceptionDetails.text : e.params.entry.text);
const go = async (p, wait = 4000) => { events.length = 0; await send("Page.navigate", { url: "https://2ndchinc.org" + p }); await sleep(wait); };
await send("Runtime.enable"); await send("Log.enable"); await send("Page.enable");
const R = { browser: ver.Browser };

// ---------- Issue 4 ----------
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 800, deviceScaleFactor: 1, mobile: true });
await go("/mirror/daily-number/");
const setv = (pairs) => ev(`(() => { ${pairs.map(([k, v]) => `document.getElementById(${JSON.stringify(k)}).value = ${JSON.stringify(v)};`).join("")}
  document.getElementById("calc").dispatchEvent(new Event("input", { bubbles: true })); return 1; })()`);
const state = () => ev(`JSON.stringify({ label: cGapLabel.textContent, daily: cDaily.textContent, inn: cIn.textContent, gap: cGap.textContent, gapNote: cGapNote.textContent,
  paras: [...cWork.querySelectorAll("p")].map((p) => p.textContent.replace(/\\s+/g, " ").trim()),
  warnBold: [...cWork.querySelectorAll("p")].filter((p) => p.textContent.includes("Benefits can go down")).map((p) => [...p.querySelectorAll("strong")].slice(1).map((s) => s.textContent)),
  roles: [...cWork.querySelectorAll("[role],[aria-live]")].length, workRole: cWork.getAttribute("role"), workLive: cWork.getAttribute("aria-live") })`).then(JSON.parse);
const i4 = {};
await ev(`document.getElementById("cExample").click()`); await sleep(300); i4.c1_example = await state();
await ev(`document.getElementById("cClear").click()`); await sleep(300);
await setv([["a_housing", "1000"], ["cWage", "15"]]); await sleep(300); i4.c2_housingOnly = await state();
await setv([["a_pay", "100"]]); await sleep(300); i4.c3_payOnly = await state();
await setv([["a_rent", "100"], ["f_rent", "monthly"]]); await sleep(300); i4.c4_rentHelp = await state();
await ev(`document.getElementById("cClear").click()`); await sleep(300);
await setv([["a_housing", "500"], ["a_benefit", "994"], ["f_benefit", "monthly"], ["cWage", "15"]]); await sleep(300); i4.c5_covered = await state();
i4.errors = errs();
const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
writeFileSync(`${out}/issue4-covered-390.png`, Buffer.from(shot.result.data, "base64"));
R.issue4 = i4;

// ---------- Issue 5 part 1: Living Options, JS on and off ----------
const lo = () => ev(`JSON.stringify({ h1: document.querySelectorAll("h1").length, fallbackLis: [...document.querySelectorAll("#mmOptions > ul > li")].map((l) => l.textContent.trim()),
  turnOn: document.body.innerText.includes("Turn on JavaScript to see the options"), has211Line: document.querySelector("#mmOptions")?.innerText.includes("ask 2-1-1 or your coordinator"),
  cards: document.querySelectorAll("#mmOptions .mm-card, #mmOptions article, #mmOptions details, #mmOptions section").length,
  firstText: (document.querySelector("#mmOptions")?.innerText || "").replace(/\\s+/g, " ").slice(0, 160),
  sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth })`).then(JSON.parse);
await go("/mirror/living-options/"); R.lo_jsOn = { ...(await lo()), errors: errs() };
await send("Emulation.setScriptExecutionDisabled", { value: true });
await go("/mirror/living-options/"); R.lo_jsOff = await lo();
const shot2 = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
writeFileSync(`${out}/issue5-living-options-nojs-390.png`, Buffer.from(shot2.result.data, "base64"));
await send("Emulation.setScriptExecutionDisabled", { value: false });

// ---------- Issue 5 parts 2 + 3: head of every public page (rendered, live) ----------
R.heads = [];
for (const p of ["", "how-it-works/", "life-dimensions/", "daily-number/", "about/", "privacy/", "accessibility/", "living-options/", "sign-in/", "forgot-password/"]) {
  await go("/mirror/" + p, 2500);
  R.heads.push({ p: "/mirror/" + p, ...JSON.parse(await ev(`JSON.stringify({ n: document.querySelectorAll('meta[name=description]').length,
    afterTitle: document.querySelector('title')?.nextElementSibling?.getAttribute('name') === 'description',
    len: (document.querySelector('meta[name=description]')?.content || '').length, desc: document.querySelector('meta[name=description]')?.content || '',
    robots: document.querySelector('meta[name=robots]')?.content || '(none)', h1: document.querySelectorAll('h1').length })`)), errors: errs() });
}
writeFileSync(`${out}/issues-4-5.json`, JSON.stringify(R, null, 1));
console.log(JSON.stringify(R, null, 1));
ws.close(); edge.kill(); process.exit(0);
