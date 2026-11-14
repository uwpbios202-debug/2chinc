// Build a Chrome-importable bookmarks file (Netscape format) of every Human Mirror page under site/mirror/.
// Usage: node .claude-tools/mirror-bookmarks.mjs <out.html>
import fs from "node:fs";
import path from "node:path";

const root = "site/mirror";
const host = "https://2ndchinc.org";
const out = process.argv[2];
const pages = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name === "index.html") pages.push(p);
  }
})(root);
// The Housing Navigator pages (portal, unit file, staff page)
const navPages = ["site/navigator/index.html", "site/navigator/unit/index.html", "site/staff/navigators/index.html"].filter((p) => fs.existsSync(p));
const navNames = { "navigator/": "Housing Navigator Portal", "navigator/unit/": "Unit file (open it from the portal: it needs a unit)",
  "staff/navigators/": "Housing Navigators (staff page)" };

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const decode = (s) => s.replace(/&amp;/g, "&").replace(/&#39;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/&mdash;/g, "—").replace(/&ndash;/g, "–").replace(/&middot;/g, "·");
const items = pages.map((p) => {
  const rel = p.split(path.sep).join("/").replace(/^site\//, "").replace(/index\.html$/, "");
  const html = fs.readFileSync(p, "utf8");
  const m = html.match(/<title>([\s\S]*?)<\/title>/i);
  let title = m ? decode(m[1].replace(/\s+/g, " ").trim()) : rel;
  title = title.replace(/\s*[|·—–-]\s*(The )?Human Mirror\s*$/i, "").replace(/^(The )?Human Mirror\s*[|·—–-]\s*/i, "").trim() || "Home";
  if (title === "My Mirror" && rel !== "mirror/my-mirror/") {           // generic page title: name it from its folder
    const names = { "identity-legal": "Identity and Legal", "life-skills": "Life Skills", "mental-health": "Mental Health",
      "physical-health": "Physical Health", "self-care": "Self-Care", abilities: "Abilities", contribution: "Contribution",
      history: "My History", needs: "Needs", strengths: "Strengths", preferences: "Preferences", today: "Today", vision: "Vision" };
    const slug = rel.replace(/\/$/, "").split("/").pop();
    title = names[slug] || slug.replace(/-/g, " ").replace(/^./, (c) => c.toUpperCase());
  }
  return { rel, url: host + "/" + rel, title };
});

const groups = [
  ["Public pages", (r) => !/^mirror\/(my-mirror|workspace|admin|sign-in|register|forgot-password|daily-number|demo|styleguide)\//.test(r)],
  ["Sign-in", (r) => /^mirror\/(sign-in|register|forgot-password)\//.test(r)],
  ["My Mirror", (r) => /^mirror\/my-mirror\//.test(r) && !/\/(daily-number|life)\//.test(r)],
  ["My Mirror - Daily Number", (r) => /^mirror\/(my-mirror\/)?daily-number\//.test(r)],
  ["My Mirror - Life areas", (r) => /^mirror\/my-mirror\/life\//.test(r)],
  ["Workspace (coordinators)", (r) => /^mirror\/workspace\//.test(r)],
  ["Admin", (r) => /^mirror\/admin\//.test(r)],
  ["Demo and style guide", (r) => /^mirror\/(demo|styleguide)\//.test(r)],
];
const used = new Set();
let body = "";
for (const [name, test] of groups) {
  const list = items.filter((i) => !used.has(i.rel) && test(i.rel)).sort((a, b) => a.rel.localeCompare(b.rel));
  if (!list.length) continue;
  list.forEach((i) => used.add(i.rel));
  body += `        <DT><H3>${esc(name)}</H3>\n        <DL><p>\n`;
  for (const i of list) body += `            <DT><A HREF="${esc(i.url)}">${esc(i.title)}</A>\n`;
  body += `        </DL><p>\n`;
}
const left = items.filter((i) => !used.has(i.rel));
if (left.length) throw new Error("ungrouped: " + left.map((i) => i.rel).join(", "));
let nav = "";
for (const p of navPages) {
  const rel = p.split(path.sep).join("/").replace(/^site\//, "").replace(/index\.html$/, "");
  nav += `        <DT><A HREF="${esc(host + "/" + rel)}">${esc(navNames[rel] || rel)}</A>\n`;
  console.log((navNames[rel] || rel).padEnd(40), host + "/" + rel);
}

const html = `<!DOCTYPE NETSCAPE-Bookmark-file-1>
<!-- Human Mirror (${items.length}) and Housing Navigator (${navPages.length}) pages on https://2ndchinc.org. Import in Chrome: Bookmarks manager, three dots, Import bookmarks. -->
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
    <DT><H3>Human Mirror</H3>
    <DL><p>
${body}    </DL><p>
    <DT><H3>Housing Navigator</H3>
    <DL><p>
${nav}    </DL><p>
    </DL><p>
</DL><p>
`;
fs.writeFileSync(out, html);
console.log(items.length, "links written to", out);
for (const [name] of groups) {}
for (const i of items.sort((a, b) => a.rel.localeCompare(b.rel))) console.log(i.title.padEnd(40), i.url);
