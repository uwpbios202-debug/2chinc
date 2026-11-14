// Caseworker portal (caseworker signed in with an emailed code; JWT in Authorization). A caseworker sees only their own clients' leases.
//   POST { action: "lease_pdf", lease_id }          -> { url }   a 5-minute link to the signed lease PDF
//   POST { action: "w9" }                            -> { pdf }   ROCA1's W-9 (base64), signed with the agent's signature on file, dated today
//   POST { action: "checkout", lease_id, amount? }   -> { url }   Stripe Checkout (bank account only) paying ROCA1, the account the lease names
// Caseworkers pay ONLY to what the lease names (ROCA1). The agency's amount is never fixed: any amount, any month.
// The tenant's own payments are not touched by any of this. The stripe-webhook posts the payment once Stripe confirms it.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, PORTAL_BASE_URL, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { buildRoca1W9 } from "../_shared/caseworker-packet.ts";
import { stripe } from "../_shared/stripe.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const BUCKET = "lease-signing";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const page = (hash: string) => new URL("/caseworker/", PORTAL_BASE_URL).toString() + hash;
const setting = async (key: string) => (await admin.from("portal_settings").select("value").eq("key", key).maybeSingle()).data?.value || "";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const body = await req.json().catch(() => ({}));
    const action = String(body.action || "");

    // Everything below needs a signed-in caseworker (the database checks the session and the email on file).
    const { error: infoErr } = await uc.rpc("caseworker_pay_info");
    if (infoErr) return json(req, 403, { error: "Please sign in as a caseworker." });

    if (action === "w9") {
      const bytes = await buildRoca1W9(admin);
      if (!bytes) return json(req, 503, { error: "The W-9 isn't ready yet. Please call or text (262) 236-5443." });
      let bin = ""; for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      return json(req, 200, { pdf: btoa(bin), filename: "ROCA1 W-9.pdf" });
    }

    // The rest are about one lease; the database confirms it is one of this caseworker's clients.
    const leaseId = String(body.lease_id || "");
    const { data: own, error: ownErr } = await uc.rpc("caseworker_owns_lease", { p_lease: leaseId });
    if (ownErr || !own) return json(req, 403, { error: "That lease isn't one of your clients." });

    if (action === "lease_pdf") {
      const { data: l } = await admin.from("leases").select("signing_doc_id").eq("id", leaseId).single();
      const { data: d } = l?.signing_doc_id ? await admin.from("lease_signing_docs").select("executed_pdf_path").eq("id", l.signing_doc_id).single() : { data: null };
      if (!d?.executed_pdf_path) return json(req, 404, { error: "The signed lease isn't on file yet. Please call or text (262) 236-5443." });
      const { data: u, error } = await admin.storage.from(BUCKET).createSignedUrl(d.executed_pdf_path, 300);
      if (error || !u) throw error || new Error("no link");
      return json(req, 200, { url: u.signedUrl });
    }

    if (action === "checkout") {
      if ((await setting("stripe_enabled")) !== "on" || (await setting("stripe_enabled_roca1")) !== "on") return json(req, 403, { error: "Paying online isn't available right now. Please use the bank transfer details or mail a check." });
      const pmc = await setting("stripe_pmc_roca1");
      if (!pmc) return json(req, 503, { error: "Paying online isn't set up yet. Please use the bank transfer details or mail a check." });
      const { data: lease } = await admin.from("leases").select("id, rent, rental_units!inner(address)").eq("id", leaseId).single();
      const { data: cw } = await admin.from("caseworkers").select("id, name, agency, email").eq("id", own.caseworker_id).single();
      const { data: due } = await admin.rpc("lease_rent_due", { p_lease: leaseId, p_as_of: new Date().toISOString().slice(0, 10) });
      const amount = Math.round((Number(body.amount) > 0 ? Number(body.amount) : Number(due) || Number((lease as any).rent) || 0) * 100) / 100;
      if (!(amount >= 1 && amount <= 20000)) return json(req, 400, { error: "Enter an amount between $1 and $20,000." });
      const label = `Rent — ${(lease as any).rental_units.address} (paid by ${cw?.agency || "agency"})`;
      const { data: row, error } = await admin.from("stripe_payments").insert({ tenant_id: own.tenant_id, lease_id: leaseId, amount, origin: "caseworker", caseworker_id: own.caseworker_id }).select("id").single();
      if (error) throw error;
      try {
        const s = await stripe("POST", "checkout/sessions", {
          mode: "payment", client_reference_id: row.id, customer_email: cw?.email, payment_method_configuration: pmc,
          payment_method_options: { us_bank_account: { verification_method: "automatic" } },
          line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: Math.round(amount * 100), product_data: { name: label } } }],
          payment_intent_data: { description: label, metadata: { stripe_payment_id: row.id, tenant_id: String(own.tenant_id), lease_id: leaseId, caseworker_id: String(own.caseworker_id), association: "ROCA1" } },
          success_url: page("?paid=1"), cancel_url: page(""),
        }, `checkout-${row.id}`, "roca1");
        await admin.from("stripe_payments").update({ checkout_session: s.id }).eq("id", row.id);
        return json(req, 200, { url: s.url });
      } catch (e) { await admin.from("stripe_payments").delete().eq("id", row.id); throw e; }   // no stale "started" attempt
    }
    return json(req, 400, { error: "Unknown action." });
  } catch (e) {
    console.error("caseworker-portal:", e instanceof Error ? e.message : String(e));
    return json(req, 500, { error: "Something went wrong. Please call or text (262) 236-5443." });
  }
});
