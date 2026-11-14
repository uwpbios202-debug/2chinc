// Minimal .xlsx reader shared by the Mirror database imports (no packages needed). From tools/landlord-db-import.mjs;
// each data row also carries _row, its row number in the sheet (row 1 = the column names).
import { readFileSync } from "node:fs";
import { inflateRawSync } from "node:zlib";



// ---------- minimal zip reader ----------
function unzip(buf) {
  let eocd = buf.length - 22;
  while (eocd >= 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd < 0) throw new Error("Not a zip file");
  const count = buf.readUInt16LE(eocd + 10), cdOff = buf.readUInt32LE(eocd + 16);
  const files = {};
  let p = cdOff;
  for (let i = 0; i < count; i++) {
    const method = buf.readUInt16LE(p + 10), csize = buf.readUInt32LE(p + 20);
    const nlen = buf.readUInt16LE(p + 28), xlen = buf.readUInt16LE(p + 30), clen = buf.readUInt16LE(p + 32), lho = buf.readUInt32LE(p + 42);
    const name = buf.toString("utf8", p + 46, p + 46 + nlen);
    const lnlen = buf.readUInt16LE(lho + 26), lxlen = buf.readUInt16LE(lho + 28);
    const data = buf.subarray(lho + 30 + lnlen + lxlen, lho + 30 + lnlen + lxlen + csize);
    files[name] = method === 0 ? Buffer.from(data) : method === 8 ? inflateRawSync(data) : null;
    p += 46 + nlen + xlen + clen;
  }
  return files;
}

// ---------- minimal xlsx reader ----------
const dec = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
  .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16))).replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n)).replace(/&amp;/g, "&");
export function readWorkbook(path) {
  const z = unzip(readFileSync(path));
  const txt = (n) => { const f = z[n]; if (!f) throw new Error("Missing " + n); return f.toString("utf8"); };
  const shared = z["xl/sharedStrings.xml"]
    ? [...txt("xl/sharedStrings.xml").matchAll(/<si>([\s\S]*?)<\/si>/g)].map((m) => dec([...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((t) => t[1]).join("")))
    : [];
  const rels = {};
  for (const m of txt("xl/_rels/workbook.xml.rels").matchAll(/<Relationship\b([^>]*)\/?>/g)) {
    const id = /Id="([^"]+)"/.exec(m[1])?.[1], target = /Target="([^"]+)"/.exec(m[1])?.[1];
    if (id && target) rels[id] = target.replace(/^\/?xl\//, "");
  }
  const col = (c) => [...c].reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1;
  const out = {};
  for (const m of txt("xl/workbook.xml").matchAll(/<sheet\b([^>]*)\/>/g)) {
    const name = dec(/name="([^"]+)"/.exec(m[1])[1]), rid = /r:id="([^"]+)"/.exec(m[1])[1];
    const rows = [];
    for (const r of txt("xl/" + rels[rid]).matchAll(/<row\b([^>]*)>([\s\S]*?)<\/row>/g)) {
      const row = []; row._n = /\br="(\d+)"/.test(r[1]) ? +/\br="(\d+)"/.exec(r[1])[1] : rows.length + 1;
      for (const c of r[2].matchAll(/<c ([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
        const ref = /r="([A-Z]+)\d+"/.exec(c[1])[1], t = /t="([^"]+)"/.exec(c[1])?.[1], body = c[2] || "";
        let v = /<v>([\s\S]*?)<\/v>/.exec(body)?.[1];
        if (t === "s") v = shared[+v];
        else if (t === "inlineStr") v = dec([...body.matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((x) => x[1]).join(""));
        else if (v !== undefined) v = dec(v);
        row[col(ref)] = v ?? null;
      }
      rows.push(row);
    }
    const header = Array.from(rows[0] || []).map((h) => (h == null ? null : String(h).trim()));
    out[name] = rows.slice(1).filter((r) => r.some((x) => x != null && String(x).trim() !== ""))
      .map((r) => ({ ...Object.fromEntries(header.map((h, i) => [h ?? "_col" + i, r[i] == null || String(r[i]).trim() === "" ? null : String(r[i]).trim()])), _row: r._n }));
  }
  return out;
}
