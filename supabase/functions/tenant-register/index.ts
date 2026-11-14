// Tenant registration, before sign-in (2ndchinc.org/register). Public endpoint: verify_jwt is off.
// A tenant whose email on file is out of date cannot get a sign-in code, so they prove who they are with the
// registration code on the notice staff hand them plus their last name, then fix their phone and email.
//
// POST { action: "check", code, last_name }            -> { token, name, email_hint, phone }
// POST { action: "save_phone", token, phone }          -> { ok }
// POST { action: "send_email_code", token, email }     -> { sent } | { same: true }   (the code goes to the NEW address)
// POST { action: "confirm_email", token, email, code } -> { ok }                      (changes the email at once)
// POST { action: "finish", token }                     -> { ok }
//
// Protection: the registration code is stored as a hash; wrong tries are counted per code and per address and
// lock the code (staff issue a new one); sessions last 30 minutes; the new email must receive a code before it
// replaces the old one; the old address is told. Nothing personal is logged.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml, SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

const MAX_CODE_TRIES = 8;          // wrong tries per registration code, then staff must issue a new one
const MAX_TRIES_PER_IP_HOUR = 12;  // wrong tries from one address per hour
const MAX_TRIES_ALL_HOUR = 150;
const MAX_EMAIL_CODES_PER_HOUR = 4;
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const str = (v: unknown, max = 200) => String(v ?? "").trim().slice(0, max);

