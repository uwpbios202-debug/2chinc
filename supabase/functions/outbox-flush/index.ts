// Sends queued emails (email_outbox) right away after a signed-in staff member
// or resident does something that queues mail in the database: keys handed
// over (Move-In + Online Payments letters), move-in checklist sent or reviewed.
// Only sends what is already queued. Also sends queued phone alerts (push_outbox).
//   POST {}  (JWT in Authorization) -> { sent }
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { flushOutbox } from "../_shared/mail.ts";
import { flushPush } from "../_shared/push.ts";

const CYCLE_SECRET = Deno.env.get("RENT_CYCLE_SECRET") || "";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  // The repair-heat-escalate job (pg_cron) calls with x-cycle-secret instead of a signed-in user.
  const viaCron = !!CYCLE_SECRET && req.headers.get("x-cycle-secret") === CYCLE_SECRET;
  if (!viaCron) {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(jwt);
    if (!u?.user?.email) return json(req, 401, { error: "Sign in first." });
  }
  try {
    // Phone alerts first (a parking alert is urgent), then the emails. A push failure never stops the emails.
    const pushed = await flushPush(admin).catch((e) => { console.error("push", e); return 0; });
    return json(req, 200, { sent: await flushOutbox(admin, 100), pushed });
  } catch (e) {
    console.error(e);
    return json(req, 500, { error: "Couldn't send right now; the daily run will send it." });
  }
});
