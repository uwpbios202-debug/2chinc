// Notices & letters.
// Staff (two-step signed in; JWT in Authorization):
//   POST { action: "send", lease_id, template_id, subject, html, blocks?, email_tenants, request_id?, email_subject?, email_html? } -> { id }
//        (email_html: the letter's own email, [[FIRST]] = each tenant's first name; without it, a plain cover note)
//        (no blocks: they are made from the html; request_id: a repair's 12-hour notice, linked back to it;
//         link: { kind: renewal | rent_change | move_out | inspection, id } likewise)
//   POST { action: "sign_drafts", ids }   (agent only) -> signs the rent cycle's draft notices, one print file
// Builds the PDF on 2nd Chance letterhead from the composed notice (text
// blocks), stores it privately, records the notice, files it for the tenants
// (resident portal: Documents -> Notices) and emails each tenant a copy.
// The agent's signature image is applied only when the sender IS the agent,
// signed in with the two-step sign-in; otherwise the signature line carries
// the sender's typed name. An emailed copy is not legal service: service is
// recorded separately (notice_record_service).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, PDFFont, rgb, StandardFonts } from "https://esm.sh/pdf-lib@1.17.1";
import { cors, escapeHtml, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";
import { htmlToBlocks } from "../_shared/letters.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

async function sha256(s: string) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))).map((b) => b.toString(16).padStart(2, "0")).join("");
}
type Block = { t: string; text?: string; align?: string; cells?: string[]; big?: boolean };

function makeSafe(font: PDFFont) {
  const ok = new Map<string, boolean>();
  return (s: string) => Array.from(s.normalize("NFC")).map((ch) => {
    if (ch === " ") return " ";
    if (!ok.has(ch)) { try { font.encodeText(ch); ok.set(ch, true); } catch { ok.set(ch, false); } }
    return ok.get(ch) ? ch : "?";
  }).join("");
}

