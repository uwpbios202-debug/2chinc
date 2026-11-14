// System costs: "Refresh from Stripe" on https://2ndchinc.org/accounting/costs/ (office staff, authenticator code).
// Reads (never changes) the balance transactions of the three Stripe accounts and stores, per month (Central time) and account,
// how many payments came in, how much was collected and what Stripe charged in fees (system_cost_stripe).
//   POST { action: "refresh" } -> { months }
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { stripe } from "../_shared/stripe.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const START = Math.floor(Date.UTC(2026, 9, 1) / 1000);   // online payments began in October 2026
const monthOf = (unix: number) => new Date(unix * 1000).toLocaleDateString("en-CA", { timeZone: "America/Chicago" }).slice(0, 7) + "-01";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const { error: denied } = await uc.rpc("system_costs_view");   // office staff with the authenticator code, or refused
    if (denied) return json(req, 403, { error: "Office staff only (sign in with your authenticator code)." });

    const rows = new Map<string, { month: string; account: string; payments: number; collected: number; fees: number }>();
    for (const account of ["main", "yawdcour", "roca1"]) {
      let after: string | undefined;
      for (let page = 0; page < 50; page++) {
        const r = await stripe("GET", "balance_transactions", { limit: 100, created: { gte: START }, ...(after ? { starting_after: after } : {}) }, undefined, account);
        for (const t of r.data as { id: string; created: number; type: string; amount: number; fee: number }[]) {
          const k = `${monthOf(t.created)}|${account}`;
          const row = rows.get(k) || { month: monthOf(t.created), account, payments: 0, collected: 0, fees: 0 };
          if (t.type === "charge" || t.type === "payment") { row.payments++; row.collected += t.amount / 100; }
          row.fees += t.fee / 100;
          rows.set(k, row);
        }
        if (!r.has_more || !r.data.length) break;
        after = r.data[r.data.length - 1].id;
      }
    }
    const list = [...rows.values()].map((r) => ({ ...r, collected: Math.round(r.collected * 100) / 100, fees: Math.round(r.fees * 100) / 100, refreshed_at: new Date().toISOString() }));
    if (list.length) { const { error } = await admin.from("system_cost_stripe").upsert(list, { onConflict: "month,account" }); if (error) throw error; }
    return json(req, 200, { months: list.length });
  } catch (e) {
    console.error("system-costs:", e instanceof Error ? e.message : String(e));
    return json(req, 500, { error: "Couldn't read Stripe right now. Try again in a minute." });
  }
});