async function sha256(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function randomToken() {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const ipOf = (req: Request) => (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "unknown";
const cleanPhone = (v: unknown) => { const d = String(v || "").replace(/\D/g, "").replace(/^1(?=\d{10}$)/, ""); return d.length === 10 ? `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` : ""; };
const hintEmail = (e: string | null) => { if (!e || !e.includes("@")) return ""; const [u, d] = e.split("@"); return (u.length <= 2 ? u[0] + "*" : u.slice(0, 2) + "***") + "@" + d; };
const norm = (s: string) => s.toLowerCase().replace(/[^a-z]/g, "");

// The last name must match a word of the name on file other than the first (or the only word).
function lastNameMatches(fullName: string, given: string) {
  const g = norm(given); if (g.length < 2) return false;
  const words = fullName.trim().split(/\s+/).map(norm).filter(Boolean);
  const candidates = words.length > 1 ? words.slice(1) : words;
  return candidates.includes(g);
}

async function sessionFor(token: unknown) {
  if (typeof token !== "string" || token.length < 30) return null;
  const { data } = await admin.from("register_sessions").select("id, tenant_id, expires_at").eq("token_hash", await sha256(token)).maybeSingle();
  if (!data || new Date(data.expires_at) < new Date()) return null;
  const { data: t } = await admin.from("tenants").select("id, name, email, phone").eq("id", data.tenant_id).maybeSingle();
  return t ? { session: data.id as string, tenant: t as { id: string; name: string; email: string | null; phone: string | null } } : null;
}

async function logAttempt(kind: string, ip: string, tenantId: string | null, ok: boolean) {
  await admin.from("register_log").insert({ kind, ip, tenant_id: tenantId, ok });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const body = await req.json().catch(() => ({}));
    const action = body.action;
    const ip = ipOf(req);
    const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();

    if (action === "check") {
      const [{ count: mine }, { count: all }] = await Promise.all([
        admin.from("register_log").select("id", { count: "exact", head: true }).eq("kind", "code_try").eq("ok", false).eq("ip", ip).gte("at", since),
        admin.from("register_log").select("id", { count: "exact", head: true }).eq("kind", "code_try").eq("ok", false).gte("at", since)]);
      if ((mine || 0) >= MAX_TRIES_PER_IP_HOUR || (all || 0) >= MAX_TRIES_ALL_HOUR)
        return json(req, 429, { error: "Too many tries. Please wait an hour, or call or text the office and we will help you right away." });
      const code = str(body.code, 40).toUpperCase().replace(/[^A-Z0-9]/g, "");
      const last = str(body.last_name, 60);
      if (code.length !== 8 || last.length < 2) return json(req, 400, { error: "Enter the 8-character code from your notice and your last name." });
      const { data: row } = await admin.from("tenant_reg_codes").select("tenant_id, failed_tries").eq("code_hash", await sha256(code)).maybeSingle();
      const bad = async (tenantId: string | null) => { await logAttempt("code_try", ip, tenantId, false); return json(req, 400, { error: "That code and last name don't match. Check the code on your notice." }); };
      if (!row) return await bad(null);
      if (row.failed_tries >= MAX_CODE_TRIES) return json(req, 423, { error: "This code is locked after too many tries. Call or text the office and we will give you a new one." });
      const { data: t } = await admin.from("tenants").select("id, name, email, phone").eq("id", row.tenant_id).maybeSingle();
      if (!t || !lastNameMatches(t.name, last)) {
        await admin.from("tenant_reg_codes").update({ failed_tries: row.failed_tries + 1 }).eq("tenant_id", row.tenant_id);
        return await bad(row.tenant_id);
      }
      await admin.from("tenant_reg_codes").update({ failed_tries: 0 }).eq("tenant_id", row.tenant_id);
      await logAttempt("code_try", ip, row.tenant_id, true);
      const token = randomToken();
      const { error } = await admin.from("register_sessions").insert({ token_hash: await sha256(token), tenant_id: row.tenant_id });
      if (error) throw error;
      return json(req, 200, { token, first_name: t.name.trim().split(/\s+/)[0].replace(/^./, (c: string) => c.toUpperCase()), email_hint: hintEmail(t.email), phone: t.phone || "" });
    }

    const s = await sessionFor(body.token);
    if (!s) return json(req, 401, { error: "This page timed out. Start again with the code on your notice." });

    if (action === "save_phone") {
      const phone = cleanPhone(body.phone);
      if (!phone) return json(req, 400, { error: "Enter a 10-digit phone number." });
      if (phone !== s.tenant.phone) {
        await admin.from("tenant_contact_changes").insert({ requested_by: "registration code", field: "phone", old_value: s.tenant.phone, new_value: phone, status: "applied", decided_by: "registration", decided_at: new Date().toISOString(), note: "Changed by the tenant before signing in" });
        const { error } = await admin.from("tenants").update({ phone }).eq("id", s.tenant.id);
        if (error) throw error;
      }
      return json(req, 200, { ok: true, phone });
    }

    if (action === "send_email_code") {
      const email = str(body.email, 200).toLowerCase();
      if (!EMAIL_RE.test(email)) return json(req, 400, { error: "Enter a full email address, like name@gmail.com." });
      if (email === (s.tenant.email || "").toLowerCase()) return json(req, 200, { same: true });
      const { count } = await admin.from("register_email_codes").select("id", { count: "exact", head: true }).eq("tenant_id", s.tenant.id).gte("created_at", since);
      if ((count || 0) >= MAX_EMAIL_CODES_PER_HOUR) return json(req, 429, { error: "Too many codes. Wait an hour, or call or text the office and we will help you right away." });
      const code = String(100000 + (crypto.getRandomValues(new Uint32Array(1))[0] % 900000));
      const { error } = await admin.from("register_email_codes").insert({ tenant_id: s.tenant.id, new_email: email, code_hash: await sha256(email + ":" + code) });
      if (error) throw error;
      await sendEmail({
        to: email, subject: `${code} is your 2nd Chance Housing code`,
        html: `<div style="font-family:Arial,sans-serif;max-width:520px;color:#1b2430"><p>Your code to confirm this email address is:</p>
          <p style="font-size:30px;letter-spacing:6px;font-weight:700;margin:12px 0">${code}</p>
          <p>Type it on the registration page. It expires in 10 minutes and works once.</p>
          <p style="color:#5b6573;font-size:13px">If you didn't ask for this, you can ignore this email.</p></div>`,
      }).catch((e) => { console.error("tenant-register: code email failed", e instanceof Error ? e.message : String(e)); throw new Error("send"); });
      return json(req, 200, { sent: true });
    }

    if (action === "confirm_email") {
      const email = str(body.email, 200).toLowerCase();
      const code = String(body.code || "").replace(/\D/g, "");
      if (!EMAIL_RE.test(email) || code.length !== 6) return json(req, 400, { error: "Enter the 6-digit code from the email." });
      const { data: row } = await admin.from("register_email_codes").select("*").eq("tenant_id", s.tenant.id).eq("new_email", email).is("used_at", null)
        .gt("expires_at", new Date().toISOString()).order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (!row) return json(req, 400, { error: "That code expired. Send a new one." });
      if (row.attempts >= 5) return json(req, 400, { error: "Too many wrong tries. Send a new code." });
      if (row.code_hash !== await sha256(email + ":" + code)) {
        await admin.from("register_email_codes").update({ attempts: row.attempts + 1 }).eq("id", row.id);
        return json(req, 400, { error: "That code didn't match." });
      }
      await admin.from("register_email_codes").update({ used_at: new Date().toISOString() }).eq("id", row.id);
      const old = s.tenant.email;
      const { error: upErr } = await admin.from("tenants").update({ email }).eq("id", s.tenant.id);
      if (upErr) {
        if (/duplicate|unique/i.test(upErr.message)) return json(req, 409, { error: "That email is already on file for this name. Call or text the office and we will fix it." });
        throw upErr;
      }
      await admin.from("tenant_contact_changes").insert({ requested_by: "registration code", field: "email", old_value: old, new_value: email, status: "applied", decided_by: "registration", decided_at: new Date().toISOString(), note: "Changed by the tenant before signing in (confirmed by a code sent to the new address)" });
      await admin.from("tenant_reg_codes").update({ used_at: new Date().toISOString() }).eq("tenant_id", s.tenant.id);
      // Tell the old address (it may be dead; that is fine) and the office.
      if (old && old.toLowerCase() !== email) {
        sendEmail({ to: old, subject: "Your 2nd Chance Housing sign-in email was changed",
          html: `<p>The email for your 2nd Chance Housing resident account was changed to ${escapeHtml(hintEmail(email))}.</p><p>If this was not you, call or text us right away at (262) 236-5443.</p>` }).catch(() => {});
      }
      sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "A tenant registered and changed their email",
        html: `<p>${escapeHtml(s.tenant.name)} registered with their notice code and changed their sign-in email (confirmed by a code sent to the new address).</p>` }).catch(() => {});
      return json(req, 200, { ok: true });
    }

    if (action === "finish") {
      await admin.from("tenant_reg_codes").update({ used_at: new Date().toISOString() }).eq("tenant_id", s.tenant.id);
      return json(req, 200, { ok: true });
    }

    return json(req, 400, { error: "Unknown request." });
  } catch (err) {
    if (err instanceof Error && err.message === "send") return json(req, 502, { error: "We couldn't send that email. Check the address and try again." });
    console.error("tenant-register: error", err instanceof Error ? err.stack || err.message : String(err));
    return json(req, 500, { error: "Something went wrong on our side. Please use the Report a problem button, or call or text the office." });
  }
});
