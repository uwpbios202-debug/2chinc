// Receives Resend's email events (delivered, opened, bounced, complained, delayed, failed) and records them in
// email_log, one row per email. Set up once in the Resend dashboard (Webhooks):
//   URL     https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/resend-webhook
//   Events  email.delivered, email.delivery_delayed, email.bounced, email.complained, email.opened, email.failed
//   Secret  the signing secret shown there (whsec_...), stored as the Supabase secret RESEND_WEBHOOK_SECRET.
// "Open tracking" must also be switched on for the sending domain (Resend, Domains) or no opened events arrive.
//
// Public endpoint (verify_jwt off): every call must carry a valid Svix signature, or it is refused.
import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL, escapeHtml } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const SECRET = Deno.env.get("RESEND_WEBHOOK_SECRET") || "";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const ok = () => new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (!SECRET) return new Response("Webhook secret is not set", { status: 503 });
  const raw = await req.text();
  let evt: { type?: string; created_at?: string; data?: Record<string, unknown> };
  try {
    // Resend signs with Svix (svix-id / svix-timestamp / svix-signature); the verifier expects the standard webhook-* names.
    const h = req.headers;
    const headers = {
      "webhook-id": h.get("svix-id") || h.get("webhook-id") || "",
      "webhook-timestamp": h.get("svix-timestamp") || h.get("webhook-timestamp") || "",
      "webhook-signature": h.get("svix-signature") || h.get("webhook-signature") || "",
    };
    evt = new Webhook(SECRET).verify(raw, headers) as typeof evt;
  } catch (err) {
    console.error("resend-webhook: bad signature", err instanceof Error ? err.message : String(err));
    return new Response("Invalid signature", { status: 401 });
  }
  try {
    const d = (evt.data || {}) as { email_id?: string; to?: string[] | string; subject?: string; created_at?: string; bounce?: { message?: string; type?: string; subType?: string } };
    const type = String(evt.type || "");
    if (!type.startsWith("email.") || !d.email_id) return ok();
    const to = Array.isArray(d.to) ? d.to[0] : (d.to || "");
    const reason = d.bounce ? [d.bounce.type, d.bounce.subType, d.bounce.message].filter(Boolean).join(": ") : null;
    const { error } = await admin.rpc("email_log_event", {
      p_resend_id: d.email_id, p_event: type, p_at: evt.created_at || d.created_at || new Date().toISOString(),
      p_to: String(to), p_subject: d.subject || null, p_reason: reason,
    });
    if (error) throw error;
    // Tell the office right away about a bounce, once per event.
    if (type === "email.bounced" || type === "email.complained") {
      sendEmail({
        to: STAFF_NOTIFY_EMAIL, subject: `Email bounced: ${String(to)}`,
        html: `<p>An email to <b>${escapeHtml(String(to))}</b> ${type === "email.complained" ? "was marked as spam" : "bounced"}${reason ? ": " + escapeHtml(reason) : ""}.</p>
          <p>Subject: ${escapeHtml(d.subject || "")}</p><p><a href="https://2ndchinc.org/staff/reports/">Fix the address</a> (staff two-step sign-in).</p>`,
      }).catch((e) => console.error("resend-webhook: alert failed", e instanceof Error ? e.message : String(e)));
    }
    return ok();
  } catch (err) {
    console.error("resend-webhook: error", err instanceof Error ? err.stack || err.message : String(err));
    return new Response("error", { status: 500 });
  }
});
