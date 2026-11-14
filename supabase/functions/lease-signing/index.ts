// Lease e-signature for 2nd Chance Housing.
//
// Staff (two-step signed in; JWT in Authorization):
//   POST { action: "send", unit_label, title?, html, blocks, lease_data?, application_id?, co_application_ids? (up to 3 more applicants),
//          signers: [{ name, email, phone }] }                    -> { id }
//        (refused while the same application already has a lease out or signed: void it first)
//   POST { action: "void", doc_id, reason }                         -> stops every signing link; tenants are told
//   POST { action: "resend", signer_id }                            -> new link emailed; the old link stops working
// Agent (two-step signed in; JWT in Authorization), after every tenant signed:
//   POST { action: "countersign", doc_id, consent }                 -> { executed }
//   POST { action: "renewal_sign", renewal_id }  (resident)         -> renewal agreement sent to every tenant to sign
// Tenant (private link token from the email):
//   POST { action: "open",   token }                              -> lease summary (sends nothing)
//   POST { action: "send_code", token }                           -> emails a 6-digit code (only when the tenant taps
//        "Email me a code": email scanners open links, so nothing is sent on opening the page)
//   POST { action: "verify", token, code }                        -> the lease exactly as sent
//   POST { action: "sign",   token, typed_name, signature, consent, initials?, initialed? } -> { signed, executed }
//        (initials + initialed: required when the lease has initial lines; every line id must be initialed)
//
// The agent's signature is never part of what's sent: once every tenant has
// signed, the lease waits for the agent, who signs in and countersigns; only
// then is the agent's stored signature (private storage) applied server-side.
// After that, the executed PDF (the lease text, each
// signature, and a certificate page with the document fingerprint and the
// full audit trail) is stored privately and emailed to every signer and staff.
// The lease HTML snapshot is the authoritative record; its SHA-256 is printed
// on the certificate.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, PDFFont, rgb, StandardFonts } from "https://esm.sh/pdf-lib@1.17.1";
import { cors, escapeHtml, PORTAL_BASE_URL, SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL } from "../_shared/config.ts";
import { flushOutbox, sendEmail } from "../_shared/mail.ts";
import { htmlToBlocks } from "../_shared/letters.ts";
import { sendCaseworkerPacket } from "../_shared/caseworker-packet.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const SIGN_BASE_URL = Deno.env.get("SIGN_BASE_URL") || new URL("/sign/", PORTAL_BASE_URL).toString();
const BUCKET = "lease-signing";
const VERIFY_WINDOW_MS = 2 * 60 * 60 * 1000;
const MAX_CODES_PER_HOUR = 4;
const CODE_COOLDOWN_MS = 60 * 1000;
const CODE_TTL_MS = 10 * 60 * 1000;
const MAX_CODE_ATTEMPTS = 5;

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

async function sha256(s: string | Uint8Array) {
  const data = typeof s === "string" ? new TextEncoder().encode(s) : s;
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", data))).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function randomToken() {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function toE164(phone: unknown): string | null {
  const d = String(phone || "").replace(/\D/g, "");
  if (d.length === 10) return "+1" + d;
  if (d.length === 11 && d.startsWith("1")) return "+" + d;
  return null;
}
const maskPhone = (e164: string) => "(•••) •••-" + e164.slice(-4);
// j•••@gmail.com: enough to recognise your own address, not enough to harvest it.
const maskEmail = (e: string) => { const [u, d] = String(e).split("@"); return (u || "").charAt(0) + "•••@" + (d || ""); };
const norm = (s: string) => s.toLowerCase().replace(/[^a-z]/g, "");
const clientIp = (req: Request) => (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || null;
const ua = (req: Request) => (req.headers.get("user-agent") || "").slice(0, 300);

function userClientFor(req: Request) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  return { jwt, uc: createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } }) };
}

async function storageDataUrl(path: string) {
  const { data, error } = await admin.storage.from(BUCKET).download(path);
  if (error || !data) throw error || new Error("missing file " + path);
  const b = new Uint8Array(await data.arrayBuffer());
  return "data:image/png;base64," + btoa(Array.from(b, (c) => String.fromCharCode(c)).join(""));
}

async function event(doc_id: string, signer_id: string | null, ev: string, req: Request | null, detail?: string) {
  await admin.from("lease_signing_events").insert({ doc_id, signer_id, event: ev, ip: req ? clientIp(req) : null, user_agent: req ? ua(req) : null, detail: detail || null });
}

async function signerFor(token: unknown) {
  if (typeof token !== "string" || token.length < 30) return null;
  const { data: s } = await admin.from("lease_signing_signers").select("*").eq("token_hash", await sha256(token)).maybeSingle();
  if (!s) return null;
  const { data: doc } = await admin.from("lease_signing_docs").select("*").eq("id", s.doc_id).single();
  if (!doc || doc.status === "void") return null;
  return { s, doc };
}

// The initial lines in the lease as sent (the Parking Agreement's sections: <span id="pi-N">Initial: ______</span>).
const initialLines = (html: string) => [...String(html || "").matchAll(/<span[^>]*\bid="pi-(\d+)"[^>]*>\s*Initial:/g)].map((m) => m[1]);

// ---------------------------------------------------------------------------
// Executed PDF
// ---------------------------------------------------------------------------
type Block = { t: string; text?: string; src?: string };

function makeSafe(font: PDFFont) {
  const ok = new Map<string, boolean>();
  const repl: Record<string, string> = { "☐": "[ ]", "☑": "[x]", "☒": "[x]", "✓": "x", "✔": "x", " ": " ", "​": "" };
  return (s: string) => Array.from(s.normalize("NFC")).map((ch) => {
    if (repl[ch] !== undefined) return repl[ch];
    if (!ok.has(ch)) { try { font.encodeText(ch); ok.set(ch, true); } catch { ok.set(ch, false); } }
    return ok.get(ch) ? ch : "?";
  }).join("");
}

