// Staff button on https://2ndchinc.org/staff/caseworkers/: emails a caseworker the signed lease and ROCA1's W-9 as attachments (no sign-in).
//   POST { caseworker_id } (staff JWT in Authorization) -> { sent: n, lease_count }   one email per client lease that has a signed lease on file
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { sendCaseworkerPacket } from "../_shared/caseworker-packet.ts";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

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
    const { data: cw } = await admin.from("caseworkers").select("id, name, email, active").eq("id", String(body.caseworker_id || "")).maybeSingle();
    if (!cw || !cw.active) return json(req, 404, { error: "That caseworker is not active." });

    // Every current or upcoming lease of this caseworker's clients, once each.
    const { data: rows } = await admin.from("caseworker_clients").select("tenant_id").eq("caseworker_id", cw.id);
    const tenantIds = (rows || []).map((r: any) => r.tenant_id);
    const { data: lts } = tenantIds.length ? await admin.from("lease_tenants").select("lease_id, leases!inner(status)").in("tenant_id", tenantIds).in("leases.status", ["active", "future"]) : { data: [] };
    const leaseIds = [...new Set((lts || []).map((r: any) => r.lease_id))] as string[];
    if (!leaseIds.length) return json(req, 404, { error: "This caseworker has no client with a current or upcoming lease." });

    let sent = 0; const problems: string[] = [];
    for (const id of leaseIds) {
      try { await sendCaseworkerPacket(admin, cw, id); sent++; }
      catch (e) { problems.push(e instanceof Error ? e.message : String(e)); }
    }
    if (!sent) return json(req, 409, { error: problems[0] || "Nothing was sent." });
    return json(req, 200, { sent, lease_count: leaseIds.length, problems });
  } catch (e) {
    console.error("caseworker-packet:", e instanceof Error ? e.message : String(e));
    return json(req, 500, { error: "Could not send the documents." });
  }
});
