// Stephen 11/13/2026: "you have the absolute best solution(s) so apply them" -> D-34, D-35, D-37 DECIDED as built. (one-off; not committed)
import fs from "node:fs";
const said = 'DECIDED 11/13/2026 (Stephen: "you have the absolute best solution(s) so apply them")';
let s = fs.readFileSync("docs/human-mirror/DECISIONS.md", "utf8");
const lines = s.split("\n");
let n = 0;
for (let i = 0; i < lines.length; i++) {
  if (/^\| D-3[457] \|/.test(lines[i]) && lines[i].endsWith("| DEFAULT (confirm) |")) {
    lines[i] = lines[i].replace("Defaults chosen by Claude, for Stephen to confirm:", "Chosen by Claude; Stephen accepted them as built 11/13/2026:")
      .replace(/\| DEFAULT \(confirm\) \|$/, "| " + said + " |");
    n++;
  }
}
if (n !== 3) { console.error("expected 3, changed " + n); process.exit(1); }
fs.writeFileSync("docs/human-mirror/DECISIONS.md", lines.join("\n")); console.log("ok DECISIONS (3)");
const edit = (f, pairs) => {
  let t = fs.readFileSync(f, "utf8");
  for (const [a, b] of pairs) { if (!t.includes(a)) { console.error("MISSING in " + f + ": " + a); process.exit(1); } t = t.replace(a, b); }
  fs.writeFileSync(f, t); console.log("ok " + f);
};
edit("docs/human-mirror/NEXT_ACTIONS.md", [["(D-34, D-35, D-37 DEFAULT to confirm)", "(D-34, D-35, D-37 decided 11/13: Stephen accepted them as built)"]]);
edit("docs/human-mirror/DEVELOPMENT_STATUS.md", [
  ["D-34 DEFAULT for Stephen to confirm.", "D-34 decided 11/13 (Stephen accepted it as built)."],
  ["D-35 DEFAULT for Stephen to confirm (no secret notes;", "D-35 decided 11/13 (Stephen accepted it as built; no secret notes;"],
  ["D-37 DEFAULT for Stephen to confirm.", "D-37 decided 11/13 (Stephen accepted it as built)."],
  ["t84 6/6, D-34 DEFAULT)", "t84 6/6, D-34 decided)"],
  ["t85 7/7, D-35 DEFAULT)", "t85 7/7, D-35 decided)"],
  ["t86 6/6, D-37 DEFAULT)", "t86 6/6, D-37 decided)"],
]);
