// Resident portal → Stripe (resident two-step signed in; JWT in Authorization).
//   POST { action: "checkout", amount? }  -> { url }  Stripe Checkout: bank account only (no cards, Stephen 10/8/2026), no fee to the tenant
//   POST { action: "autopay_setup" }       -> { url }  save a bank account for automatic rent on the 1st
//   POST { action: "autopay_cancel" }      -> { ok }
//   POST { action: "owner_checkout", unit_number, amount? } -> { url }  owner pays association dues (bank only)
//   POST { action: "staff_dues_checkout", unit_number, amount } -> { url }  staff pay dues on a 2nd Chance-owned unit (max one year per payment)
// Stripe collects all bank and card details; the stripe-webhook function
// posts the payment once Stripe confirms it.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, PORTAL_BASE_URL, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { stripe } from "../_shared/stripe.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const portal = (hash: string) => new URL("/resident/", PORTAL_BASE_URL).toString() + hash;
const ownerPortal = (hash: string) => new URL("/association-owners/roca1/", PORTAL_BASE_URL).toString() + hash;
const staffDuesPage = (q: string) => new URL("/staff/dues-pay/", PORTAL_BASE_URL).toString() + q;

// No double payments (11/5/2026: a tenant paid $825 rent three times in one evening because the balance still showed $825 while the
// first bank payment was clearing, and a bank debit cannot be cancelled once it is processing). Before a new checkout:
//  - money already on its way (status processing) counts against what is owed; nothing left owed means no new payment;
//  - any other checkout still open for the same lease / account is expired, so a second tab or device cannot complete it too.
type Col = "lease_id" | "land_contract_id" | "condo_account_id";
const fmtDay = (iso: string) => new Date(iso).toLocaleDateString("en-US", { timeZone: "America/Chicago" });
const usd = (n: number) => "$" + n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
async function onTheWay(col: Col, id: string) {
  const { data } = await admin.from("stripe_payments").select("amount, created_at").eq(col, id).eq("status", "processing").order("created_at");
  const rows = (data || []) as { amount: number; created_at: string }[];
  return { sum: Math.round(rows.reduce((t, r) => t + Number(r.amount), 0) * 100) / 100, rows };
}
function clearingRefusal(way: { sum: number; rows: { amount: number; created_at: string }[] }, owed: number, amount: number): string | null {
  if (!(way.sum > 0)) return null;
  const list = way.rows.map((r) => `${usd(Number(r.amount))} from ${fmtDay(r.created_at)}`).join(" and ");
  const left = Math.round((owed - way.sum) * 100) / 100;
  if (left <= 0) return `Your payment of ${list} is on its way from your bank (bank payments take a few business days). You do not need to pay again.`;
  if (amount > left) return `You already have ${list} on its way from your bank. The most you can pay now is ${usd(left)}.`;
  return null;
}
async function expireOpenCheckouts(col: Col, id: string, call: (m: "GET" | "POST", p: string) => Promise<unknown>) {
  const { data } = await admin.from("stripe_payments").select("id, checkout_session").eq(col, id).eq("status", "created").not("checkout_session", "is", null);
  for (const r of (data || []) as { id: string; checkout_session: string }[]) {
    try { await call("POST", `checkout/sessions/${r.checkout_session}/expire`); await admin.from("stripe_payments").update({ status: "canceled", updated_at: new Date().toISOString() }).eq("id", r.id).eq("status", "created"); }
    catch (e) { console.error("stripe-pay: could not expire an older checkout:", (e as Error).message); }   // already completed or expired: the webhook settles it
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const body0 = await req.clone().json().catch(() => ({}));
    // Stripe is offered only once it is live (setting stripe_enabled), and owners can't pay through 2nd Chance's
    // Stripe account: "Tenants pay 2nd Chance and Owners pay ROCA1" (owner_pay_stripe stays off until ROCA1 has its own).
    const { data: st } = await admin.from("portal_settings").select("key, value").in("key", ["stripe_enabled", "owner_pay_stripe", "stripe_enabled_roca1", "tenant_cards"]);
    const setting = (k: string) => (st || []).find((x: { key: string }) => x.key === k)?.value || "off";
    // Staff paying ROCA1 dues on a unit 2nd Chance Housing Inc owns (admin: all of them; staff: their assigned ones). Owner money only:
    // staff never take or start a tenant's payment (Stephen, 11/3/2026). It runs the owner checkout below with the company as the owner.
    const staffPay = body0.action === "staff_dues_checkout";
    if (staffPay) body0.action = "owner_checkout";
    if (body0.action !== "autopay_cancel" && body0.action !== "owner_checkout" && setting("stripe_enabled") !== "on") return json(req, 403, { error: "Online card and bank payments aren't available yet. Please use one of the other ways to pay." });
    if (body0.action === "owner_checkout" && (setting("owner_pay_stripe") !== "on" || setting("stripe_enabled_roca1") !== "on")) return json(req, 403, { error: "Association dues are paid to ROCA1: Zelle to ROCA1 or a bank transfer to ROCA1's First Citizens account. 2nd Chance's online payments are for rent only." });

    // Association dues: the signed-in owner pays one of their units (ROCA1's money).
    if (body0.action === "owner_checkout") {
      const { data: tgt, error: terr } = await uc.rpc(staffPay ? "staff_dues_pay_target" : "condo_pay_target", { p_unit: String(body0.unit_number || "") });
      if (terr || !tgt) return json(req, 403, { error: terr?.message || (staffPay ? "Please sign in as staff." : "Please sign in as an owner.") });
      const ownerId: string = tgt.owner_id;
      // Association dues go through ROCA1's own Stripe account (paying out to ROCA1's First Citizens account), never 2nd Chance's.
      const ro = (m: "GET" | "POST", p: string, params: Record<string, unknown> = {}, idem?: string) => stripe(m, p, params, idem, "roca1");
      let { data: oc } = await admin.from("stripe_owner_customers").select("*").eq("owner_id", ownerId).maybeSingle();
      if (oc && (oc.stripe_account || "main") !== "roca1") {
        const c = await ro("POST", "customers", { name: tgt.name, email: tgt.email, metadata: { owner_id: ownerId, association: "ROCA1" } }, `owner-customer-${ownerId}-roca1`);
        const { data } = await admin.from("stripe_owner_customers").update({ customer_id: c.id, stripe_account: "roca1" }).eq("owner_id", ownerId).select("*").single();
        oc = data;
      }
      if (!oc) {
        const c = await ro("POST", "customers", { name: tgt.name, email: tgt.email, metadata: { owner_id: ownerId, association: "ROCA1" } }, `owner-customer-${ownerId}-roca1`);
        const { data } = await admin.from("stripe_owner_customers").insert({ owner_id: ownerId, customer_id: c.id, stripe_account: "roca1" }).select("*").single();
        oc = data;
      }
      const due = Number(tgt.balance) > 0 ? Number(tgt.balance) : Number(tgt.dues);
      const amount = Math.round((Number(body0.amount) > 0 ? Number(body0.amount) : due) * 100) / 100;
      // Staff payments: at most one year of dues per payment (12 x monthly dues, $2,580 at $215); another year can be paid with a further payment.
      const maxAmt = staffPay ? Number(tgt.max) : 20000;
      if (!(amount >= 1 && amount <= maxAmt)) return json(req, 400, { error: `Enter an amount between $1 and $${maxAmt.toLocaleString("en-US", { minimumFractionDigits: maxAmt % 1 ? 2 : 0 })}${staffPay ? " (one year of dues per payment; pay another year with a second payment)" : ""}.` });
      const label = `ROCA1 association dues, Unit ${tgt.unit_number}`;
      // Dues already clearing count against the balance. Staff may pay a year ahead, so for them only the same amount twice is refused.
      const way = await onTheWay("condo_account_id", tgt.account_id);
      const refuse = staffPay
        ? (way.rows.some((r) => Number(r.amount) === amount) ? `A payment of ${usd(amount)} for this unit is already on its way from the bank (started ${fmtDay(way.rows.find((r) => Number(r.amount) === amount)!.created_at)}). Wait for it to clear before paying the same amount again.` : null)
        : clearingRefusal(way, Math.max(Number(tgt.balance), 0), amount);
      if (refuse) return json(req, 409, { error: refuse });
      await expireOpenCheckouts("condo_account_id", tgt.account_id, (m, p) => ro(m, p, {}));
      const { data: row, error } = await admin.from("stripe_payments").insert({ owner_id: ownerId, condo_account_id: tgt.account_id, amount, origin: "pay_now", started_by: staffPay ? tgt.paid_by : null }).select("id").single();
      if (error) throw error;
      // ROCA1's Stripe account takes payment methods from a bank-only payment method configuration (stripe_pmc_roca1), not payment_method_types.
      const pmcRoca1 = (await admin.from("portal_settings").select("value").eq("key", "stripe_pmc_roca1").maybeSingle()).data?.value;
      if (!pmcRoca1) return json(req, 503, { error: "Online payment isn't set up yet. Please pay by Zelle, or call or text (262) 236-5443." });
      const sessionParams = {
        mode: "payment", customer: oc.customer_id, client_reference_id: row.id,
        payment_method_configuration: pmcRoca1,   // owners: bank account only (no card, Apple Pay, Link or Klarna; ACH costs far less)
        payment_method_options: { us_bank_account: { verification_method: "automatic" } },
        line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: Math.round(amount * 100), product_data: { name: label } } }],
        payment_intent_data: { description: label, metadata: { stripe_payment_id: row.id, owner_id: ownerId, association: "ROCA1", unit: String(tgt.unit_number), ...(staffPay ? { started_by: tgt.paid_by } : {}) } },
        success_url: staffPay ? staffDuesPage("?paid=1") : ownerPortal("?paid=1#payments"), cancel_url: staffPay ? staffDuesPage("") : ownerPortal("#payments"),
      };
      // The owner may tick "save my bank account"; their next dues payment then offers the saved account (no bank sign-in, no codes).
      // Only the owner, present at Checkout, can pay from it: nothing here lets staff or us charge a saved account.
      let s;
      try {
        s = await ro("POST", "checkout/sessions", { ...sessionParams, saved_payment_method_options: { payment_method_save: "enabled" } }, `checkout-${row.id}`);
      } catch (e) {
        // If Stripe refuses the save option, the owner can still pay: retry without it (new idempotency key, the parameters differ).
        if (!(e as { status?: number }).status || (e as { status: number }).status >= 500 || !/saved_payment_method/i.test(String((e as Error).message))) throw e;
        console.error("stripe-pay: owner checkout without the save option:", (e as Error).message);
        s = await ro("POST", "checkout/sessions", sessionParams, `checkout-${row.id}-nosave`);
      }
      await admin.from("stripe_payments").update({ checkout_session: s.id }).eq("id", row.id);
      return json(req, 200, { url: s.url });
    }

    const { data: ids } = await uc.rpc("resident_me");
    const tenantId: string | undefined = (ids || []).map((x: unknown) => (typeof x === "string" ? x : Object.values(x as Record<string, string>)[0]))[0];
    if (!tenantId) return json(req, 403, { error: "Please sign in." });
    const { data: t } = await admin.from("tenants").select("id, name, email").eq("id", tenantId).single();
    const body = await req.json().catch(() => ({}));

    // Which Stripe account takes this tenant's rent. A lease's bank account (leases.pay_to_account_id) may belong to another
    // entity: Yawdcour LLC has its own Stripe account paying out to its own Chase account. A lease routed to a bank account with
    // no Stripe account (ROCA1) pays by Zelle or bank transfer only, and an account's online payment stays off until its
    // setting stripe_enabled_<account> is on.
    let acct = "main";
    if (body.action === "checkout" || body.action === "autopay_setup") {
      const { data: routed } = await admin.from("lease_tenants").select("leases!inner(pay_to_account_id, status)").eq("tenant_id", tenantId)
        .in("leases.status", ["active", "future"]).not("leases.pay_to_account_id", "is", null).limit(1);
      if ((routed || []).length) {
        const { data: ba } = await admin.from("bank_accounts").select("stripe_account").eq("id", (routed as any)[0].leases.pay_to_account_id).maybeSingle();
        acct = ba?.stripe_account || "";
        const on = acct ? (await admin.from("portal_settings").select("value").eq("key", `stripe_enabled_${acct}`).maybeSingle()).data?.value === "on" : false;
        if (!acct || !on) return json(req, 403, { error: "Your rent is paid by Zelle or bank transfer to a specific account. Open Payments to see where to send it, or call or text (262) 236-5443." });
      }
    }
    const sp = (m: "GET" | "POST", p: string, params: Record<string, unknown> = {}, idem?: string) => stripe(m, p, params, idem, acct);
    // Newer Stripe accounts (Yawdcour) no longer accept payment_method_types on Checkout: they use a payment method configuration
    // (bank account only) named in portal_settings stripe_pmc_<account>. The 2nd Chance account keeps payment_method_types.
    let methods: Record<string, unknown> = { payment_method_types: ["us_bank_account"] };   // no cards (Stephen, 10/8/2026)
    if (acct !== "main") {
      const pmc = (await admin.from("portal_settings").select("value").eq("key", `stripe_pmc_${acct}`).maybeSingle()).data?.value;
      if (!pmc) return json(req, 503, { error: "Online payment isn't set up for your unit yet. Please pay by Zelle, or call or text (262) 236-5443." });
      methods = { payment_method_configuration: pmc };
    }

    // The resident's Stripe customer (created once).
    let { data: cust } = await admin.from("stripe_customers").select("*").eq("tenant_id", tenantId).maybeSingle();
    if (cust && body.action !== "autopay_cancel" && (cust.stripe_account || "main") !== acct) {
      // This tenant's rent now goes through a different Stripe account: make a customer there (autopay must be set up again).
      const c = await sp("POST", "customers", { name: t.name, email: t.email, metadata: { tenant_id: tenantId } }, `customer-${tenantId}-${acct}`);
      const { data } = await admin.from("stripe_customers").update({ customer_id: c.id, stripe_account: acct, updated_at: new Date().toISOString() }).eq("tenant_id", tenantId).select("*").single();
      cust = data;
    }
    if (!cust && body.action !== "autopay_cancel") {
      const c = await sp("POST", "customers", { name: t.name, email: t.email, metadata: { tenant_id: tenantId } }, acct === "main" ? `customer-${tenantId}` : `customer-${tenantId}-${acct}`);
      const { data } = await admin.from("stripe_customers").insert({ tenant_id: tenantId, customer_id: c.id, stripe_account: acct }).select("*").single();
      cust = data;
    }

    if (body.action === "checkout") {
      const { data: lease } = await admin.from("lease_tenants").select("leases!inner(id, status, rent, start_date, move_in_charges_posted, keys_ready_at, rental_units!inner(address))").eq("tenant_id", tenantId).in("leases.status", ["active", "future"]).order("start_date", { referencedTable: "leases", ascending: false }).limit(1).maybeSingle();
      let leaseId: string | null = null, lcId: string | null = null, label = "Rent", due = 0, owed = 0;
      if (lease) {
        leaseId = (lease as any).leases.id; label = `Rent — ${(lease as any).leases.rental_units.address}`;
        const { data: d } = await admin.rpc("lease_rent_due", { p_lease: leaseId, p_as_of: new Date().toISOString().slice(0, 10) });
        // Nothing due yet: suggest one month of what the tenant pays (their portion, if an agency pays part).
        const { data: mine } = await admin.rpc("lease_tenant_rent", { p_lease: leaseId });
        due = Number(d) || (mine == null ? Number((lease as any).leases.rent) : Number(mine)) || 0;
        owed = due;   // nothing owed yet: one month (a payment ahead), minus anything already on its way
        if ((lease as any).leases.move_in_charges_posted && !(lease as any).leases.keys_ready_at) {
          // Move-in: the security deposit and first month's rent, together.
          const { data: rows } = await admin.from("lease_ledger_entries").select("amount").eq("lease_id", leaseId);
          due = Math.max((rows || []).reduce((t: number, e: { amount: number }) => t + Number(e.amount), 0), 0);
          label = `Move-in (security deposit + first month) — ${(lease as any).leases.rental_units.address}`;
          owed = due;
        }
      } else {
        const { data: lc } = await admin.from("land_contract_buyers").select("land_contracts!inner(id, status, monthly_payment, rental_properties!inner(street))").eq("tenant_id", tenantId).eq("land_contracts.status", "active").limit(1).maybeSingle();
        if (!lc) return json(req, 404, { error: "No active lease or land contract found." });
        lcId = (lc as any).land_contracts.id; label = `Land contract payment — ${(lc as any).land_contracts.rental_properties.street}`; due = Number((lc as any).land_contracts.monthly_payment); owed = due;
      }
      const amount = Math.round((Number(body.amount) > 0 ? Number(body.amount) : due) * 100) / 100;
      if (!(amount >= 1 && amount <= 20000)) return json(req, 400, { error: "Enter an amount between $1 and $20,000." });
      const refCol: Col = leaseId ? "lease_id" : "land_contract_id", refId = (leaseId || lcId)!;
      const refuse = clearingRefusal(await onTheWay(refCol, refId), owed, amount);
      if (refuse) return json(req, 409, { error: refuse });
      await expireOpenCheckouts(refCol, refId, (m, p) => sp(m, p, {}));
      const { data: row, error } = await admin.from("stripe_payments").insert({ tenant_id: tenantId, lease_id: leaseId, land_contract_id: lcId, amount, origin: "pay_now" }).select("id").single();
      if (error) throw error;
      // Cards (Stephen, 10/11/2026; debit only since 10/30/2026, the webhook refunds a credit card), only while portal_settings tenant_cards is on: bank account or the tenant's OWN card, with 3D Secure
      // (the card's bank verifies the cardholder), the billing name and address collected, and a written authorization on the pay button.
      // The webhook then checks the cardholder name against the lease and refunds a card that isn't a tenant's. Autopay stays bank-only.
      const cardsOn = setting("tenant_cards") === "on";
      let payMethods: Record<string, unknown> = methods, cardExtras: Record<string, unknown> = {};
      if (cardsOn) {
        if (acct === "main") payMethods = { payment_method_types: ["us_bank_account", "card"] };
        else {
          const pc = (await admin.from("portal_settings").select("value").eq("key", `stripe_pmc_card_${acct}`).maybeSingle()).data?.value;
          if (pc) payMethods = { payment_method_configuration: pc };
        }
        if (JSON.stringify(payMethods) !== JSON.stringify(methods)) cardExtras = {
          billing_address_collection: "auto",   // only what the card needs (often just the ZIP): less typing
          custom_text: { submit: { message: `I am ${t.name}. This payment is from my own bank account or my own debit card, and I authorize this charge for my rent. A credit card, or a card not in my name, will be refunded.` } },
        };
      }
      const sessionParams = {
        mode: "payment", customer: cust.customer_id, client_reference_id: row.id,
        ...payMethods, ...cardExtras,
        payment_method_options: { us_bank_account: { verification_method: "automatic" }, ...(Object.keys(cardExtras).length ? { card: { request_three_d_secure: "any" } } : {}) },
        line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: Math.round(amount * 100), product_data: { name: label } } }],
        payment_intent_data: { description: label, metadata: { stripe_payment_id: row.id, tenant_id: tenantId, lease_id: leaseId || "", land_contract_id: lcId || "" } },
        success_url: portal("#payments?stripe=done"), cancel_url: portal("#payments"),
      };
      // The tenant may tick "save" for their bank account or debit card; their next payment then offers it (no bank sign-in, no typing).
      // A saved account is never charged without the tenant at Checkout: autopay uses only the account named in its own signed authorization.
      let s: any;
      try {
        {
          try { s = await sp("POST", "checkout/sessions", { ...sessionParams, saved_payment_method_options: { payment_method_save: "enabled" } }, `checkout-${row.id}`); }
          catch (e) {
            // If Stripe refuses the save option, the tenant can still pay: retry without it (new idempotency key, the parameters differ).
            if (!(e as { status?: number }).status || (e as { status: number }).status >= 500 || !/saved_payment_method/i.test(String((e as Error).message))) throw e;
            console.error("stripe-pay: tenant checkout without the save option:", (e as Error).message);
            s = await sp("POST", "checkout/sessions", sessionParams, `checkout-${row.id}-nosave`);
          }
        }
      } catch (e) { await admin.from("stripe_payments").delete().eq("id", row.id); throw e; }   // no stale "started" attempt
      await admin.from("stripe_payments").update({ checkout_session: s.id }).eq("id", row.id);
      return json(req, 200, { url: s.url });
    }

    // Autopay is started only from a setup this tenant just authorized themselves (terms read, boxes checked, name typed, a code emailed to them).
    // The server refuses a "view as" session, so staff cannot start or cancel it as the tenant.
    if (body.action === "autopay_setup") {
      const authId = String(body.authorization_id || "");
      const { data: ready, error: rerr } = await uc.rpc("autopay_setup_ready", { p_auth: authId });
      if (rerr) return json(req, 403, { error: rerr.message });
      // The bank must be connected in the Stripe account this lease's rent goes to, or every withdrawal would land in the wrong account.
      if (!ready?.account || ready.account !== acct) return json(req, 403, { error: "Autopay can't be set up for this lease online. Open Payments to see how to pay, or call or text (262) 236-5443." });
      const s = await sp("POST", "checkout/sessions", {
        mode: "setup", customer: cust.customer_id, currency: "usd", ...methods,
        payment_method_options: { us_bank_account: { verification_method: "automatic" } },
        custom_text: { submit: { message: "I am setting up autopay myself. Money will leave this account on the day I chose, I will get email reminders before each withdrawal, and I can cancel any time in my portal." } },
        setup_intent_data: { metadata: { tenant_id: tenantId, purpose: "autopay", authorization_id: authId } },
        success_url: portal("#payments?autopay=done"), cancel_url: portal("#payments"),
      });
      return json(req, 200, { url: s.url });
    }

    if (body.action === "autopay_cancel") {
      const { data: c, error: cerr } = await uc.rpc("autopay_cancel");
      if (cerr) return json(req, 403, { error: cerr.message });
      return json(req, 200, { ok: true, canceled: c?.canceled || 0 });
    }
    return json(req, 400, { error: "Unknown action" });
  } catch (err) {
    console.error("stripe-pay: error", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "We couldn't start the payment. Try again." });
  }
});
