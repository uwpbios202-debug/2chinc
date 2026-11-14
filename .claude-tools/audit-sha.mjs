// Matches each audit's inventory letters to files in "databases gapped" by SHA-256, else by name.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
const A = "Issues and fixes/Databases_TheMirror", G = "Issues and fixes/databases gapped";
const files = [];
for (const d of readdirSync(G)) for (const f of readdirSync(G + "/" + d)) { const p = G + "/" + d + "/" + f; if (statSync(p).isFile()) files.push({ p, f, d, sha: createHash("sha256").update(readFileSync(p)).digest("hex") }); }
for (const f of readdirSync(A).filter((x) => x.endsWith("Folder_Audit.html"))) {
  const h = readFileSync(A + "/" + f, "utf8");
  const inv = /<section id="inventory">([\s\S]*?)<\/section>/.exec(h)?.[1] || "";
  const rows = [...inv.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/g)].map((r) => [...r[1].matchAll(/<t[dh][^>]*>([\s\S]*?)<\/t[dh]>/g)].map((c) => c[1].replace(/<[^>]+>/g, "").trim())).filter((r) => /^[A-Z]$/.test(r[0]));
  const shas = new Set([...h.matchAll(/\b[0-9a-f]{64}\b/g)].map((m) => m[0]));
  console.log("==", f, "sha count in file", shas.size);
  for (const r of rows) {
    const bySha = files.filter((x) => r.some((c) => c === x.sha) || false);
    const byName = files.filter((x) => x.f === r[1]);
    const shaHit = files.filter((x) => shas.has(x.sha) && x.f.replace(/\(\d\)/g, "") === r[1].replace(/\(\d\)/g, ""));
    console.log("  ", r[0], r[1], "| sha:", bySha.map((x) => x.d + "/" + x.f).join(";") || "-", "| name:", byName.map((x) => x.d + "/" + x.f).join(";") || "-");
  }
}