async function buildPdf(blocks: Block[], opts: { subject: string; sender: string; signature: Uint8Array | null; logo: Uint8Array | null; ref: string }) {
  const pdf = await PDFDocument.create();
  pdf.setTitle(opts.subject);
  const reg = await pdf.embedFont(StandardFonts.Helvetica), bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const safe = makeSafe(reg);
  const W = 612, H = 792, M = 60, TW = W - 2 * M;
  let page = pdf.addPage([W, H]), y = H - M;
  const header = async () => {
    if (opts.logo) { const img = await pdf.embedPng(opts.logo); page.drawImage(img, { x: M, y: H - 44 - 40, width: 44, height: 44 }); }
    page.drawText("2nd Chance Housing Inc.", { x: M + 54, y: H - 58, size: 12, font: bold, color: rgb(0.07, 0.13, 0.1) });
    page.drawText("6626 N. Bourbon St., Milwaukee, WI 53224  ·  (262) 236-5443  ·  2ndchinc.org", { x: M + 54, y: H - 72, size: 8.5, font: reg, color: rgb(0.35, 0.4, 0.36) });
    page.drawLine({ start: { x: M, y: H - 92 }, end: { x: W - M, y: H - 92 }, thickness: 1, color: rgb(0.18, 0.49, 0.12) });
    y = H - 110;
  };
  await header();
  const newPage = async () => { page = pdf.addPage([W, H]); await header(); };
  const wrap = (text: string, font: PDFFont, size: number) => {
    const lines: string[] = [];
    for (const para of text.split("\n").map(safe)) {   // split first: the font can't draw a newline
      let line = "";
      for (const word of para.split(/\s+/).filter(Boolean)) {
        const test = line ? line + " " + word : word;
        if (font.widthOfTextAtSize(test, size) <= TW) line = test; else { if (line) lines.push(line); line = word; }
      }
      lines.push(line);
    }
    return lines;
  };
  const write = async (text: string, o: { font?: PDFFont; size?: number; align?: string; gap?: number } = {}) => {
    const font = o.font || reg, size = o.size || 10, lh = size * 1.35;
    for (const ln of wrap(text, font, size)) {
      if (y - lh < M + 20) await newPage();
      const w = font.widthOfTextAtSize(ln, size);
      const x = o.align === "center" ? (W - w) / 2 : o.align === "right" ? W - M - w : M;
      page.drawText(ln, { x, y: y - size, size, font, color: rgb(0.08, 0.1, 0.09) });
      y -= lh;
    }
    y -= o.gap ?? 5;
  };
  for (const b of blocks) {
    if (b.t === "sig") {
      if (y - 60 < M + 20) await newPage();
      if (opts.signature) {
        const img = await pdf.embedPng(opts.signature);
        const s = Math.min(170 / img.width, 48 / img.height);
        page.drawImage(img, { x: M, y: y - img.height * s, width: img.width * s, height: img.height * s });
        y -= img.height * s + 2;
      } else { y -= 26; }
      page.drawLine({ start: { x: M, y }, end: { x: M + 220, y }, thickness: 0.7, color: rgb(0.2, 0.2, 0.2) });
      y -= 12;
      await write(opts.signature ? opts.sender : `${opts.sender} (signature on file not applied)`, { size: 9, gap: 6 });
    } else if (b.t === "tr") {
      // Table row: label left, amount right, boxed. A "big" row (the total due) is bold and one size larger than the letter's 10 pt text.
      const size = b.big ? 11 : 10, f = b.big ? bold : reg, rh = size * 1.35 + 9, cw = [TW * 0.72, TW * 0.28];
      if (y - rh < M + 20) await newPage();
      const cells = b.cells || [];
      page.drawRectangle({ x: M, y: y - rh, width: TW, height: rh, borderColor: rgb(0.2, 0.2, 0.2), borderWidth: 0.8, color: b.big ? rgb(0.94, 0.94, 0.94) : undefined });
      page.drawLine({ start: { x: M + cw[0], y }, end: { x: M + cw[0], y: y - rh }, thickness: 0.8, color: rgb(0.2, 0.2, 0.2) });
      cells.slice(0, 2).forEach((c, i) => {
        const t = safe(c), w = f.widthOfTextAtSize(t, size);
        page.drawText(t, { x: i === 0 ? M + 6 : M + TW - 6 - w, y: y - rh + 5.5, size, font: f, color: rgb(0.08, 0.1, 0.09) });
      });
      y -= rh;
      if (!(blocks[blocks.indexOf(b) + 1]?.t === "tr")) y -= 8;
    } else if (b.t === "line") {
      y -= 22; page.drawLine({ start: { x: M, y }, end: { x: M + 220, y }, thickness: 0.7, color: rgb(0.2, 0.2, 0.2) }); y -= 10;
    } else if (b.t === "h") await write(b.text || "", { font: bold, size: 13, align: b.align, gap: 6 });
    else if (b.t === "li") await write("•  " + (b.text || ""));
    else if (b.text) await write(b.text, { align: b.align, font: b.t === "b" ? bold : reg });
  }
  const pages = pdf.getPages();
  pages.forEach((p, i) => p.drawText(safe(`${opts.ref} · Page ${i + 1} of ${pages.length}`), { x: M, y: 30, size: 7.5, font: reg, color: rgb(0.45, 0.45, 0.45) }));
  return await pdf.save();
}

