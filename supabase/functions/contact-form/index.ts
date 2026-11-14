// Public Contact form (2ndchinc.org/contact/). Anyone may post { email, message }; the message is emailed to
// info@2ndchinc.org with the visitor's address as Reply-To. verify_jwt is off, so the protections live here:
// a hidden honeypot field, length limits, and rate limits per sender and overall.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";
import { turnstileOk } from "../_shared/turnstile.ts";

const TO = "info@2ndchinc.org";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const b = await req.json().catch(() => ({}));
    if (String(b.website || "").trim() !== "") return json(req, 200, { ok: true });          // honeypot: pretend it worked
    const email = String(b.email || "").trim().toLowerCase().slice(0, 200);
    const message = String(b.message || "").trim().slice(0, 2000);
    if (!EMAIL_RE.test(email)) return json(req, 400, { error: "Enter a full email address so we can reply." });
    if (message.length < 5) return json(req, 400, { error: "Tell us why you are contacting us." });
    if (!(await turnstileOk(b.turnstile, req))) return json(req, 400, { error: "The security check did not pass. Reload the page and try again." });
    const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const [{ count: mine }, { count: all }] = await Promise.all([
      admin.from("contact_messages").select("id", { count: "exact", head: true }).eq("email", email).gte("created_at", since),
      admin.from("contact_messages").select("id", { count: "exact", head: true }).gte("created_at", since)]);
    if ((mine || 0) >= 3 || (all || 0) >= 40) return json(req, 429, { error: "We got several messages already. Please call (262) 236-5443 or try again in an hour." });
    const { error } = await admin.from("contact_messages").insert({ email, message });
    if (error) throw error;
    await sendEmail({
      to: TO, replyTo: email, subject: `Website message from ${email}`,
      html: `<p><b>New message from the website Contact page</b></p><p>From: ${escapeHtml(email)}</p><p style="white-space:pre-wrap">${escapeHtml(message)}</p><p style="color:#666;font-size:12px">Reply to this email to answer them.</p>`,
    });
    return json(req, 200, { ok: true });
  } catch (err) {
    console.error("contact-form: error", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "We couldn't send that. Please email info@2ndchinc.org or call (262) 236-5443." });
  }
});
