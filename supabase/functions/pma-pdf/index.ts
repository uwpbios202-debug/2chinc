// Signed Property Management Agreement -> PDF in the owner's Documents (Stephen, 11/11/2026).
//
//   POST { id }   (signed-in JWT: the owner, the president or office staff of that agreement)
//
// Only for an agreement with status 'signed' and both signatures on the same text (hash). Makes the PDF once (later calls return the
// existing path), uploads it to the private owner-docs bucket, adds a unit-only condo_documents row (the owner sees it under
// Documents and can print it at any time), saves pma_agreements.pdf_path and sends the queued emails.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, PDFFont, rgb, StandardFonts } from "https://esm.sh/pdf-lib@1.17.1";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { flushOutbox } from "../_shared/mail.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

function makeSafe(font: PDFFont) {
  const ok = new Map<string, boolean>();
  return (s: string) => Array.from(String(s || "").normalize("NFC").replace(/[“”]/g, '"').replace(/[‘’]/g, "'").replace(/[–—]/g, "-")).map((ch) => {
    if (ch === " ") return " ";
    if (!ok.has(ch)) { try { font.encodeText(ch); ok.set(ch, true); } catch { ok.set(ch, false); } }
    return ok.get(ch) ? ch : "?";
  }).join("");
}

const ct = (iso: string) => new Date(iso).toLocaleString("en-US", { timeZone: "America/Chicago", month: "long", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }) + " Central";