// The agent signs the rent cycle's draft notices (5-day notices) in one step:
// each becomes a signed PDF in the tenant's file, plus one combined print file.
async function signDrafts(req: Request, email: string, ids: string[]) {
  const { data: agent } = await admin.from("lease_agents").select("name, signature_path").eq("active", true).ilike("email", email).maybeSingle();
  if (!agent?.signature_path) return json(req, 403, { error: "Only the agent can sign these notices (signed in with the two-step sign-in)." });
  const { data: sigFile } = await admin.storage.from("lease-signing").download(agent.signature_path);
  const signature = new Uint8Array(await sigFile!.arrayBuffer());
  let logo: Uint8Array | null = null;
  try { const r = await fetch(new URL("/logo-192.png", Deno.env.get("PORTAL_BASE_URL") || "https://2ndchinc.org/owners/")); if (r.ok) logo = new Uint8Array(await r.arrayBuffer()); } catch { /* no logo */ }
  let q = admin.from("notices").select("id, lease_id, land_contract_id, subject, html, email_subject, email_html, rental:leases(rental_units(address)), lc:land_contracts(rental_properties(street))").eq("status", "draft");
  if (ids.length) q = q.in("id", ids);
  const { data: drafts } = await q;
  if (!drafts?.length) return json(req, 404, { error: "No notices are waiting to be signed." });
  const print = await PDFDocument.create();
  for (const d of drafts as any[]) {
    const where = d.rental?.rental_units?.address || d.lc?.rental_properties?.street || "";
    const ref = `Notice ${String(d.id).slice(0, 8).toUpperCase()} · ${where}`;
    const bytes = await buildPdf(htmlToBlocks(d.html, true), { subject: d.subject, sender: agent.name, signature, logo, ref });
    const path = `${d.lease_id || "lc-" + d.land_contract_id}/${d.id}.pdf`;
    const { error } = await admin.storage.from("notices").upload(path, bytes, { contentType: "application/pdf", upsert: true });
    if (error) throw error;
    await admin.from("notices").update({ status: "sent", pdf_path: path, signed_by_agent: true, sent_by: email, sent_at: new Date().toISOString(), html_sha256: await sha256(d.html) }).eq("id", d.id);
    // A notice with its own email (the pay-or-vacate notice) goes to each tenant with the signed PDF.
    // The emailed copy is a courtesy; the mailed paper notice is the legal service.
    if (d.lease_id && d.email_html) {
      const { data: ts } = await admin.from("lease_tenants").select("tenants!inner(name, email)").eq("lease_id", d.lease_id);
      const b64 = btoa(Array.from(bytes, (c) => String.fromCharCode(c)).join(""));
      const emailed: string[] = [];
      for (const t of (ts || []).map((x: any) => x.tenants).filter((t: any) => t.email)) {
        await sendEmail({ to: t.email, subject: d.email_subject || d.subject, html: d.email_html.replaceAll("[[FIRST]]", escapeHtml(t.name.split(/\s+/)[0])),
          attachments: [{ filename: `${d.subject.replace(/[^\w .,-]/g, "")}.pdf`, content: b64 }] });
        emailed.push(t.email);
      }
      await admin.from("notices").update({ emailed_to: emailed }).eq("id", d.id);
    }
    const src = await PDFDocument.load(bytes);
    (await print.copyPages(src, src.getPageIndices())).forEach((p) => print.addPage(p));
  }
  const printPath = `print/${new Date().toISOString().slice(0, 10)}-${crypto.randomUUID().slice(0, 8)}.pdf`;
  const { error: pErr } = await admin.storage.from("notices").upload(printPath, await print.save(), { contentType: "application/pdf" });
  if (pErr) throw pErr;
  return json(req, 200, { signed: drafts.length, print_path: printPath, ids: drafts.map((d: any) => d.id) });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const { data: ok } = await uc.rpc("staff_session_ok");
    const { data: u } = await admin.auth.getUser(jwt);
    const email = u?.user?.email?.toLowerCase();
    if (ok !== true || !email) return json(req, 403, { error: "Staff two-step sign-in required." });
    const body = await req.json().catch(() => ({}));
    if (body.action === "sign_drafts") return await signDrafts(req, email, Array.isArray(body.ids) ? body.ids.map(String) : []);
    if (body.action !== "send") return json(req, 400, { error: "Unknown action" });

    const { data: lease } = await admin.from("leases").select("id, tenants_label, rental_units!inner(address)").eq("id", String(body.lease_id || "")).maybeSingle();
    if (!lease) return json(req, 404, { error: "Lease not found." });
    const { data: tpl } = await admin.from("letter_templates").select("id, name").eq("id", String(body.template_id || "")).maybeSingle();
    if (!tpl) return json(req, 404, { error: "Template not found." });
    const html = String(body.html || "");
    const blocks: Block[] = Array.isArray(body.blocks) && body.blocks.length ? body.blocks.slice(0, 2000) : htmlToBlocks(html, true).slice(0, 2000);
    if (!blocks.length || html.length > 500_000) return json(req, 400, { error: "The notice is empty." });
    if (/\[\[(?!SIGNATURE\]\]|LINE\]\])[A-Za-z0-9_]+\]\]/.test(html)) return json(req, 400, { error: "Some fields are still blank. Fill every highlighted field first." });
    const subject = String(body.subject || tpl.name).slice(0, 160);

    // Signature: only the authenticated agent's own signature, applied here.
    const { data: agent } = await admin.from("lease_agents").select("name, signature_path").eq("active", true).ilike("email", email).maybeSingle();
    const { data: staffRow } = await admin.from("condo_staff").select("name").ilike("email", email).maybeSingle();
    let signature: Uint8Array | null = null;
    if (agent?.signature_path) {
      const { data } = await admin.storage.from("lease-signing").download(agent.signature_path);
      if (data) signature = new Uint8Array(await data.arrayBuffer());
    }
    let logo: Uint8Array | null = null;
    try { const r = await fetch(new URL("/logo-192.png", Deno.env.get("PORTAL_BASE_URL") || "https://2ndchinc.org/owners/")); if (r.ok) logo = new Uint8Array(await r.arrayBuffer()); } catch { /* letterhead without logo */ }

    const id = crypto.randomUUID();
    const ref = `Notice ${id.slice(0, 8).toUpperCase()} · ${lease.rental_units.address}`;
    const bytes = await buildPdf(blocks, { subject, sender: agent?.name || staffRow?.name || email, signature, logo, ref });
    const path = `${lease.id}/${id}.pdf`;
    const { error: upErr } = await admin.storage.from("notices").upload(path, bytes, { contentType: "application/pdf" });
    if (upErr) throw upErr;

    const { data: tenants } = await admin.from("lease_tenants").select("tenants!inner(name, email)").eq("lease_id", lease.id);
    const recips = (tenants || []).map((t: any) => t.tenants).filter((t: any) => t.email);
    const emailed: string[] = [];
    const { error: insErr } = await admin.from("notices").insert({
      id, lease_id: lease.id, template_id: tpl.id, template_name: tpl.name, subject, html, html_sha256: await sha256(html), pdf_path: path,
      sent_by: email, signed_by_agent: !!signature, emailed_to: [],
    });
    if (insErr) throw insErr;
    // Link the filed notice back to what it was made from (same lease only).
    const link = body.request_id ? { kind: "repair", id: body.request_id, table: "maintenance_requests" }
      : body.link && ["renewal", "rent_change", "move_out", "inspection"].includes(body.link.kind) ? { kind: body.link.kind, id: body.link.id,
          table: ({ renewal: "lease_renewals", rent_change: "lease_rent_changes", move_out: "move_outs", inspection: "inspection_appointments" } as Record<string, string>)[body.link.kind] } : null;
    if (link && /^[0-9a-f-]{36}$/.test(String(link.id || ""))) {
      const { data: row } = await admin.from(link.table).select("id, lease_id").eq("id", link.id).maybeSingle();
      if (row && row.lease_id === lease.id) await admin.rpc("notice_link_back", { p_kind: link.kind, p_id: row.id, p_notice: id });
    }
    if (body.email_tenants !== false) {
      const b64 = btoa(Array.from(bytes, (c) => String.fromCharCode(c)).join(""));
      // The letter's own email (built with the letter, [[FIRST]] per tenant), or the plain cover note.
      const ownHtml = typeof body.email_html === "string" && body.email_html.length < 100_000 ? body.email_html : "";
      const ownSubject = typeof body.email_subject === "string" && body.email_subject.trim() ? body.email_subject.trim().slice(0, 160) : subject;
      for (const t of recips) {
        const first = escapeHtml(t.name.split(/\s+/)[0]);
        await sendEmail({ to: t.email, subject: ownHtml ? ownSubject : subject,
          html: ownHtml ? ownHtml.replaceAll("[[FIRST]]", first)
            : `<p>Hi ${first},</p><p>Please see the attached notice from 2nd Chance Housing: <b>${escapeHtml(subject)}</b>. A copy is also in your resident portal under Documents.</p><p>2nd Chance Housing</p>`,
          attachments: [{ filename: `${subject.replace(/[^\w .,-]/g, "")}.pdf`, content: b64 }] });
        emailed.push(t.email);
      }
      await admin.from("notices").update({ emailed_to: emailed }).eq("id", id);
    }
    return json(req, 200, { id, pdf_path: path, emailed, signed_by_agent: !!signature });
  } catch (err) {
    console.error("notices: error", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "Something went wrong. Try again." });
  }
});
