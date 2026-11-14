// Quick re-check before sensitive actions (changing an email or phone number): a fresh 6-digit code emailed to the signed-in person.
//   POST { action: "send" }           -> { sent: true }       emails a code to the address they signed in with
//   POST { action: "verify", code }   -> { ok: true }         records the check against THIS sign-in only (valid step_up_minutes)
// The email address always comes from the session, never from the request. See supabase/migrations/*_step_up.sql.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const sha = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))).map((b) => b.toString(16).padStart(2, "0")).join("");
const sessionId = (jwt: string) => { try { return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).session_id as string | undefined; } catch (_) { return undefined; } };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(jwt);
    const user = u?.user, sid = sessionId(jwt);
    if (!user?.email || !sid) return json(req, 401, { error: "Please sign in." });
    const body = await req.json().catch(() => ({}));

    if (body.action === "send") {
      const { count } = await admin.from("step_up_codes").select("id", { count: "exact", head: true }).eq("user_id", user.id).gte("created_at", new Date(Date.now() - 3600_000).toISOString());
      if ((count || 0) >= 5) return json(req, 429, { error: "Too many codes. Please wait an hour, or call or text (262) 236-5443." });
      const code = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0");
      await admin.from("step_up_codes").insert({ user_id: user.id, code_hash: await sha(code + ":" + user.id) });
      await sendEmail({
        to: user.email, subject: `${code} is your 2nd Chance Housing confirmation code`,
        html: `<div style="font-family:Arial,sans-serif;max-width:480px;color:#1b2430"><p>Your confirmation code is:</p><p style="font-size:28px;font-weight:700;letter-spacing:4px">${code}</p><p>It works for 10 minutes. We ask for it before changing your email or phone number. If you did not ask for it, you can ignore this email, and nothing changes.</p></div>`,
      });
      return json(req, 200, { sent: true });
    }

    if (body.action === "verify") {
      const code = String(body.code || "").replace(/\D/g, "");
      const { data: row } = await admin.from("step_up_codes").select("*").eq("user_id", user.id).is("used_at", null).gt("expires_at", new Date().toISOString()).order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (!row || row.attempts >= 5) return json(req, 400, { error: "That code has expired. Send a new one." });
      if (code.length !== 6 || row.code_hash !== await sha(code + ":" + user.id)) {
        await admin.from("step_up_codes").update({ attempts: row.attempts + 1 }).eq("id", row.id);
        return json(req, 400, { error: "That code isn't right. Check the email and try again." });
      }
      await admin.from("step_up_codes").update({ used_at: new Date().toISOString() }).eq("id", row.id);
      await admin.from("session_stepups").upsert({ session_id: sid, user_id: user.id, verified_at: new Date().toISOString() });
      return json(req, 200, { ok: true });
    }
    return json(req, 400, { error: "Unknown action" });
  } catch (e) {
    console.error("step-up", e instanceof Error ? e.message : String(e));
    return json(req, 500, { error: "Couldn't do that right now. Please try again." });
  }
});