async function buildPdf(a: any, contact: { mail_to?: string; phone?: string }, ev: any) {
  const pdf = await PDFDocument.create();
  pdf.setTitle(a.title + " (signed)");
  const reg = await pdf.embedFont(StandardFonts.TimesRoman), bold = await pdf.embedFont(StandardFonts.TimesRomanBold);
  const safe = makeSafe(reg);
  const W = 612, H = 792, M = 64, TW = W - 2 * M;
  let page = pdf.addPage([W, H]), y = H - M;
  const newPage = () => { page = pdf.addPage([W, H]); y = H - M; };
  const wrap = (text: string, font: PDFFont, size: number, width: number) => {
    const lines: string[] = [];
    for (const para of text.split("\n").map(safe)) {
      let line = "";
      for (const word of para.split(/\s+/).filter(Boolean)) {
        const test = line ? line + " " + word : word;
        if (font.widthOfTextAtSize(test, size) <= width) line = test; else { if (line) lines.push(line); line = word; }
      }
      lines.push(line);
    }
    return lines;
  };
  const write = (text: string, o: { font?: PDFFont; size?: number; align?: string; gap?: number; indent?: number } = {}) => {
    const font = o.font || reg, size = o.size || 10.5, lh = size * 1.38, ind = o.indent || 0;
    for (const ln of wrap(text, font, size, TW - ind)) {
      if (y - lh < M + 16) newPage();
      const w = font.widthOfTextAtSize(ln, size);
      const x = o.align === "center" ? (W - w) / 2 : M + ind;
      page.drawText(ln, { x, y: y - size, size, font, color: rgb(0.07, 0.07, 0.07) });
      y -= lh;
    }
    y -= o.gap ?? 4;
  };
  write("Royal Orleans Condominium - Addition One (ROCA1)", { align: "center", size: 10.5, gap: 0 });
  write("6626 N Bourbon St, Milwaukee, WI 53224", { align: "center", size: 10.5, gap: 8 });
  write("PROPERTY MANAGEMENT AGREEMENT", { align: "center", font: bold, size: 15, gap: 2 });
  write(`Unit ${a.unit_number}, 6622 N Bourbon St`, { align: "center", gap: 12 });
  for (const s of a.sections) {
    if (y - 50 < M + 16) newPage();
    write(String(s.title).toUpperCase(), { font: bold, size: 10.5, gap: 2 });
    page.drawLine({ start: { x: M, y: y + 1 }, end: { x: W - M, y: y + 1 }, thickness: 0.6, color: rgb(0.55, 0.55, 0.55) });
    y -= 4;
    for (const para of String(s.body).split(/\n\s*\n/)) {
      for (const line of para.split("\n")) {
        const li = /^\s*\d+\.\s/.test(line);
        write(line.trim(), { indent: li ? 12 : 0, gap: li ? 1 : 1 });
      }
      y -= 4;
    }
    y -= 4;
  }
  if (y - 60 < M + 16) newPage();
  write("OWNER'S ADDRESS FOR STATEMENTS AND NOTICES", { font: bold, size: 10.5, gap: 2 });
  write(`Mailing address on file: ${contact.mail_to || "(none on file)"}`, { gap: 1 });
  write(`Phone on file: ${contact.phone || "(none on file)"}`, { gap: 12 });
  // Exhibit A: the unit's eviction expense budget as it stood when signed (section 5a).
  if (ev && Array.isArray(ev.items)) {
    newPage();
    write("EXHIBIT A: WHAT AN EVICTION COSTS (ESTIMATE)", { font: bold, size: 12, gap: 2 });
    write(`The eviction expense budget for Unit ${a.unit_number} that section 5a refers to, as it stood on the day both signed. Court and Sheriff fees change; rows "to be entered" depend on the case.`, { size: 9.5, gap: 8 });
    const money = (n: number) => Number(n || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
    for (const r of ev.items) {
      if (y - 40 < M + 16) newPage();
      const amt = Number(r.amount) ? money(Number(r.amount)) : "to be entered", aw = bold.widthOfTextAtSize(safe(amt), 10.5);
      const top = y;
      write(r.expense, { font: bold, gap: 0 });
      page.drawText(safe(amt), { x: W - M - aw, y: top - 10.5, size: 10.5, font: bold, color: rgb(0.07, 0.07, 0.07) });
      write(r.covers + (r.note ? " - " + r.note : ""), { size: 9, gap: 5, indent: 10 });
    }
    write(`Known costs so far (rows "to be entered" are not counted): ${money(Number(ev.total))}`, { font: bold, gap: 14 });
  }
  const sig = (who: string, name: string, at: string, email: string, ip: string) => {
    if (y - 90 < M + 16) newPage();
    write(who, { font: bold, size: 10.5, gap: 4 });
    write("/s/ " + name, { font: bold, size: 14, gap: 1 });
    page.drawLine({ start: { x: M, y: y + 2 }, end: { x: M + 280, y: y + 2 }, thickness: 0.7, color: rgb(0.2, 0.2, 0.2) });
    y -= 4;
    write(`Signed electronically by ${name} on ${ct(at)}`, { size: 9, gap: 0 });
    write(`Signed in as ${email}${ip ? ` from ${ip}` : ""}`, { size: 9, gap: 12 });
  };
  sig(`OWNER OF UNIT ${a.unit_number}`, a.owner_signed_name, a.owner_signed_at, a.owner_signed_email, a.owner_signed_ip);
  sig(`FOR ROCA1 (${a.president_name}, President) AND FOR 2ND CHANCE HOUSING INC, MANAGEMENT PARTNER`, a.president_signed_name, a.president_signed_at, a.president_signed_email, a.president_signed_ip);
  write(`Both signatures are on version ${a.version} of this text (fingerprint ${String(a.owner_signed_hash).slice(0, 16)}). Signed online at 2ndchinc.org.`, { size: 8.5, gap: 0 });
  const pages = pdf.getPages();
  pages.forEach((p, i) => p.drawText(safe(`${a.title} · signed ${ct(a.signed_at)} · Page ${i + 1} of ${pages.length}`), { x: M, y: 30, size: 7.5, font: reg, color: rgb(0.45, 0.45, 0.45) }));
  return await pdf.save();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const { data: u } = await uc.auth.getUser(jwt);
    if (!u?.user) return json(req, 401, { error: "Please sign in again." });
    const { id } = await req.json().catch(() => ({}));
    // Only someone who can see the agreement (owner, president, office) gets an answer.
    const [mine, staff] = await Promise.all([uc.rpc("pma_mine"), uc.rpc("pma_staff_list")]);
    const seen = [...(mine.data || []), ...(staff.data || [])].some((x: any) => x.id === id);
    if (!seen) return json(req, 404, { error: "Agreement not found." });
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const { data: a } = await admin.from("pma_agreements").select("*").eq("id", id).maybeSingle();
    if (!a || a.status !== "signed") return json(req, 409, { error: "Not signed by both yet." });
    if (a.pdf_path) return json(req, 200, { ok: true, path: a.pdf_path });
    if (!a.owner_signed_hash || a.owner_signed_hash !== a.president_signed_hash) return json(req, 409, { error: "The two signatures are on different versions. Ask the office to reopen it." });
    const { data: contact } = await admin.rpc("pma_owner_contact", { p_owner: a.owner_id });
    const { data: ev } = await admin.rpc("pma_eviction_sheet", { p_unit: a.unit_number });
    const bytes = await buildPdf(a, contact || {}, ev);
    const day = new Date(a.signed_at).toLocaleDateString("en-US", { timeZone: "America/Chicago" });
    const path = `pma/unit-${a.unit_number}-pma-v${a.version}-${String(a.id).slice(0, 8)}.pdf`;
    const up = await admin.storage.from("owner-docs").upload(path, bytes, { contentType: "application/pdf", upsert: true });
    if (up.error) throw new Error(up.error.message);
    // Claim it (only one caller files the document row).
    const { data: claimed } = await admin.from("pma_agreements").update({ pdf_path: path }).eq("id", id).is("pdf_path", null).select("id");
    if (claimed?.length) {
      // condo_documents.id is an identity column: never send one. If filing fails, release the claim so "Make the PDF now" can retry.
      const doc = await admin.from("condo_documents").insert({ unit_number: a.unit_number, title: `${a.title}, signed ${day}`, category: "Agreements", storage_path: path, uploaded_by: "signed online" });
      if (doc.error) { await admin.from("pma_agreements").update({ pdf_path: null }).eq("id", id); throw new Error(doc.error.message); }
    }
    await flushOutbox(admin).catch(() => 0);
    return json(req, 200, { ok: true, path });
  } catch (err) {
    console.error("pma-pdf: error", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "Something went wrong making the PDF. The office can try again from the agreement page." });
  }
});
