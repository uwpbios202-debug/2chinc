// An owner emails the tenant of one of their own units.
//   POST { tenant_id, subject, message }  (owner JWT in Authorization) -> { sent: true }
// The tenant must be a current tenant in a unit this owner owns (checked through the owner's
// own session). The tenant's address is looked up here and never sent to the browser. The
// message carries the owner's name, Reply-To is the owner, and the office is copied.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml as esc, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
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

    const body = await req.json().catch(() => ({}));
    const subject = String(body.subject || "").trim().slice(0, 150), message = String(body.message || "").trim().slice(0, 5000);
    if (!subject || !message) return json(req, 400, { error: "Add a subject and a message." });

    const { data: mine, error } = await uc.rpc("condo_my_tenants");
    if (error || !mine) return json(req, 403, { error: "Sign in as an owner first." });
    const hit = (mine as { unit_number: string; tenants: { id: string; name: string }[] }[])
      .flatMap((x) => x.tenants.map((t) => ({ ...t, unit: x.unit_number }))).find((t) => t.id === String(body.tenant_id || ""));
    if (!hit) return json(req, 400, { error: "Choose one of your tenants." });
    const { data: me } = await uc.rpc("condo_my_profile");

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const { data: t } = await admin.from("tenants").select("email").eq("id", hit.id).maybeSingle();
    if (!t?.email) return json(req, 422, { error: `We don't have an email address for ${hit.name}. Contact the office at ${OFFICE}.` });

    const owner = me?.name || from;
    await sendEmail({
      to: t.email, replyTo: from, subject,
      html: `<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430">
        <p>A message from <b>${esc(owner)}</b>, owner of Unit ${esc(hit.unit)}, Royal Orleans Condominium:</p>
        <p style="white-space:pre-wrap;border-left:3px solid #ccd3dc;padding-left:12px">${esc(message)}</p>
        <p style="color:#5b6573;font-size:13px">Reply to this email to answer ${esc(owner)}. Sent through 2nd Chance Housing.</p></div>`,
    });
    // Copy for the office's records (not shown to the tenant).
    await sendEmail({ to: OFFICE, replyTo: from, subject: `[Owner to tenant, Unit ${hit.unit}] ${subject}`,
      html: `<p>${esc(owner)} (${esc(from)}) wrote to ${esc(hit.name)}:</p><p style="white-space:pre-wrap">${esc(message)}</p>` }).catch(() => {});
    try { await uc.rpc("owner_log_mail", { p_kind: "tenant", p_unit: hit.unit, p_to: hit.name, p_subject: subject, p_body: message }); } catch (_) { /* ignore */ }
    return json(req, 200, { sent: true, tenant: hit.name });
  } catch (err) {
    console.error("owner-tenant-email:", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "We couldn't send your message. Try again or contact the office." });
  }
});
