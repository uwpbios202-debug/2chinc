// Admin "View as": lets the admin (portal_admins, signed in WITH the authenticator code) open the real
// portal as any tenant, owner or staff member, to see exactly what that person sees.
//
//   POST { action: "start", email }         (admin JWT)        -> { token_hash, path }
//   POST { action: "bind" }                 (the NEW session)  -> { ok: true }
//
// start: checks the caller is an admin, that the email is on file and is not another admin, mints a
//        one-time sign-in token (no email is sent) and writes a view_as_grants row (also the audit log).
// bind:  called by the view-as page right after it signs in with that token; ties the grant to that one
//        session id, which is what lets the session skip the target's own authenticator step (see
//        mfa_aal_ok in 20261109000000_login_profiles_admin_view_as.sql).
// The admin's own session is never replaced: the view-as page keeps its session in that browser tab only.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

function claims(jwt: string): Record<string, unknown> {
  try { return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))); } catch { return {}; }
}

// Where each kind of person lands (the portal pages sign in by role).
async function landingPath(admin: ReturnType<typeof createClient>, email: string) {
  const { data: who } = await admin.rpc("admin_role_for_email", { p_email: email });
  return who === "owner" ? "/association-owners/roca1/" : who === "resident" ? "/resident/" : who === "seller" ? "/seller/" : who === "navigator" ? "/navigator/" : "/staff/";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const { data: u } = await uc.auth.getUser(jwt);   // verifies the token with Supabase Auth
    const me = u?.user;
    if (!me?.email) return json(req, 401, { error: "Please sign in." });
    const c = claims(jwt);
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const body = await req.json().catch(() => ({}));

    if (body.action === "bind") {
      // The caller is the new (view-as) session: find the fresh, unbound grant for this user.
      const sid = String(c.session_id || "");
      if (!sid) return json(req, 400, { error: "No session." });
      const { data: g } = await admin.from("view_as_grants").select("id")
        .eq("target_user_id", me.id).is("session_id", null).gt("created_at", new Date(Date.now() - 2 * 60_000).toISOString())
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (!g) return json(req, 403, { error: "No view-as request is waiting." });
      const { error } = await admin.from("view_as_grants").update({ session_id: sid, bound_at: new Date().toISOString() }).eq("id", g.id).is("session_id", null);
      if (error) throw error;
      return json(req, 200, { ok: true });
    }

    if (body.action !== "start") return json(req, 400, { error: "Unknown action." });

    // Admin only, and only with the authenticator code entered (aal2).
    const { data: isAdmin } = await uc.rpc("portal_is_admin");
    if (isAdmin !== true) return json(req, 403, { error: "Admins only (sign in with your authenticator code)." });

    const target = String(body.email || "").trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(target)) return json(req, 400, { error: "Choose a person." });
    const { data: onFile } = await admin.rpc("condo_email_on_file", { p_email: target });
    if (onFile !== true) return json(req, 404, { error: "That email isn't on file." });
    const { data: targetIsAdmin } = await admin.from("portal_admins").select("email").ilike("email", target).maybeSingle();
    if (targetIsAdmin) return json(req, 400, { error: "That's an admin login; you're already seeing everything it sees." });

    const { data: link, error: lerr } = await admin.auth.admin.generateLink({ type: "magiclink", email: target });
    if (lerr || !link?.properties?.hashed_token || !link.user?.id) throw lerr || new Error("no link");
    const { error: gerr } = await admin.from("view_as_grants").insert({ admin_email: me.email, target_email: target, target_user_id: link.user.id });
    if (gerr) throw gerr;
    return json(req, 200, { token_hash: link.properties.hashed_token, path: await landingPath(admin, target) });
  } catch (err) {
    console.error("admin-view-as:", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "Couldn't open that view. Try again." });
  }
});
