// T8.2 findings 5 and 6 on the person's own list pages. Each replace must match exactly once.
import fs from "node:fs";
const edits = [
  ["site/mirror/my-mirror/my-needs/index.html", "<title>My Needs | The Human Mirror</title>", "<title>My needs list | The Human Mirror</title>"],
  ["site/mirror/my-mirror/my-needs/index.html", "    <h1>My needs</h1>\n", "    <h1>My needs list</h1>\n"],
  ["site/mirror/my-mirror/my-needs/index.html",
   "follow it until it's met. You decide what goes here.</p>",
   "follow it until it's met. You decide what goes here.</p>\n    <p class=\"mm-small\">This is your list. The questions to think it through are in <a href=\"/mirror/my-mirror/needs/\">What must change, and what do I need?</a></p>"],
  ["site/mirror/my-mirror/my-needs/index.html",
   "${x.from ? esc(STATUS[x.from]) + \" → \" : \"\"}${esc(STATUS[x.to])}",
   "${x.from && x.from === x.to ? \"changed\" : (x.from ? esc(STATUS[x.from]) + \" → \" : \"\") + esc(STATUS[x.to])}"],
  ["site/mirror/my-mirror/my-strengths/index.html", "<title>My Strengths | The Human Mirror</title>", "<title>My strengths list | The Human Mirror</title>"],
  ["site/mirror/my-mirror/my-strengths/index.html", "    <h1>My strengths</h1>\n", "    <h1>My strengths list</h1>\n"],
  ["site/mirror/my-mirror/my-strengths/index.html",
   "Everyone has strengths; this is where yours are written down.</p>",
   "Everyone has strengths; this is where yours are written down.</p>\n    <p class=\"mm-small\">This is your list. The questions to think it through are in <a href=\"/mirror/my-mirror/strengths/\">What do I have within me?</a></p>"],
  ["site/mirror/my-mirror/index.html", "href=\"/mirror/my-mirror/my-needs/\">My needs</a>", "href=\"/mirror/my-mirror/my-needs/\">My needs list</a>"],
  ["site/mirror/my-mirror/index.html", "href=\"/mirror/my-mirror/my-strengths/\">My strengths</a>", "href=\"/mirror/my-mirror/my-strengths/\">My strengths list</a>"],
];
for (const [f, a, b] of edits) {
  const t = fs.readFileSync(f, "utf8");
  const k = t.split(a).length - 1;
  if (k !== 1) { console.log("FAIL (" + k + "): " + f + " :: " + a.slice(0, 60)); process.exit(1); }
  fs.writeFileSync(f, t.replace(a, () => b));
}
console.log("ok " + edits.length);
