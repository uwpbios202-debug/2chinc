// Real headless Edge (signed-out fresh profile), driven over the DevTools protocol. Read-only: navigates and measures, never submits.
// Usage: node .claude-tools/mirror-edge-check.mjs <scratch-dir>
import { spawn } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";

const out = process.argv[2];
mkdirSync(out + "/edgeprof2", { recursive: true });
const EDGE = "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe";
const port = 9339;
const edge = spawn(EDGE, ["--headless=new", "--disable-gpu", `--remote-debugging-port=${port}`, `--user-data-dir=${out}/edgeprof2`, "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let ver;
for (let i = 0; i < 40 && !ver; i++) { try { ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); } catch { await sleep(250); } }
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0; const pending = new Map(); const events = [];
ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); } else events.push(d); };
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const evalJs = async (expr) => (await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true })).result?.result?.value;

await send("Runtime.enable"); await send("Log.enable"); await send("Page.enable");
const results = { browser: ver.Browser, pages: [] };

const phase1 = ["/mirror/", "/mirror/about/", "/mirror/how-it-works/", "/mirror/life-dimensions/", "/mirror/privacy/", "/mirror/accessibility/",
  "/mirror/forgot-password/", "/mirror/sign-in/", "/mirror/styleguide/", "/mirror/demo/conversation/", "/mirror/my-mirror/", "/mirror/workspace/"];
for (const w of [320, 390]) {
  await send("Emulation.setDeviceMetricsOverride", { width: w, height: 800, deviceScaleFactor: 1, mobile: true });
  for (const p of phase1) {
    events.length = 0;
    await send("Page.navigate", { url: "https://2ndchinc.org" + p });
    await sleep(4000);
    const m = await evalJs(`JSON.stringify({ end: location.pathname + location.search, sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth,
      menuBtn: !!document.querySelector('.mm-btn, [aria-controls]'), h1: (document.querySelector('h1')||{}).textContent })`);
    const errs = events.filter((e) => e.method === "Runtime.exceptionThrown" || (e.method === "Log.entryAdded" && e.params.entry.level === "error"))
      .map((e) => e.method === "Runtime.exceptionThrown" ? e.params.exceptionDetails.exception?.description || e.params.exceptionDetails.text : e.params.entry.text + " " + (e.params.entry.url || ""));
    const r = JSON.parse(m); results.pages.push({ w, p, ...r, ok: r.sw <= r.cw, errs });
    if (p === "/mirror/sign-in/" || p === "/mirror/") {
      const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
      writeFileSync(`${out}/edge-cdp${p.replace(/\//g, "_")}${w}.png`, Buffer.from(shot.result.data, "base64"));
    }
  }
}

// Signed-out sign-in page: what is on it (no submit).
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 800, deviceScaleFactor: 1, mobile: true });
await send("Page.navigate", { url: "https://2ndchinc.org/mirror/sign-in/" });
await sleep(6000);
results.signIn = JSON.parse(await evalJs(`JSON.stringify((() => {
  const email = document.querySelector('input[type=email], input[autocomplete=email], input[name=email]');
  const lab = email && (email.labels && email.labels[0] ? email.labels[0].textContent.trim() : email.getAttribute('aria-label'));
  const btns = [...document.querySelectorAll('main button')].map((b) => b.textContent.trim()).filter(Boolean);
  const ts = [...document.querySelectorAll('iframe')].map((f) => f.src).filter((s) => s.includes('challenges.cloudflare.com')).length;
  const tsScript = [...document.querySelectorAll('script')].some((s) => (s.src || '').includes('challenges.cloudflare.com'));
  return { path: location.pathname, emailField: !!email, emailLabel: lab, emailAutocomplete: email && email.getAttribute('autocomplete'),
    buttons: btns, turnstileScript: tsScript, turnstileFrames: ts, text: (document.querySelector('main')||document.body).innerText.replace(/\\s+/g,' ').slice(0, 400) };
})())`));

writeFileSync(`${out}/edge-check.json`, JSON.stringify(results, null, 1));
const fails = results.pages.filter((x) => !x.ok);
const errs = results.pages.filter((x) => x.errs.length);
console.log(JSON.stringify({ browser: results.browser, measured: results.pages.length, sidewaysScroll: fails.map((x) => x.w + " " + x.p),
  redirects: [...new Set(results.pages.filter((x) => x.end !== x.p).map((x) => x.p + " -> " + x.end))],
  pagesWithErrors: errs.map((x) => ({ w: x.w, p: x.p, errs: x.errs.slice(0, 3) })), signIn: results.signIn }, null, 1));
ws.close(); edge.kill();
process.exit(0);
