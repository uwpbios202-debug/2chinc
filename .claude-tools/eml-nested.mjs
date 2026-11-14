// Splits the message/rfc822 attachments out of one .eml into separate .eml files. Usage: node eml-nested.mjs <in.eml> <outdir>
import fs from "node:fs";
import path from "node:path";
const [inp, out] = process.argv.slice(2);
const src = fs.readFileSync(inp, "latin1");
const b = /boundary="?([^"\r\n;]+)"?/i.exec(src)[1];
const parts = src.split("--" + b);
fs.mkdirSync(out, { recursive: true });
let n = 0;
for (const p of parts) {
  if (!/content-type:\s*message\/rfc822/i.test(p.slice(0, 600))) continue;
  const name = (/filename="?([^"\r\n]+)"?/i.exec(p) || /name="?([^"\r\n]+)"?/i.exec(p) || [, "part" + n + ".eml"])[1];
  const bodyAt = p.search(/\r?\n\r?\n/);
  let body = p.slice(bodyAt).replace(/^\s+/, "");
  if (/content-transfer-encoding:\s*base64/i.test(p.slice(0, bodyAt))) body = Buffer.from(body.replace(/\s+/g, ""), "base64").toString("latin1");
  fs.writeFileSync(path.join(out, (n++) + "-" + name.replace(/[^\w. -]/g, "_")), body, "latin1");
}
console.log(n + " parts");
