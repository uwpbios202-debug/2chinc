// Marks P3-11 done in KNOWN_ISSUES and adds the refusal-channel check to bug-check segment 7.
import fs from "node:fs";
const k = "docs/human-mirror/KNOWN_ISSUES.md";
let s = fs.readFileSync(k, "utf8");
const a = "so \"Who looked\" cannot show them. | Open |";
if (!s.includes(a)) throw new Error("P3-11 row not found");
s = s.replace(a, "so \"Who looked\" cannot show them. | DONE 11/13 (Stephen chose \"Separate write\"): migrations 20261119284000 + 285000, commits 990d1e6, 7af9088. Refusals are written through a second connection (Supabase pooler, sign-in `mirror_refusal_writer` that can only add refused rows, password made in the database and kept in Vault); fallback to the old log if it fails. dblink in private schema `mirror_link`. |");
fs.writeFileSync(k, s);
const b = "docs/BUG-CHECK-ROTATION.md";
let t = fs.readFileSync(b, "utf8");
const m = "**7. Sign-in, sessions and security**: ";
if (!t.includes(m)) throw new Error("segment 7 not found");
t = t.replace(m, m + "Mirror refusal log (11/13/2026): `select mirror.refusal_channel_ok()` answers 'ok' (second connection through the pooler; if it fails, refusals fall back to the old log and do not survive an error); `mirror_link` schema has no USAGE for anon, authenticated, service_role; role `mirror_refusal_writer` still has connection limit 3 and no inherit. ");
fs.writeFileSync(b, t);
console.log("docs updated");
