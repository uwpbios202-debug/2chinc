// LOCAL CHECK ONLY: serves site/ on 127.0.0.1:8788 with mirror-client.js replaced by .claude-tools/dn-stub-client.js (made-up data).
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
const root = path.resolve("site");
const stub = path.resolve(".claude-tools/dn-stub-client.js");
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml", ".json": "application/json" };
http.createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (p.endsWith("/")) p += "index.html";
  const f = p === "/mirror/assets/mirror-client.js" ? stub : path.join(root, p);
  if ((f !== stub && !f.startsWith(root)) || !fs.existsSync(f)) { res.writeHead(404); res.end("not found"); return; }
  res.writeHead(200, { "content-type": types[path.extname(f)] || "application/octet-stream", "cache-control": "no-store" });
  fs.createReadStream(f).pipe(res);
}).listen(8788, "127.0.0.1", () => console.log("ready 8788"));
