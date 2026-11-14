// Server-side template filling for [[Field]] letters, and a
// plain HTML -> text-block conversion for the notice PDF builder.
export type Block = { t: string; text?: string; align?: string; cells?: string[]; big?: boolean };

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));

// Fills every field it has a value for. Signature fields become markers the
// PDF builder turns into the signature line; returns the fields still blank.
export function fillTemplate(html: string, ctx: Record<string, unknown>) {
  const missing = new Set<string>();
  const out = html.replace(/\[\[([A-Za-z0-9_]+)\]\]/g, (m, f) => {
    if (f === "Sender_Signature") return "[[SIGNATURE]]";
    if (/^Adobe_/.test(f)) return "[[LINE]]";
    const v = ctx[f];
    if (v === undefined || v === null || String(v) === "") { missing.add(f); return m; }
    return esc(String(v));
  });
  return { html: out, missing: [...missing] };
}

const decode = (s: string) => s.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)));

// One block per paragraph-level element (p, div, h1-6, li, tr), keeping
// center/right alignment and bold headings; [[SIGNATURE]] / [[LINE]] split out.
export function htmlToBlocks(html: string, tables = false): Block[] {   // tables: only the notices builder draws table rows
  const blocks: Block[] = [];
  const clean = html.replace(/<(script|style)[\s\S]*?<\/\1>/gi, "").replace(/<hr[^>]*>/gi, "");
  const re = /<(p|div|h[1-6]|li|tr)(\s[^>]*)?>([\s\S]*?)<\/\1>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(clean))) {
    const [, tag, attrs = "", inner] = m;
    if (/<(p|div|h[1-6]|li|tr)[\s>]/i.test(inner)) { blocks.push(...htmlToBlocks(inner, tables)); continue; }
    const align = /text-align:\s*center/i.test(attrs + inner.slice(0, 200)) ? "center" : /text-align:\s*right/i.test(attrs) ? "right" : "left";
    const isTr = tag.toLowerCase() === "tr";
    if (isTr && tables) {   // a table row: its cells are drawn in a bordered table; class="big" = bold and one size larger (the amount due)
      const cells = inner.split(/<\/t[dh]>/i).map((c) => decode(c.replace(/<br\s*\/?>/gi, " ").replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim()).filter((c, i, arr) => c || i < arr.length - 1);
      if (cells.some(Boolean)) blocks.push({ t: "tr", cells, big: /class\s*=\s*["']?[^"'>]*\bbig\b/i.test(attrs) });
      continue;
    }
    const text = decode((isTr ? inner.replace(/<\/t[dh]>/gi, "   ") : inner).replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]+>/g, "")).replace(/[ \t]+/g, " ").replace(/ *\n */g, "\n").trim();
    if (!text) continue;
    const bold = /^<(strong|b)\b/i.test(inner.replace(/<span[^>]*>/gi, "").trim()) && !/<\/(strong|b)>[\s\S]*\S[\s\S]*$/i.test(inner.replace(/<\/span>/gi, "").trim().replace(/<\/(strong|b)>\s*$/i, ""));
    for (const part of text.split(/(\[\[SIGNATURE\]\]|\[\[LINE\]\])/)) {
      const p = part.trim();
      if (!p) continue;
      if (p === "[[SIGNATURE]]") blocks.push({ t: "sig" });
      else if (p === "[[LINE]]") blocks.push({ t: "line" });
      else blocks.push({ t: tag.toLowerCase() === "li" ? "li" : /^h/i.test(tag) || bold ? "h" : "p", text: p, align });
    }
  }
  return blocks;
}
