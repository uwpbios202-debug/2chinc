// Staff emails 2nd Chance Housing Inc's W-9 (signed on screen) to whoever is paying a tenant's rent or deposit.
//   POST { to: string[], for_name?, message?, signature (PNG data URL), typed_name }  (staff JWT in Authorization) -> { sent: n }
// The blank IRS form is filled here (page 1 only), the drawn signature and today's date are placed on the
// signature line, the form is flattened, and the PDF is attached. Replies go to the office, which gets a copy.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";
import { cors, escapeHtml as esc, PORTAL_BASE_URL, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const OFFICE = "info@2ndchinc.org";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const P = "topmostSubform[0].Page1[0].";

async function buildW9(signature: Uint8Array, today: string) {
  const r = await fetch(new URL("/assets/forms/fw9.pdf", PORTAL_BASE_URL));
  if (!r.ok) throw new Error("blank W-9 not found");
  const pdf = await PDFDocument.load(new Uint8Array(await r.arrayBuffer()));
  const f = pdf.getForm();
  f.getTextField(P + "f1_01[0]").setText("2nd Chance Housing Inc");
  f.getCheckBox(P + "Boxes3a-b_ReadOrder[0].c1_1[1]").check();               // C corporation
  f.getTextField(P + "f1_05[0]").setText("1");                                // exempt payee code: 501(a) organization
  f.getTextField(P + "Address_ReadOrder[0].f1_07[0]").setText("6626 N Bourbon St");
  f.getTextField(P + "Address_ReadOrder[0].f1_08[0]").setText("Milwaukee, WI 53224");
  f.getTextField(P + "f1_14[0]").setText("47");
  f.getTextField(P + "f1_15[0]").setText("5387503");
  f.flatten();
  for (let i = pdf.getPageCount() - 1; i >= 1; i--) pdf.removePage(i);       // the form itself, without the instructions
  const page = pdf.getPage(0);
  const img = await pdf.embedPng(signature);
  const h = 26, w = Math.min(img.width * (h / img.height), 220);
  page.drawImage(img, { x: 142, y: 196, width: w, height: h });
  page.drawText(today, { x: 418, y: 200, size: 10, font: await pdf.embedFont(StandardFonts.Helvetica), color: rgb(0, 0, 0) });
  return await pdf.save();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(jwt);
    const me = u?.user?.email?.toLowerCase();
    const { data: st } = me ? await admin.from("condo_staff").select("name").ilike("email", me).maybeSingle() : { data: null };
    if (!st) return json(req, 403, { error: "Staff only." });

    const body = await req.json().catch(() => ({}));
    const to = [...new Set((Array.isArray(body.to) ? body.to : []).map((x: unknown) => String(x).trim().toLowerCase()).filter(Boolean))] as string[];
    if (!to.length || to.length > 5 || to.some((e) => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e))) return json(req, 400, { error: "Enter one to five valid email addresses." });
    const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(String(body.signature || ""));
    if (!m) return json(req, 400, { error: "Please draw your signature." });
    const sig = Uint8Array.from(atob(m[1]), (c) => c.charCodeAt(0));
    if (sig.length < 1500 || sig.length > 400_000) return json(req, 400, { error: "Please draw your signature again." });

    const today = new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago" }).format(new Date());
    const bytes = await buildW9(sig, today);
    const b64 = btoa(Array.from(bytes, (c) => String.fromCharCode(c)).join(""));
    const who = String(body.for_name || "").trim().slice(0, 120);
    const note = String(body.message || "").trim().slice(0, 3000);
    const html = `<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430">
      <p>Hello,</p>
      <p>Attached is the signed IRS Form W-9 for <b>2nd Chance Housing Inc</b>, the payee for the rent and security deposit${who ? ` for <b>${esc(who)}</b>` : ""}.</p>
      ${note ? `<p style="white-space:pre-wrap">${esc(note)}</p>` : ""}
      <p>Please make payment through the instructions on file, and reply to this email if you need anything else.</p>
      <p>2nd Chance Housing Inc<br>6626 N Bourbon St, Milwaukee, WI 53224<br>${OFFICE}</p></div>`;
    const subject = `W-9 from 2nd Chance Housing Inc${who ? ` (${who})` : ""}`;
    const attachments = [{ filename: "W-9 - 2nd Chance Housing Inc.pdf", content: b64 }];
    for (const addr of to) await sendEmail({ to: addr, replyTo: OFFICE, subject, html, attachments });
    await sendEmail({ to: OFFICE, subject: `[W-9 sent] ${subject}`, attachments,
      html: `<p>${esc(st.name || me)} sent the signed W-9 to ${esc(to.join(", "))}${who ? ` for ${esc(who)}` : ""}.</p>` }).catch(() => {});
    return json(req, 200, { sent: to.length });
  } catch (err) {
    console.error("w9-send:", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "We couldn't send the W-9. Try again." });
  }
});
