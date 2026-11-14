// Link walk for the Mirror public pages: every page and every local href/src on them must answer 200.
// Usage: node .claude-tools/mirror-linkwalk.mjs [base]   (default http://127.0.0.1:8787)
const base = process.argv[2] || "http://127.0.0.1:8787";
const pages = ["/mirror/", "/mirror/about/", "/mirror/how-it-works/", "/mirror/life-dimensions/", "/mirror/privacy/",
  "/mirror/accessibility/", "/mirror/forgot-password/", "/mirror/sign-in/", "/mirror/styleguide/", "/mirror/demo/conversation/"];
// links the shell (mirror-ui.js) adds to every public page
const shell = ["/mirror/", "/mirror/how-it-works/", "/mirror/life-dimensions/", "/mirror/about/", "/mirror/privacy/", "/mirror/sign-in/",
  "/mirror/accessibility/", "/mirror/forgot-password/", "/mirror/assets/mirror-ui.js", "/mirror/assets/dimensions.js", "/mirror/assets/mirror-listen.js"];
const seen = new Map();
const check = async (u) => { if (!seen.has(u)) seen.set(u, (await fetch(base + u)).status); return seen.get(u); };
let bad = 0;
for (const p of pages) {
  const st = await check(p);
  const html = st === 200 ? await (await fetch(base + p)).text() : "";
  const refs = [...html.matchAll(/(?:href|src)="(\/[^"#?]*)/g)].map((m) => m[1]).filter((u) => !u.startsWith("//"));
  const noindex = /<meta name="robots" content="noindex/.test(html);
  for (const r of refs) if ((await check(r)) !== 200) { bad++; console.log("BROKEN", p, "->", r, seen.get(r)); }
  console.log(st, noindex ? "noindex" : "INDEXABLE", p, refs.length + " links");
}
for (const s of shell) if ((await check(s)) !== 200) { bad++; console.log("BROKEN shell link", s, seen.get(s)); }
console.log(bad ? bad + " broken" : "all links 200");
