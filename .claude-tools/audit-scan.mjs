// Scans the folder audits: catalog entries, row anchors and inventory. node .claude-tools/audit-scan.mjs <dir>
import { readFileSync, readdirSync } from "node:fs";
const dir = process.argv[2];
for (const f of readdirSync(dir).filter((x) => x.endsWith("Folder_Audit.html"))) {
  const h = readFileSync(dir + "/" + f, "utf8");
  const cat = /<section id="catalog">([\s\S]*?)<\/section>/.exec(h)?.[1] || "";
  const entries = [...cat.matchAll(/<details id=["']?(p\d+)["']?[^>]*><summary>([\s\S]*?)<\/summary>/g)];
  const anchors = [...cat.matchAll(/href="#([^"]+)"/g)].map((m) => m[1]);
  const kinds = {};
  for (const a of anchors) { const k = a.replace(/\d+$/, "N").replace(/^[xw][A-Z0-9]+-/, "X-"); kinds[k] = (kinds[k] || 0) + 1; }
  const inv = /<section id="inventory">([\s\S]*?)<\/section>/.exec(h)?.[1] || "";
  const invRows = [...inv.matchAll(/<tr>([\s\S]*?)<\/tr>/g)].map((r) => [...r[1].matchAll(/<t[dh][^>]*>([\s\S]*?)<\/t[dh]>/g)].map((c) => c[1].replace(/<[^>]+>/g, "").trim()).slice(0, 4).join(" | "));
  const ids = [...new Set(anchors.map((a) => /^([xw][A-Z0-9]+)-/.exec(a)?.[1]).filter(Boolean))];
  console.log("=====", f, "entries", entries.length, "anchor prefixes", ids.join(","));
  console.log("  first:", entries.slice(0, 2).map((e) => e[2].replace(/<[^>]+>/g, "")).join(" || "));
  console.log("  kinds:", JSON.stringify(kinds).slice(0, 400));
  console.log("  inv:", invRows.slice(0, 9).join("\n       "));
}
