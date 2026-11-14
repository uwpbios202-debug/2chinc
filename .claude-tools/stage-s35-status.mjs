// Stage ONLY my step-35 entry in DEVELOPMENT_STATUS.md (another session has uncommitted lines there; the working copy is untouched).
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
const f = "docs/human-mirror/DEVELOPMENT_STATUS.md";
const a = "- Open: the signed-in screens in a real browser, Android, iPhone, Speak / Read aloud and Narrator stay the Guided Tour (D-28).";
const add = "\n\n### 11/14/2026 — Phase 10 step 35: deployment documentation (Stephen: \"go\")\n" +
  "- New docs/human-mirror/DEPLOYMENT.md: the parts and where they live (pages, schema, edge function mirror-files, email outbox, bucket,\n" +
  "  jobs mirror-docs-sweep and mirror-reminders, secrets by name), putting a change live with several sessions (exact-version migrations,\n" +
  "  push by hash, no deploy over another session's unpublished pages), checking, undoing, the two switches, the launch steps, running it.";
let head = execFileSync("git", ["show", "HEAD:" + f], { encoding: "utf8" });
if (!head.includes(a) || head.includes("Phase 10 step 35")) { console.error("unexpected HEAD"); process.exit(1); }
head = head.replace(a, a + add);
const tmp = path.join(os.tmpdir(), "devstatus-staged.md");
fs.writeFileSync(tmp, head);
const blob = execFileSync("git", ["hash-object", "-w", tmp], { encoding: "utf8" }).trim();
execFileSync("git", ["update-index", "--cacheinfo", "100644," + blob + "," + f]);
fs.unlinkSync(tmp);
console.log("staged my entry in " + f);