function dataUrlBytes(src: string): { bytes: Uint8Array; png: boolean } | null {
  const m = /^data:image\/(png|jpe?g);base64,(.+)$/.exec(src || "");
  if (!m) return null;
  return { bytes: Uint8Array.from(atob(m[2]), (c) => c.charCodeAt(0)), png: m[1] === "png" };
}

async function buildPdf(doc: Record<string, any>, signers: Record<string, any>[], events: Record<string, any>[], agent: Record<string, any> | null) {
  const pdf = await PDFDocument.create();
  pdf.setTitle(`${doc.title} — ${doc.unit_label}`);
  pdf.setProducer("2nd Chance Housing lease signing");
  const reg = await pdf.embedFont(StandardFonts.Helvetica), bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const safe = makeSafe(reg);
  const W = 612, H = 792, M = 54, TW = W - 2 * M;
  let page = pdf.addPage([W, H]), y = H - M;
  const newPage = () => { page = pdf.addPage([W, H]); y = H - M; };
  const ensure = (h: number) => { if (y - h < M + 20) newPage(); };
  const wrap = (text: string, font: PDFFont, size: number, width: number) => {
    const lines: string[] = [];
    for (const para of safe(text).split("\n")) {
      let line = "";
      for (const word of para.split(/\s+/).filter(Boolean)) {
        const test = line ? line + " " + word : word;
        if (font.widthOfTextAtSize(test, size) <= width) line = test;
        else { if (line) lines.push(line); line = word; }
      }
      lines.push(line);
    }
    return lines;
  };
  const write = (text: string, o: { font?: PDFFont; size?: number; indent?: number; gap?: number; color?: number } = {}) => {
    const font = o.font || reg, size = o.size || 9.5, indent = o.indent || 0, lh = size * 1.32;
    for (const ln of wrap(text, font, size, TW - indent)) {
      ensure(lh);
      page.drawText(ln, { x: M + indent, y: y - size, size, font, color: rgb(o.color ?? 0.08, o.color ?? 0.1, o.color ?? 0.09) });
      y -= lh;
    }
    y -= o.gap ?? 4;
  };
  const image = async (src: string, maxW: number, maxH: number) => {
    const d = dataUrlBytes(src); if (!d) return;
    const img = d.png ? await pdf.embedPng(d.bytes) : await pdf.embedJpg(d.bytes);
    const s = Math.min(maxW / img.width, maxH / img.height, 1);
    ensure(img.height * s + 6);
    page.drawImage(img, { x: M, y: y - img.height * s, width: img.width * s, height: img.height * s });
    y -= img.height * s + 6;
  };

  const initials = signers.filter((s) => s.initials).map((s) => s.initials).join(" / ");
  const fill = (t: string) => initials ? t.replace(/Initial: _+/g, `Initials: ${initials}`) : t;
  // Each tenant's own signature and date go into their box in the lease (the lease's signature line and the Parking Agreement's
  // "Signature and date of NAME" row), so nobody signs twice. The Signatures page after the lease stays as the full record.
  const sigFor = (name: string) => signers.find((s) => String(s.name).trim().toLowerCase() === name.trim().toLowerCase());
  const day = (iso: string) => new Date(iso).toLocaleDateString("en-US", { timeZone: "America/Chicago", year: "numeric", month: "long", day: "numeric" });
  let afterAck = false;
  const stamped = new Set<string>();
  for (const b of (doc.blocks || []) as Block[]) {
    const text = fill(b.text || "");
    const raw = String(b.text || "").trim();
    if (b.t === "p") {
      if (/^Legal Acknowledgment/i.test(raw)) afterAck = true;
      const mk = /^Signature and date of (.+)$/i.exec(raw);
      if (mk) {
        const s = sigFor(mk[1]);
        write(raw, { font: bold, size: 9.5, gap: 2 });
        if (s?.signature_png) await image(s.signature_png, 170, 55); else y -= 20;
        if (s?.signed_at) write(`Signed ${day(s.signed_at)}`, { size: 8.5, gap: 8, color: 0.3 });
        continue;
      }
      const sg = afterAck ? sigFor(raw) : undefined;
      if (sg && !stamped.has(sg.id)) {
        stamped.add(sg.id);
        if (sg.signature_png) await image(sg.signature_png, 170, 55);
        write(raw, { font: bold, size: 9.5, gap: 1 });
        if (sg.signed_at) write(`Signed ${day(sg.signed_at)}`, { size: 8.5, gap: 8, color: 0.3 });
        continue;
      }
    }
    // The signing page shows a note where the agent's signature goes; the executed copy shows the signature itself.
    if (b.t === "p" && /^Agent signature applied when the agent countersigns$/i.test(raw)) { if (agent?.signature_png) await image(agent.signature_png, 170, 55); continue; }
    if (b.t === "h1") { y -= 4; write(text, { font: bold, size: 14, gap: 6 }); }
    else if (b.t === "h2") { y -= 4; write(text, { font: bold, size: 11, gap: 4 }); }
    else if (b.t === "h3") write(text, { font: bold, size: 10, gap: 3 });
    else if (b.t === "li") write("•  " + text, { indent: 12 });
    else if (b.t === "img" && b.src) await image(b.src, 200, 70);
    else if (b.t === "pb") newPage();
    else if (text) write(text);
  }

  // Signatures
  newPage();
  write("Signatures", { font: bold, size: 14, gap: 4 });
  write("These signatures apply to the whole lease, including every addendum in it (such as the Parking Agreement and the Rules and Regulations).", { gap: 8, color: 0.35 });
  const fmt = (iso: string) => new Date(iso).toLocaleString("en-US", { timeZone: "America/Chicago", dateStyle: "long", timeStyle: "long" });
  for (const s of signers) {
    write(`${s.name} (${s.role})`, { font: bold, size: 11, gap: 2 });
    if (s.signature_png) await image(s.signature_png, 220, 80);
    write(`Typed name: ${s.typed_name}`, { gap: 1 });
    if (s.initials) write(`Initials: ${s.initials}, on each of the ${(s.initialed_sections || []).length} initial lines (Parking Agreement sections)`, { gap: 1 });
    write(`Signed: ${fmt(s.signed_at)} (Central Time)`, { gap: 1 });
    // Leases confirmed before 10/7/2026 used a texted code; the audit trail says which.
    const how = String(events.find((e) => e.signer_id === s.id && e.event === "verified")?.detail || "");
    write(`Email: ${s.email} · identity confirmed by ${/texted/.test(how) ? `a code texted to ${s.phone ? maskPhone(s.phone) : "their phone"}` : "a one-time code emailed to this address"}`, { gap: 1 });
    write(`IP address: ${s.sign_ip || "—"}`, { gap: 10, color: 0.35 });
  }
  if (agent) {
    write(`${agent.name}${agent.title ? ", " + agent.title : ""}${agent.org ? " — " + agent.org : ""} (Agent for the Landlord)`, { font: bold, size: 11, gap: 2 });
    if (agent.signature_png) await image(agent.signature_png, 220, 80);
    write(`Countersigned: ${fmt(doc.agent_signed_at)} (Central Time), after all tenants signed`, { gap: 1 });
    write("Identity confirmed by two-step sign-in (an emailed code and the agent's authenticator app)", { gap: 1 });
    write(`IP address: ${doc.agent_sign_ip || "—"}`, { gap: 10, color: 0.35 });
  }

  // Certificate / audit trail
  newPage();
  write("Certificate of Completion", { font: bold, size: 14, gap: 6 });
  write(`Document: ${doc.title}, ${doc.unit_label}`);
  write(`Document ID: ${doc.id}`);
  write(`Document fingerprint (SHA-256 of the lease exactly as shown to the signers): ${doc.html_sha256}`);
  write(`Sent by: ${doc.created_by} on ${fmt(doc.created_at)}`);
  write("Each tenant opened a private link sent to their email, confirmed a one-time code sent to that email address, reviewed the full lease, initialed each initial line in it, consented to sign electronically, and signed by drawing their signature and typing their full name." +
    (agent ? " The agent then signed in with a two-step sign-in, reviewed the tenant-signed lease and countersigned; the agent's signature on file was applied by the system at that moment." : ""), { gap: 8 });
  write("Audit trail", { font: bold, size: 11, gap: 3 });
  const names = Object.fromEntries(signers.map((s) => [s.id, s.name]));
  for (const e of events) write(`${fmt(e.at)} — ${e.event}${e.signer_id ? ` — ${names[e.signer_id] || ""}` : ""}${e.ip ? ` — IP ${e.ip}` : ""}${e.detail ? ` — ${e.detail}` : ""}`, { size: 8.5, gap: 1 });

  const pages = pdf.getPages();
  pages.forEach((p, i) => p.drawText(safe(`${doc.unit_label} · Document ${String(doc.id).slice(0, 8)} · Page ${i + 1} of ${pages.length}`),
    { x: M, y: 28, size: 7.5, font: reg, color: rgb(0.45, 0.45, 0.45) }));
  return await pdf.save();
}

