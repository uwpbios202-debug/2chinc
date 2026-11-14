// Stage ONLY my T8.8 line in docs/BUG-CHECK-ROTATION.md (another session has uncommitted edits in the same file; the working
// copy is left exactly as it is). Builds the staged version from HEAD + my one replacement. (one-off; not committed)
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
const f = "docs/BUG-CHECK-ROTATION.md";
const a = "t87 still 5/5 (rolled back); https://2ndchinc.org/mirror/workspace/inventory/ returns 200.";
const b = a + " T8.8 (11/13/2026, migration 20261119580000): mirror_org_report is security definer with a fixed search_path and not executable by anon; t88 still 5/5 (rolled back); https://2ndchinc.org/mirror/workspace/reports/ returns 200.";
let head = execFileSync("git", ["show", "HEAD:" + f], { encoding: "utf8" });
if (!head.includes(a) || head.includes(b)) { console.error("unexpected HEAD content"); process.exit(1); }
head = head.replace(a, b);
const tmp = path.join(os.tmpdir(), "bugcheck-staged.md");
fs.writeFileSync(tmp, head);
const blob = execFileSync("git", ["hash-object", "-w", tmp], { encoding: "utf8" }).trim();
execFileSync("git", ["update-index", "--cacheinfo", "100644," + blob + "," + f]);
fs.unlinkSync(tmp);
console.log("staged " + f + " as " + blob);
