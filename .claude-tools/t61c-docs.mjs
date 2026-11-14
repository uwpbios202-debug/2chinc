// D-30 (needs removable by the person) after D-29, and a status line. Refuses if D-30 is taken.
import fs from "node:fs";
const f = "docs/human-mirror/DECISIONS.md";
const lines = fs.readFileSync(f, "utf8").split("\n");
if (lines.some((l) => l.startsWith("| D-30 |"))) throw new Error("D-30 taken");
const i = lines.findIndex((l) => l.startsWith("| D-29 |"));
if (i < 0) throw new Error("D-29 missing");
lines.splice(i + 1, 0, "| D-30 | Removing a need (T6.1 report finding 2, 11/13/2026). DECIDED by Stephen 11/13 (\"should people be able to remove their own needs - yes\"): the person may remove one of their own needs for good, with its history and its steps (public.mirror_need_delete, migration 20261119333000). Only the person: a coordinator, even with \"see and change\", can mark it \"no longer needed\" but cannot remove it. Every other single delete stays blocked by mirror.needs_no_delete(); deleting the whole Mirror still removes everything (D-18). | DECIDED 11/13/2026 |");
fs.writeFileSync(f, lines.join("\n"));
fs.appendFileSync("docs/human-mirror/DEVELOPMENT_STATUS.md",
  "- 11/13 later: Stephen decided T6.1 finding 2 (D-30): people can remove their own needs. Migration 20261119333000 (mirror_need_delete, person only;\n" +
  "  needs_no_delete lets through only that function's own removal or a whole-Mirror delete). Remove link with an \"are you sure\" on\n" +
  "  /mirror/my-mirror/my-needs/. Checks: t61c 3/3 and t61 9/9 rolled back with it; page driven headless (confirm, keep, remove), no errors.\n" +
  "  Stephen also confirmed D-27 (\"confirmed D-27 = go\").\n");
console.log("ok");