// Safe to run again: a second run reuses the stored PDF, the tenancy/renewal
// steps are idempotent, and the signed copies are emailed only once. The
// tenancy is recorded BEFORE any email, so a bounced address can't stop it;
// email problems are reported to staff instead of failing the whole step.
async function execute(docId: string, req: Request) {
  const { data: doc } = await admin.from("lease_signing_docs").select("*").eq("id", docId).single();
  const { data: signers } = await admin.from("lease_signing_signers").select("*").eq("doc_id", docId).order("position");
  let agent: Record<string, any> | null = null;
  if (doc.agent_id) {
    const { data: a } = await admin.from("lease_agents").select("*").eq("id", doc.agent_id).single();
    agent = a;
  }

  let bytes: Uint8Array;
  if (doc.status === "signed" && doc.executed_pdf_path) {
    const { data, error } = await admin.storage.from(BUCKET).download(doc.executed_pdf_path);
    if (error || !data) throw error || new Error("missing executed PDF");
    bytes = new Uint8Array(await data.arrayBuffer());
  } else {
    for (const s of signers || []) s.signature_png = await storageDataUrl(s.signature_path);
    if (agent) agent.signature_png = await storageDataUrl(agent.signature_path);
    await event(docId, null, "executed", req, agent ? "all tenants signed and agent countersigned" : "all signers signed");
    const { data: events } = await admin.from("lease_signing_events").select("*").eq("doc_id", docId).order("at");
    bytes = await buildPdf(doc, signers || [], events || [], agent);
    const path = `${docId}/executed-${Date.now()}.pdf`;
    const { error: upErr } = await admin.storage.from(BUCKET).upload(path, bytes, { contentType: "application/pdf" });
    if (upErr) throw upErr;
    const { error: dErr } = await admin.from("lease_signing_docs").update({ status: "signed", executed_at: new Date().toISOString(), executed_pdf_path: path }).eq("id", docId);
    if (dErr) throw dErr;
  }

  const problems: string[] = [];
  let newLeaseId: string | null = null;
  const unit = escapeHtml(doc.unit_label);

  // 1. Record it. Stage 7: a signed Lease Renewal Agreement extends the existing lease.
  // Stage 2: otherwise create the tenancy (tenants, lease, deposit + first month's rent
  // charges, signed lease on file); lease_from_signing queues the Welcome Letter.
  if (doc.renewal_id) {
    const { error: rErr } = await admin.rpc("renewal_from_signing", { p_doc: docId });
    if (rErr) problems.push(`<b>Record the renewal by hand.</b> The system could not update the lease: ${escapeHtml(rErr.message)}.`);
    else await event(docId, null, "renewal_recorded", req, "lease term extended");
  } else {
    const { data: leaseId, error: lErr } = await admin.rpc("lease_from_signing", { p_doc: docId });
    if (lErr) problems.push(`<b>Set up the lease by hand.</b> The system could not create the tenancy automatically: ${escapeHtml(lErr.message)}.`);
    else { newLeaseId = String(leaseId); await event(docId, null, "lease_created", req, `lease ${String(leaseId).slice(0, 8)} with move-in charges`); }
  }

  // 2. Signed copies, once.
  const { count: emailed } = await admin.from("lease_signing_events").select("id", { count: "exact", head: true }).eq("doc_id", docId).eq("event", "emailed");
  if (!emailed) {
    const b64 = btoa(Array.from(bytes, (c) => String.fromCharCode(c)).join(""));
    const filename = `Lease - ${String(doc.unit_label).replace(/[^\w #.,-]/g, "")} - signed.pdf`;
    const names = (signers || []).map((s) => escapeHtml(s.name)).join(", ");
    let sent = 0;
    for (const s of signers || []) {
      try {
        await sendEmail({
          to: s.email, subject: `Your signed lease — ${doc.unit_label}`,
          html: `<p>Hi ${escapeHtml(s.name.split(/\s+/)[0])},</p><p>Everyone has signed. Your copy of the signed lease for <b>${unit}</b> is attached. Keep it for your records.</p><p>Questions? Reply to this email.</p><p>2nd Chance Housing</p>`,
          attachments: [{ filename, content: b64 }],
        });
        sent++;
      } catch (e) {
        console.error("lease-signing: signed copy email failed", e instanceof Error ? e.message : String(e));
        problems.push(`Couldn't email the signed copy to ${escapeHtml(s.name)} (${escapeHtml(s.email)}). Send it to them from the attachment.`);
      }
    }
    try {
      await sendEmail({
        to: STAFF_NOTIFY_EMAIL, subject: `Lease signed — ${doc.unit_label}`,
        html: `<p>${names} signed the lease for <b>${unit}</b>${agent ? ` and ${escapeHtml(agent.name)} countersigned` : ""}. The executed copy is attached and stored in the system.</p>` +
          (problems.length ? `<p><b>Needs attention:</b></p><ul>${problems.map((p) => `<li>${p}</li>`).join("")}</ul>` : ""),
        attachments: [{ filename, content: b64 }],
      });
      problems.length = 0;   // reported in the email above
    } catch (e) {
      console.error("lease-signing: staff email failed", e instanceof Error ? e.message : String(e));
    }
    await event(docId, null, "emailed", req, `executed copy to ${sent} of ${(signers || []).length} signer(s)`);

    // 3. Caseworkers already listed for a tenant on this lease get the signed lease and ROCA1's W-9 as attachments, with no sign-in
    // (county mail systems often block our sign-in page). Caseworkers added later get them from the staff Caseworkers page.
    if (newLeaseId) {
      const { data: cws } = await admin.from("lease_tenants").select("tenant_id").eq("lease_id", newLeaseId);
      const tids = (cws || []).map((r: any) => r.tenant_id);
      const { data: links } = tids.length ? await admin.from("caseworker_clients").select("caseworkers!inner(id, name, email, active)").in("tenant_id", tids) : { data: [] };
      const seen = new Set<string>();
      for (const l of links || []) {
        const c = (l as any).caseworkers;
        if (!c?.active || seen.has(c.id)) continue;
        seen.add(c.id);
        try { await sendCaseworkerPacket(admin, c, newLeaseId); await event(docId, null, "caseworker_packet", req, "signed lease and W-9 emailed to a caseworker"); }
        catch (e) { console.error("lease-signing: caseworker packet failed", e instanceof Error ? e.message : String(e)); problems.push(`Couldn't email the lease packet to caseworker ${escapeHtml(c.name)}. Use Email documents on the Caseworkers page.`); }
      }
    }
  }
  if (problems.length) {
    await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: `Needs attention — signed lease for ${doc.unit_label}`,
      html: `<p>The lease for <b>${unit}</b> is fully signed.</p><ul>${problems.map((p) => `<li>${p}</li>`).join("")}</ul>` })
      .catch((e) => console.error("lease-signing: attention email failed", e instanceof Error ? e.message : String(e)));
  }
  // The Welcome Letter (portal + move-in amount) and renewal notices were queued in the database.
  await flushOutbox(admin).catch((e) => console.error("lease-signing: outbox flush failed", e instanceof Error ? e.message : String(e)));
}

// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const body = await req.json().catch(() => ({}));
    const action = body.action;

    if (action === "void" || action === "resend") {
      const { jwt, uc: userClient } = userClientFor(req);
      const { data: ok } = await userClient.rpc("staff_session_ok");
      const { data: u } = await admin.auth.getUser(jwt);
      const by = u?.user?.email;
      if (ok !== true || !by) return json(req, 403, { error: "Staff two-step sign-in required." });

      if (action === "void") {
        const reason = String(body.reason || "").trim().slice(0, 300);
        if (reason.length < 3) return json(req, 400, { error: "Say why the lease is being voided." });
        const { data: done, error } = await admin.from("lease_signing_docs").update({ status: "void", void_reason: reason })
          .eq("id", String(body.doc_id || "")).in("status", ["sent", "awaiting_agent"]).select("id, unit_label").maybeSingle();
        if (error) throw error;
        if (!done) return json(req, 409, { error: "Only a lease that isn't fully signed yet can be voided." });
        await event(done.id, null, "voided", req, `by ${by}: ${reason}`);
        const { data: signers } = await admin.from("lease_signing_signers").select("name, email").eq("doc_id", done.id);
        for (const t of signers || []) {
          await sendEmail({ to: t.email, subject: `Lease link cancelled — ${done.unit_label}`,
            html: `<p>Hi ${escapeHtml(t.name.split(/\s+/)[0])},</p><p>The lease we sent you for <b>${escapeHtml(done.unit_label)}</b> has been cancelled, and its signing link no longer works. If a corrected lease is on its way, you'll get a new email with a new link.</p><p>Questions? Reply to this email or call (262) 236-5443.</p><p>2nd Chance Housing</p>` })
            .catch((e) => console.error("lease-signing: void email failed", e instanceof Error ? e.message : String(e)));
        }
        return json(req, 200, { voided: true });
      }

      // resend
      const { data: s0 } = await admin.from("lease_signing_signers").select("*").eq("id", String(body.signer_id || "")).maybeSingle();
      if (!s0) return json(req, 404, { error: "Tenant not found." });
      if (s0.signed_at) return json(req, 409, { error: `${s0.name} has already signed.` });
      const { data: d0 } = await admin.from("lease_signing_docs").select("id, unit_label, title, status").eq("id", s0.doc_id).single();
      if (d0!.status !== "sent") return json(req, 409, { error: "This lease isn't waiting for tenant signatures." });
      const token = randomToken();
      const { error: tErr } = await admin.from("lease_signing_signers").update({ token_hash: await sha256(token), sent_at: new Date().toISOString(),
        verified_at: null, code_hash: null, code_expires_at: null, code_attempts: 0 }).eq("id", s0.id);
      if (tErr) throw tErr;
      const link = `${SIGN_BASE_URL}#t=${token}`;
      const renewal = d0!.title === "Lease Renewal Agreement";
      await sendEmail({
        to: s0.email, subject: `${renewal ? "Sign your lease renewal" : "Your lease is ready to sign"} — ${d0!.unit_label} (new link)`,
        html: `<p>Hi ${escapeHtml(s0.name.split(/\s+/)[0])},</p><p>Here is a new link to review and sign your ${renewal ? "Lease Renewal Agreement" : "lease"} for <b>${escapeHtml(d0!.unit_label)}</b>. Any earlier link no longer works.</p>
          <p><a href="${link}" style="display:inline-block;background:#2e7d1f;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">Review and sign</a></p>
          <p>If the button doesn't work, copy this link into your browser:<br>${link}</p>
          <p>To confirm it's you, the page will email you a code when you tap "Email me a code". This link is just for you; please don't forward it.</p><p>2nd Chance Housing</p>`,
      });
      await event(d0!.id, s0.id, "emailed_link", req, `new link sent by ${by}; the old link stopped working`);
      return json(req, 200, { resent: true });
    }

    if (action === "send") {
      const { jwt, uc: userClient } = userClientFor(req);
      const { data: ok } = await userClient.rpc("staff_session_ok");
      const { data: u } = await admin.auth.getUser(jwt);
      if (ok !== true || !u?.user?.email) return json(req, 403, { error: "Staff two-step sign-in required." });

      const html = String(body.html || ""), blocks = Array.isArray(body.blocks) ? body.blocks : [];
      if (html.length < 500 || html.length > 3_000_000 || !blocks.length) return json(req, 400, { error: "The lease content is missing." });
      const signers = (Array.isArray(body.signers) ? body.signers : []).slice(0, 4).map((s: Record<string, unknown>) => ({
        name: String(s.name || "").trim(), email: String(s.email || "").trim().toLowerCase(), phone: toE164(s.phone),
      }));
      if (!signers.length) return json(req, 400, { error: "Add at least one tenant to sign." });
      for (const s of signers) {
        if (s.name.length < 2 || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s.email)) return json(req, 400, { error: `Check the name and email for ${s.name || "each tenant"}.` });
      }
      const unit = String(body.unit_label || "").trim().slice(0, 120);
      if (!unit) return json(req, 400, { error: "The unit is missing." });
      let agentId: string | null = null;
      if (body.agent_id) {
        const { data: a } = await admin.from("lease_agents").select("id, active, signature_path").eq("id", body.agent_id).maybeSingle();
        if (!a || !a.active) return json(req, 400, { error: "That agent isn't on file." });
        if (!a.signature_path) return json(req, 400, { error: "That agent has no signature on file yet." });
        agentId = a.id;
      }

      const appId = /^[0-9a-f-]{36}$/.test(body.application_id || "") ? body.application_id : null;
      if (appId) {
        const { data: live } = await admin.from("lease_signing_docs").select("id, status").or(`application_id.eq.${appId},co_application_ids.cs.{${appId}}`).neq("status", "void").limit(1).maybeSingle();
        if (live) return json(req, 409, { error: `This application already has a lease ${live.status === "signed" ? "signed" : "out for signature"} (document ${String(live.id).slice(0, 8)}). To send a corrected one, void it on the Applications page first.` });
      }
      // The other applicants on this lease (up to three besides the first), each from their own application.
      const coIds = [...new Set((Array.isArray(body.co_application_ids) ? body.co_application_ids : []).map(String).filter((x: string) => /^[0-9a-f-]{36}$/.test(x) && x !== appId))].slice(0, 3);
      for (const cid of coIds) {
        const { data: live } = await admin.from("lease_signing_docs").select("id, status").neq("status", "void").or(`application_id.eq.${cid},co_application_ids.cs.{${cid}}`).limit(1).maybeSingle();
        if (live) return json(req, 409, { error: `One of the other applicants already has a lease ${live.status === "signed" ? "signed" : "out for signature"} (document ${String(live.id).slice(0, 8)}). Void it on the Applications page first, or remove that applicant from this lease.` });
      }
      const { data: doc, error } = await admin.from("lease_signing_docs").insert({
        unit_label: unit, title: String(body.title || "Residential Rental Agreement").slice(0, 120), html, html_sha256: await sha256(html),
        blocks, lease_data: body.lease_data || {}, created_by: u.user.email, agent_id: agentId,
        application_id: appId, co_application_ids: coIds,
      }).select("*").single();
      if (error) throw error;
      await event(doc.id, null, "sent", req, `by ${u.user.email}`);

      for (const [i, s] of signers.entries()) {
        const token = randomToken();
        const { data: row, error: sErr } = await admin.from("lease_signing_signers").insert({
          doc_id: doc.id, position: i + 1, name: s.name, email: s.email, phone: s.phone, token_hash: await sha256(token), sent_at: new Date().toISOString(),
        }).select("id").single();
        if (sErr) throw sErr;
        const link = `${SIGN_BASE_URL}#t=${token}`;
        await sendEmail({
          to: s.email, subject: `Your lease for ${unit} is ready to sign`,
          html: `<p>Hi ${escapeHtml(s.name.split(/\s+/)[0])},</p><p>Your lease for <b>${escapeHtml(unit)}</b> is ready. Review it and sign on our website:</p>
            <p><a href="${link}" style="display:inline-block;background:#2e7d1f;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">Review and sign my lease</a></p>
            <p>If the button doesn't work, copy this link into your browser:<br>${link}</p>
            <p>To confirm it's you, the page will email you a code when you tap "Email me a code". This link is just for you; please don't forward it.</p><p>2nd Chance Housing</p>`,
        });
        await event(doc.id, row.id, "emailed_link", req, s.email);
      }
      return json(req, 200, { id: doc.id });
    }

    if (action === "renewal_sign") {
      // Stage 7: the tenant accepted a renewal offer in the portal.
      const { uc } = userClientFor(req);
      const renewalId = String(body.renewal_id || "");
      const { data: r, error: rErr } = await uc.rpc("resident_renewal_accept", { p_id: renewalId });
      if (rErr) return json(req, 400, { error: rErr.message });
      const undo = (msg: string) => admin.from("lease_renewals").update({ status: "offered", answered_at: null }).eq("id", renewalId).then(() => json(req, 400, { error: msg }));
      const signers = ((r.signers || []) as Record<string, unknown>[]).slice(0, 4).map((s) => ({ name: String(s.name), email: String(s.email).toLowerCase(), phone: toE164(s.phone) }));
      if (!signers.length) return await undo("No tenant email on file. Message the office.");
      if (!r.agent_id) return await undo("The office can't countersign online right now. Message the office.");
      const html = String(r.html), blocks = htmlToBlocks(html);
      const { data: doc, error } = await admin.from("lease_signing_docs").insert({
        unit_label: String(r.unit_label).slice(0, 120), title: "Lease Renewal Agreement", html, html_sha256: await sha256(html), blocks,
        lease_data: {}, created_by: "tenant accepted renewal", agent_id: r.agent_id, lease_id: r.lease_id, renewal_id: renewalId,
      }).select("*").single();
      if (error) throw error;
      await admin.from("lease_renewals").update({ signing_doc_id: doc.id }).eq("id", renewalId);
      await event(doc.id, null, "sent", req, "tenant accepted the renewal offer in the portal");
      for (const [i, s] of signers.entries()) {
        const token = randomToken();
        const { data: row, error: sErr } = await admin.from("lease_signing_signers").insert({
          doc_id: doc.id, position: i + 1, name: s.name, email: s.email, phone: s.phone, token_hash: await sha256(token), sent_at: new Date().toISOString(),
        }).select("id").single();
        if (sErr) throw sErr;
        const link = `${SIGN_BASE_URL}#t=${token}`;
        await sendEmail({
          to: s.email, subject: `Sign your lease renewal — ${doc.unit_label}`,
          html: `<p>Hi ${escapeHtml(s.name.split(/\s+/)[0])},</p><p>Your Lease Renewal Agreement for <b>${escapeHtml(doc.unit_label)}</b> is ready. Review it and sign on our website:</p>
            <p><a href="${link}" style="display:inline-block;background:#2e7d1f;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">Review and sign my renewal</a></p>
            <p>If the button doesn't work, copy this link into your browser:<br>${link}</p>
            <p>To confirm it's you, the page will email you a code when you tap "Email me a code". This link is just for you; please don't forward it.</p><p>2nd Chance Housing</p>`,
        });
        await event(doc.id, row.id, "emailed_link", req, s.email);
      }
      return json(req, 200, { id: doc.id, signers: signers.length });
    }

    if (action === "countersign") {
      const { uc } = userClientFor(req);
      const { data: agentId } = await uc.rpc("lease_agent_me");
      if (!agentId) return json(req, 403, { error: "Please sign in as the agent (email code and authenticator app)." });
      if (body.consent !== true) return json(req, 400, { error: "Please check the box to confirm your countersignature." });
      const { data: doc } = await admin.from("lease_signing_docs").select("*").eq("id", String(body.doc_id || "")).maybeSingle();
      if (!doc || doc.agent_id !== agentId) return json(req, 404, { error: "Lease not found." });
      if (doc.status !== "awaiting_agent") return json(req, 409, { error: doc.status === "signed" ? "This lease is already countersigned." : "Not every tenant has signed yet." });
      if (doc.agent_signed_at) {
        // Countersigned before, but finishing failed part-way (the lease is still awaiting_agent): finish it now.
        await event(doc.id, null, "agent_countersign_retry", req, "finishing a countersignature that did not complete");
      } else {
        const { data: done, error } = await admin.from("lease_signing_docs").update({
          agent_signed_at: new Date().toISOString(), agent_sign_ip: clientIp(req), agent_sign_user_agent: ua(req),
        }).eq("id", doc.id).eq("status", "awaiting_agent").is("agent_signed_at", null).select("id");
        if (error) throw error;
        if (!done?.length) return json(req, 409, { error: "This lease is already countersigned." });
        await event(doc.id, null, "agent_countersigned", req, "agent signed in with email code and authenticator app; signature on file applied");
      }
      await execute(doc.id, req);
      return json(req, 200, { executed: true });
    }

    if (action === "open" || action === "send_code" || action === "verify" || action === "sign") {
      const found = await signerFor(body.token);
      if (!found) return json(req, 404, { error: "This signing link isn't valid anymore. Contact 2nd Chance Housing for a new one." });
      const { s, doc } = found;
      const { data: all } = await admin.from("lease_signing_signers").select("id, name, signed_at, position").eq("doc_id", doc.id).order("position");
      const others = (all || []).map((o) => ({ name: o.name, signed: !!o.signed_at, you: o.id === s.id }));
      const summary = { title: doc.title, unit_label: doc.unit_label, signer_name: s.name, email_hint: maskEmail(s.email), signers: others,
        executed: doc.status === "signed", awaiting_agent: doc.status === "awaiting_agent" };

      // Opening the page sends nothing (email scanners open links); the code goes out on "Email me a code".
      if (action === "open") {
        if (!s.viewed_at) await admin.from("lease_signing_signers").update({ viewed_at: new Date().toISOString() }).eq("id", s.id);
        await event(doc.id, s.id, "opened", req);
        return json(req, 200, { ...summary, signed: !!s.signed_at });
      }

      if (action === "send_code") {
        if (s.signed_at) return json(req, 409, { error: "You've already signed this lease." });
        const { data: sent } = await admin.from("lease_signing_events").select("at").eq("signer_id", s.id).eq("event", "code_sent")
          .gte("at", new Date(Date.now() - 3600_000).toISOString()).order("at", { ascending: false });
        if ((sent || []).length >= MAX_CODES_PER_HOUR) return json(req, 429, { error: "Too many codes requested. Wait an hour and try again." });
        if (sent?.length && Date.now() - new Date(sent[0].at).getTime() < CODE_COOLDOWN_MS) return json(req, 429, { error: "A code was just sent. Check your email (and spam), or wait a minute to send a new one." });
        const code = String(100000 + (crypto.getRandomValues(new Uint32Array(1))[0] % 900000));
        const { error: cErr } = await admin.from("lease_signing_signers").update({
          code_hash: await sha256(s.id + ":" + code), code_expires_at: new Date(Date.now() + CODE_TTL_MS).toISOString(), code_attempts: 0,
        }).eq("id", s.id);
        if (cErr) throw cErr;
        try {
          await sendEmail({
            to: s.email, subject: `${code} is your code to sign your lease`,
            html: `<div style="font-family:Arial,sans-serif;max-width:520px;color:#1b2430"><p>Your code to open your lease for <b>${escapeHtml(doc.unit_label)}</b> is:</p>
              <p style="font-size:30px;letter-spacing:6px;font-weight:700;margin:12px 0">${code}</p>
              <p>Enter it on the signing page. It expires in 10 minutes and works once.</p>
              <p style="color:#5b6573;font-size:13px">If you didn't ask for this, you can ignore this email. Nobody can sign without this code.</p></div>`,
          });
        } catch (e) {
          console.error("lease-signing: code email failed", e instanceof Error ? e.message : String(e));
          return json(req, 502, { error: "We couldn't send the email. Try again in a minute." });
        }
        await event(doc.id, s.id, "code_sent", req, `emailed to ${maskEmail(s.email)}`);
        return json(req, 200, { sent: true, email_hint: maskEmail(s.email) });
      }

      if (action === "verify") {
        if (s.signed_at) return json(req, 409, { error: "You've already signed this lease." });
        const code = String(body.code || "").replace(/\D/g, "");
        if (code.length !== 6) return json(req, 400, { error: "Enter the 6-digit code from the email." });
        if (!s.code_hash || !s.code_expires_at || new Date(s.code_expires_at).getTime() < Date.now()) return json(req, 400, { error: "That code expired. Tap Send a new code." });
        if ((s.code_attempts || 0) >= MAX_CODE_ATTEMPTS) return json(req, 400, { error: "Too many wrong tries. Tap Send a new code." });
        if (s.code_hash !== await sha256(s.id + ":" + code)) {
          await admin.from("lease_signing_signers").update({ code_attempts: (s.code_attempts || 0) + 1 }).eq("id", s.id);
          return json(req, 400, { error: "That code didn't match." });
        }
        await admin.from("lease_signing_signers").update({ verified_at: new Date().toISOString(), code_hash: null, code_expires_at: null, code_attempts: 0 }).eq("id", s.id);
        await event(doc.id, s.id, "verified", req, "emailed code confirmed");
        return json(req, 200, { ...summary, html: doc.html, fingerprint: doc.html_sha256 });
      }

      // sign
      if (s.signed_at) return json(req, 409, { error: "You've already signed this lease." });
      if (!s.verified_at || Date.now() - new Date(s.verified_at).getTime() > VERIFY_WINDOW_MS) return json(req, 401, { error: "Please confirm with a new emailed code before signing (reload the page)." });
      if (body.consent !== true) return json(req, 400, { error: "Please check the box to agree to sign electronically." });
      const typed = String(body.typed_name || "").trim();
      if (norm(typed) !== norm(s.name)) return json(req, 400, { error: `Type your full name exactly as it appears on the lease: ${s.name}` });
      const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(String(body.signature || ""));
      if (!m) return json(req, 400, { error: "Please draw your signature." });
      const png = Uint8Array.from(atob(m[1]), (c) => c.charCodeAt(0));
      if (png.length < 1500 || png.length > 400_000) return json(req, 400, { error: "Please draw your signature again." });
      const required = initialLines(doc.html);
      let initials: string | null = null;
      if (required.length) {
        initials = String(body.initials || "").trim().toUpperCase();
        if (!/^[A-Z][A-Z. -]{0,7}$/.test(initials)) return json(req, 400, { error: "Enter your initials (letters only), then tap each \"Initial here\" in the lease." });
        const got = new Set((Array.isArray(body.initialed) ? body.initialed : []).map(String));
        const left = required.filter((id) => !got.has(id)).length;
        if (left) return json(req, 400, { error: `Initial every initial line in the lease first (${left} left). Tap "Next initial" to find them.` });
      }
      const path = `${doc.id}/signature-${s.id}.png`;
      const { error: upErr } = await admin.storage.from(BUCKET).upload(path, png, { contentType: "image/png", upsert: true });
      if (upErr) throw upErr;
      const now = new Date().toISOString();
      const { data: mine, error: uErr } = await admin.from("lease_signing_signers").update({
        signed_at: now, typed_name: typed, signature_path: path, sign_ip: clientIp(req), sign_user_agent: ua(req),
        initials, initialed_sections: required.length ? required : null,
      }).eq("id", s.id).is("signed_at", null).select("id");
      if (uErr) throw uErr;
      if (!mine?.length) return json(req, 409, { error: "You've already signed this lease." });
      if (required.length) await event(doc.id, s.id, "initialed", req, `${required.length} initial lines (Parking Agreement sections ${required[0]}–${required[required.length - 1]}) initialed "${initials}"`);
      await event(doc.id, s.id, "signed", req, `typed name "${typed}"; signature image SHA-256 ${await sha256(png)}`);

      const { count: unsigned } = await admin.from("lease_signing_signers").select("id", { count: "exact", head: true }).eq("doc_id", doc.id).is("signed_at", null);
      // From here the tenant's signature is saved: a failure below must not tell them to sign again.
      if ((unsigned || 0) === 0) {
        if (doc.agent_id) {
          // Only the request that moves the lease to awaiting_agent sends the emails (two tenants can finish at the same moment).
          const { data: moved } = await admin.from("lease_signing_docs").update({ status: "awaiting_agent" }).eq("id", doc.id).eq("status", "sent").select("id");
          if (moved?.length) {
            await event(doc.id, null, "awaiting_agent", req, "all tenants signed");
            try {
              const { data: a } = await admin.from("lease_agents").select("name, email").eq("id", doc.agent_id).single();
              const link = new URL("/leasing/countersign/", PORTAL_BASE_URL).toString();
              await sendEmail({ to: a!.email, subject: `Ready for your countersignature — ${doc.unit_label}`,
                html: `<p>Hi ${escapeHtml(a!.name.split(/\s+/)[0])},</p><p>All tenants have signed the lease for <b>${escapeHtml(doc.unit_label)}</b>. Please sign in to review it and countersign:</p><p><a href="${link}">${link}</a></p><p>You'll sign in with an email code and your authenticator app.</p>` });
              await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: `Tenants signed — ${doc.unit_label} (waiting for ${a!.name})`,
                html: `<p>All tenants signed the lease for <b>${escapeHtml(doc.unit_label)}</b>. It's waiting for ${escapeHtml(a!.name)}'s countersignature.</p>` });
            } catch (e) {
              console.error("lease-signing: countersign request email failed", e instanceof Error ? e.message : String(e));
            }
          }
          return json(req, 200, { signed: true, executed: false, awaiting_agent: true });
        }
        try {
          await execute(doc.id, req);
          return json(req, 200, { signed: true, executed: true });
        } catch (e) {
          console.error("lease-signing: execute failed", e instanceof Error ? e.message : String(e));
          await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: `Needs attention — signed lease for ${doc.unit_label}`,
            html: `<p>Every tenant signed the lease for <b>${escapeHtml(doc.unit_label)}</b> (document ${escapeHtml(String(doc.id).slice(0, 8))}), but building the signed copy failed. Nothing is lost; the signatures are saved. Ask for help finishing it.</p>` }).catch(() => {});
          return json(req, 200, { signed: true, executed: false });
        }
      }
      return json(req, 200, { signed: true, executed: false });
    }

    return json(req, 400, { error: "Unknown action" });
  } catch (err) {
    console.error("lease-signing: error", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "Something went wrong. Try again." });
  }
});
