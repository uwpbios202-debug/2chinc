// "Report a problem" button, on every tenant-facing page. Public endpoint: verify_jwt is off.
//
// POST { message, contact_name?, contact_email?, contact_phone?, page_url, page_title, user_agent, viewport,
//        errors?: string[], photo?: "data:image/jpeg;base64,...", access_token?, website? (honeypot) }
//   -> { ok: true, ref }
//
// The report lands in issue_reports (read by staff at /staff/reports/), staff get an email, and the person gets
// a receipt if they gave an email. If the person was signed in, access_token (their portal session) ties the report
// to their tenant record; otherwise a matching email on file does. The page address is stored WITHOUT its query
// string or hash, because signing links carry a private token there.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml, SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

const MAX_PER_IP_HOUR = 8;
const MAX_ALL_HOUR = 80;
const MAX_PHOTO_BYTES = 3 * 1024 * 1024;
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const str = (v: unknown, max = 200) => String(v ?? "").trim().slice(0, max);
const ipOf = (req: Request) => (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "unknown";

function cleanUrl(v: unknown) {
  try { const u = new URL(String(v || "")); return (u.origin + u.pathname).slice(0, 300); } catch { return ""; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const b = await req.json().catch(() => ({}));
    if (b.website) return json(req, 200, { ok: true, ref: "XXXXXXXX" });   // honeypot: pretend it worked
    const message = str(b.message, 3000);
    if (message.length < 3) return json(req, 400, { error: "Tell us what went wrong, even a few words." });
    const email = str(b.contact_email, 200).toLowerCase();
    if (email && !EMAIL_RE.test(email)) return json(req, 400, { error: "That email address doesn't look right. You can leave it blank." });

    const ip = ipOf(req);
    const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const [{ count: mine }, { count: all }] = await Promise.all([
      admin.from("register_log").select("id", { count: "exact", head: true }).eq("kind", "report").eq("ip", ip).gte("at", since),
      admin.from("register_log").select("id", { count: "exact", head: true }).eq("kind", "report").gte("at", since)]);
    if ((mine || 0) >= MAX_PER_IP_HOUR || (all || 0) >= MAX_ALL_HOUR)
      return json(req, 429, { error: "You have sent several reports. Please call or text the office at (262) 236-5443." });
    await admin.from("register_log").insert({ kind: "report", ip, ok: true });

    // Who is it? A signed-in portal session wins; otherwise one tenant with that exact email.
    let tenantId: string | null = null, signedInEmail: string | null = null;
    const token = str(b.access_token, 4000);
    if (token) {
      const { data: u } = await admin.auth.getUser(token);
      signedInEmail = u?.user?.email?.toLowerCase() || null;
    }
    const lookup = signedInEmail || email;
    if (lookup) {
      const { data: ids } = await admin.rpc("resident_tenant_ids", { p_email: lookup });
      const list = (Array.isArray(ids) ? ids : []) as string[];
      if (list.length === 1) tenantId = list[0];
    }

    const errors = (Array.isArray(b.errors) ? b.errors : []).slice(0, 8).map((e: unknown) => str(e, 300));
    const { data: row, error } = await admin.from("issue_reports").insert({
      page_url: cleanUrl(b.page_url), page_title: str(b.page_title, 160), user_agent: str(b.user_agent, 300), viewport: str(b.viewport, 40),
      message, contact_name: str(b.contact_name, 120) || null, contact_email: email || null, contact_phone: str(b.contact_phone, 40) || null,
      tenant_id: tenantId, signed_in_email: signedInEmail, errors,
    }).select("id").single();
    if (error) throw error;

    // Optional photo (the page shrinks it first). Stored privately; staff read it with a signed link.
    const photo = str(b.photo, 6_000_000);
    const m = /^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/=]+)$/.exec(photo);
    if (m) {
      const bytes = Uint8Array.from(atob(m[2]), (c) => c.charCodeAt(0));
      if (bytes.length <= MAX_PHOTO_BYTES) {
        const ext = m[1] === "image/png" ? "png" : m[1] === "image/webp" ? "webp" : "jpg";
        const path = `${row.id}.${ext}`;
        const { error: upErr } = await admin.storage.from("issue-reports").upload(path, bytes, { contentType: m[1], upsert: true });
        if (!upErr) await admin.from("issue_reports").update({ photo_path: path }).eq("id", row.id);
      }
    }

    const ref = String(row.id).slice(0, 8).toUpperCase();
    const who = signedInEmail ? `signed in as ${escapeHtml(signedInEmail)}` : email ? escapeHtml(email) : "no contact given";
    sendEmail({
      to: STAFF_NOTIFY_EMAIL, subject: `Problem report ${ref}: ${message.slice(0, 60).replace(/\s+/g, " ")}`,
      html: `<p><b>${escapeHtml(message.slice(0, 600))}</b></p><p>From: ${who}${b.contact_phone ? " · " + escapeHtml(str(b.contact_phone, 40)) : ""}<br>Page: ${escapeHtml(cleanUrl(b.page_url))}</p>
        <p><a href="https://2ndchinc.org/staff/reports/">Open it and fix it</a> (staff two-step sign-in).</p>`,
    }).catch((e) => console.error("issue-report: staff email failed", e instanceof Error ? e.message : String(e)));
    if (email) {
      sendEmail({ to: email, subject: `We got your report (${ref})`,
        html: `<p>Thank you. We got your report and will fix it as soon as we can. Your reference is <b>${ref}</b>.</p><p>If it's urgent, call or text us at (262) 236-5443.</p><p>2nd Chance Housing</p>` })
        .catch(() => {});
    }
    return json(req, 200, { ok: true, ref });
  } catch (err) {
    console.error("issue-report: error", err instanceof Error ? err.stack || err.message : String(err));
    return json(req, 500, { error: "We couldn't send that report. Please call or text (262) 236-5443." });
  }
});
