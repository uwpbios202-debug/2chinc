// An owner emails the office from the portal.
//   POST { subject, message, unit_number? }  (owner JWT in Authorization) -> { sent: true }
// Goes to info@2ndchinc.org with Reply-To set to the owner's sign-in email, so the
// office can simply reply. The owner is identified by their session, never by the form.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml as esc, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const OFFICE = "info@2ndchinc.org";
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const { data: u } = await uc.auth.getUser(jwt);
    const from = u?.user?.email;
    if (!from) return json(req, 401, { error: "Please sign in." });
    const { data: me, error } = await uc.rpc("condo_my_profile");
    if (error || !me) return json(req, 403, { error: "Sign in as an owner first." });

    const body = await req.json().catch(() => ({}));
    const subject = String(body.subject || "").trim().slice(0, 150), message = String(body.message || "").trim().slice(0, 5000);
    if (!subject || !message) return json(req, 400, { error: "Add a subject and a message." });
    const units = (me.units || []).map((x: { unit_number: string }) => x.unit_number);
    const unit = units.includes(String(body.unit_number || "")) ? String(body.unit_number) : "";

    await sendEmail({
      to: OFFICE, replyTo: from, subject: `[Owner portal] ${subject}`,
      html: `<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430">
        <p><b>${esc(me.name || from)}</b> (${esc(from)})${unit ? ` · Unit ${esc(unit)}` : units.length ? ` · Units ${units.map(esc).join(", ")}` : ""}</p>
        <p style="white-space:pre-wrap;border-left:3px solid #ccd3dc;padding-left:12px">${esc(message)}</p>
        <p style="color:#5b6573;font-size:13px">Sent from the owner portal. Reply to answer ${esc(from)}.</p></div>`,
    });
    // Keep it on the owner's Communications history (a failure here never blocks the message).
    try { await uc.rpc("owner_log_mail", { p_kind: "office", p_unit: unit, p_to: OFFICE, p_subject: subject, p_body: message }); } catch (_) { /* ignore */ }
    return json(req, 200, { sent: true });
  } catch (err) {
    console.error("owner-email:", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "We couldn't send your message. Email info@2ndchinc.org directly." });
  }
});
