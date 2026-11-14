// Stripe webhooks (signature-verified with STRIPE_WEBHOOK_SECRET; each event
// handled once). The ONLY place a Stripe payment becomes "paid" in the ledger.
//   checkout.session.completed   pay-now: link the payment intent; setup: save autopay bank
//   payment_intent.processing    bank payment submitted (clears in a few business days)
//   payment_intent.succeeded     post the payment (verified by Stripe), receipt follows
//   payment_intent.payment_failed mark failed, tell the tenant and staff (after a success: reverse the posted payment)
//   charge.refunded               reverse the refunded amount on the ledger (offsetting line; nothing deleted)
//   charge.dispute.created        mark disputed, tell staff;  charge.dispute.closed: lost -> reverse, won -> nothing
//   payout.paid / payout.failed   record the payout so the Chase deposit it makes is recognised (not a tenant payment)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { escapeHtml, PORTAL_BASE_URL, SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL } from "../_shared/config.ts";
import { flushOutbox, sendEmail } from "../_shared/mail.ts";
import { stripe, verifyStripeSignature } from "../_shared/stripe.ts";

// One endpoint serves both Stripe accounts; the signing secret that matches tells which account sent the event.
const SECRETS: Record<string, string> = { main: Deno.env.get("STRIPE_WEBHOOK_SECRET") || "", yawdcour: Deno.env.get("STRIPE_WEBHOOK_SECRET_YAWDCOUR") || "", roca1: Deno.env.get("STRIPE_WEBHOOK_SECRET_ROCA1") || "" };
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

// A pending payment just ended badly: tell rent-cycle to prepare the pay-or-vacate notice (tenants) and post the late fee (owners)
// that were held back while it was pending. Best effort; the daily run catches anything this misses.
async function catchup(leaseId?: string | null) {
  try {
    await fetch(`${SUPABASE_URL}/functions/v1/rent-cycle`, { method: "POST",
      headers: { "Content-Type": "application/json", "x-cycle-secret": Deno.env.get("RENT_CYCLE_SECRET") || "" },
      body: JSON.stringify({ action: "catchup", lease_id: leaseId || null }) });
  } catch (e) { console.error("stripe-webhook: catchup failed", e instanceof Error ? e.message : String(e)); }
}
// The seller of a land contract is emailed when a buyer's payment is submitted, clears, is rejected, or is returned after clearing
// (Stephen, 10/18/2026). Best effort: a failed email never stops the payment from being recorded.
async function tellSellers(row: any, kind: "submitted" | "cleared" | "failed" | "returned") {
  if (!row?.land_contract_id) return;
  try {
    const { data: c } = await admin.from("land_contracts").select("buyers_label, rental_properties(street), land_contract_sellers(name, email, active)").eq("id", row.land_contract_id).single();
    const sellers = ((c as any)?.land_contract_sellers || []).filter((s: any) => s.active && s.email);
    if (!sellers.length) return;
    const street = (c as any).rental_properties?.street || "the property", amt = `$${Number(row.amount).toFixed(2)}`, buyers = (c as any).buyers_label || "The buyers";
    const link = new URL("/seller/", PORTAL_BASE_URL).toString();
    const [subject, body] = kind === "submitted"
      ? [`Payment submitted: ${amt} for ${street}`, `${escapeHtml(buyers)} paid <b>${amt}</b> toward the land contract for ${escapeHtml(street)} from their bank account. A bank payment takes 3 to 5 business days to clear. We will email you again when it clears, or if the bank rejects it.`]
      : kind === "cleared"
      ? [`Payment cleared: ${amt} for ${street}`, `The <b>${amt}</b> payment from ${escapeHtml(buyers)} cleared and was added to the land contract for ${escapeHtml(street)}.`]
      : kind === "failed"
      ? [`Payment rejected: ${amt} for ${street}`, `The bank did not accept the <b>${amt}</b> payment from ${escapeHtml(buyers)} for ${escapeHtml(street)}. Nothing was added to the land contract, and the buyers have been told.`]
      : [`Payment returned: ${amt} for ${street}`, `The <b>${amt}</b> payment from ${escapeHtml(buyers)} for ${escapeHtml(street)} had cleared, but the bank has returned it. It was taken off the land contract, and the buyers have been told.`];
    for (const s of sellers) {
      await sendEmail({ to: s.email, subject, html: `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;color:#1b2430;line-height:1.5"><p style="font-weight:700;color:#1d3a5c;font-size:18px;margin:0 0 14px">2nd Chance Housing</p><p>Hi ${escapeHtml(String(s.name || "").split(/\s+/)[0] || "there")},</p><p>${body}</p><p>See your contract, the payments received and the schedule: <a href="${link}">${link}</a></p><p>Questions? Reply to this email, or call or text (262) 236-5443.</p><p>Thank you,<br>2nd Chance Housing Inc.</p></div>` });
    }
  } catch (e) { console.error("stripe-webhook: could not email the seller", e instanceof Error ? e.message : String(e)); }
}
async function rowFor(pi: any) {
  let { data } = await admin.from("stripe_payments").select("*").eq("payment_intent", pi.id).maybeSingle();
  if (!data && pi.metadata?.stripe_payment_id) {
    ({ data } = await admin.from("stripe_payments").update({ payment_intent: pi.id }).eq("id", pi.metadata.stripe_payment_id).select("*").maybeSingle());
  }
  return data;
}
// Card name check: the name on the card must be a tenant on the lease (first and last name, or first initial and last name).
const nameWords = (s: string) => s.toLowerCase().replace(/\b(jr|sr|ii|iii|iv)\b/g, " ").replace(/[^a-z\s]/g, " ").split(/\s+/).filter(Boolean);
function nameMatches(tenant: string, holder: string) {
  const t = nameWords(tenant), h = nameWords(holder);
  if (t.length < 2 || h.length < 2) return t.join(" ") === h.join(" ");
  const first = t[0], last = t[t.length - 1];
  return h.includes(last) && (h.includes(first) || h.some((w) => w[0] === first[0] && w.length === 1));
}
async function leaseNames(row: any): Promise<string[]> {
  if (row.lease_id) {
    const { data } = await admin.from("lease_tenants").select("tenants(name)").eq("lease_id", row.lease_id);
    return (data || []).map((x: any) => x.tenants?.name).filter(Boolean);
  }
  if (row.land_contract_id) {
    const { data } = await admin.from("land_contract_buyers").select("tenants(name)").eq("contract_id", row.land_contract_id);
    return (data || []).map((x: any) => x.tenants?.name).filter(Boolean);
  }
  const { data } = await admin.from("tenants").select("name").eq("id", row.tenant_id);
  return (data || []).map((x: any) => x.name);
}
const methodType = (pi: any) => pi.payment_method_types?.length === 1 ? pi.payment_method_types[0]
  : pi.latest_charge?.payment_method_details?.type || (typeof pi.payment_method === "object" ? pi.payment_method?.type : null) || null;

// Autopay turns on only for a setup the tenant authorized themselves (the authorization id travels with the setup), and only once
// Stripe says the bank account is VERIFIED. A bank still being verified (small test deposits) waits for setup_intent.succeeded;
// a failed one cancels the setup. Activation is idempotent, so the two events that can both arrive for one setup are harmless.
// deno-lint-ignore no-explicit-any
async function autopaySetup(setupIntentId: string, account: string, customer?: any) {
  const si = await stripe("GET", `setup_intents/${setupIntentId}`, { expand: ["payment_method"] }, undefined, account);
  const pm = si.payment_method, bank = pm?.us_bank_account, authId = si.metadata?.authorization_id;
  if (!authId || si.metadata?.purpose !== "autopay") return;
  if (si.status === "succeeded" && pm?.id) {
    const { error } = await admin.rpc("autopay_activate", { p_auth: authId, p_customer: customer || si.customer || "", p_account: account, p_pm: pm.id,
      p_bank: bank ? `${bank.bank_name || "Bank"} ••••${bank.last4}` : null, p_setup_intent: si.id, p_mandate: typeof si.mandate === "string" ? si.mandate : si.mandate?.id || null });
    if (error) throw error;
  } else if (si.status === "requires_action" || si.status === "processing") {
    const { error } = await admin.rpc("autopay_bank_verifying", { p_auth: authId, p_setup_intent: si.id }); if (error) throw error;
  } else if (si.status === "canceled" || si.status === "requires_payment_method") {
    const { error } = await admin.rpc("autopay_setup_failed", { p_auth: authId, p_reason: si.last_setup_error?.message || "the bank connection was not completed" }); if (error) throw error;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const payload = await req.text();
  let account = "";
  for (const [name, secret] of Object.entries(SECRETS)) { if (secret && await verifyStripeSignature(payload, req.headers.get("stripe-signature"), secret)) { account = name; break; } }
  if (!account) return new Response("bad signature", { status: 400 });
  const ev = JSON.parse(payload);
  const { error: dup } = await admin.from("stripe_events").insert({ id: ev.id, type: ev.type });
  if (dup) return Response.json({ duplicate: true });
  try {
    const o = ev.data.object;
    if (ev.type === "checkout.session.completed") {
      if (o.mode === "payment") {
        await admin.from("stripe_payments").update({ payment_intent: o.payment_intent, status: o.payment_status === "paid" ? "processing" : "processing", updated_at: new Date().toISOString() })
          .eq("checkout_session", o.id).is("payment_intent", null);
      } else if (o.mode === "setup" && o.setup_intent) {
        await autopaySetup(o.setup_intent, account, o.customer);
      }
    } else if (ev.type === "checkout.session.expired") {
      // The payer opened checkout but never finished it (Stripe expires it after 24 hours); nothing was charged (Stephen, 11/3/2026).
      if (o.mode === "payment") {
        await admin.from("stripe_payments").update({ status: "canceled", failure_message: "Checkout expired in Stripe without being finished; nothing was charged", updated_at: new Date().toISOString() })
          .eq("checkout_session", o.id).eq("status", "created");
      }
    } else if (ev.type === "setup_intent.succeeded" && o.metadata?.purpose === "autopay") {
      await autopaySetup(o.id, account, o.customer);   // the bank finished verifying (small test deposits): autopay turns on now
    } else if (ev.type === "setup_intent.setup_failed" && o.metadata?.purpose === "autopay" && o.metadata?.authorization_id) {
      const { error } = await admin.rpc("autopay_setup_failed", { p_auth: o.metadata.authorization_id, p_reason: o.last_setup_error?.message || "the bank could not be verified" }); if (error) throw error;
    } else if (ev.type === "payment_intent.processing") {
      const row = await rowFor(o);
      if (row && row.status !== "succeeded" && Number(row.refunded_amount || 0) < Number(row.amount)) await admin.from("stripe_payments").update({ status: "processing", method_type: methodType(o), updated_at: new Date().toISOString() }).eq("id", row.id);
      if (row && row.status !== "succeeded" && row.status !== "processing") await tellSellers(row, "submitted");   // once, not on a repeated event
    } else if (ev.type === "payment_intent.succeeded") {
      const row = await rowFor(o);
      if (row) {
        // Which method paid, and (cards) whose name is on it. The event carries only the charge id, so fetch it.
        let pi: any = o;   // if the key cannot read the charge, fall back to the event itself (no card name check) rather than fail to post the payment
        try { pi = await stripe("GET", `payment_intents/${o.id}`, { expand: ["latest_charge"] }, undefined, account); } catch (e) { console.error("stripe-webhook: could not read the charge", e instanceof Error ? e.message : String(e)); }
        const mt = methodType(pi);
        if (mt === "card" && row.tenant_id) {
          const ch = pi.latest_charge, holder: string = ch?.billing_details?.name || "", cd = ch?.payment_method_details?.card;
          const names = await leaseNames(row);
          const ok = !holder || !names.length || names.some((n) => nameMatches(n, holder));   // no name on the card: allow, staff are told
          await admin.from("stripe_payments").update({ payer_name: holder || null, card_brand: cd?.brand || null, card_last4: cd?.last4 || null,
            name_check: !holder ? "missing" : ok ? "match" : "mismatch" }).eq("id", row.id);
          if (cd?.funding && !["debit", "prepaid"].includes(cd.funding)) {
            // Debit cards only (Stephen, 10/30/2026): Checkout cannot filter by card type, so a credit card is refunded before it is ever posted.
            await admin.from("stripe_payments").update({ status: "canceled", refunded_amount: row.amount, updated_at: new Date().toISOString(),
              failure_message: "Only debit cards are accepted, so this credit card payment was refunded." }).eq("id", row.id);
            await stripe("POST", "refunds", { payment_intent: o.id, metadata: { reason: "credit card: debit cards only" } }, `refund-credit-${o.id}`, account);
            const { data: tn } = await admin.from("tenants").select("name, email").eq("id", row.tenant_id).single();
            if (tn?.email) await sendEmail({ to: tn.email, subject: "Your card payment was refunded: please use a debit card", html: `<p>Hi ${escapeHtml(tn.name.split(/\s+/)[0])},</p><p>Your payment of $${Number(row.amount).toFixed(2)} was made with a credit card. We accept <b>debit cards</b> and bank accounts only, so it was refunded. The refund reaches your card in 5 to 10 days. Please pay again with your debit card or from your bank account at https://2ndchinc.org/resident/#payments. Rent is not paid until a payment goes through. Questions: (262) 236-5443.</p>` });
            await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "Credit card payment refunded", html: `<p>${escapeHtml(tn?.name || "")} paid $${Number(row.amount).toFixed(2)} with a credit card. It was refunded automatically and not posted.</p>` });
            await flushOutbox(admin);
            return Response.json({ received: true, refunded: "credit card" });
          }
          if (!ok) {
            // Not a tenant's card: refund it before it is ever posted (refunded_amount is set first so the refund event posts nothing).
            await admin.from("stripe_payments").update({ status: "canceled", refunded_amount: row.amount, updated_at: new Date().toISOString(),
              failure_message: `The name on the card (${holder}) is not a tenant on this lease, so it was refunded.` }).eq("id", row.id);
            await stripe("POST", "refunds", { payment_intent: o.id, metadata: { reason: "card name does not match the tenant" } }, `refund-name-${o.id}`, account);
            const { data: tn } = await admin.from("tenants").select("name, email").eq("id", row.tenant_id).single();
            if (tn?.email) await sendEmail({ to: tn.email, subject: "Your card payment was refunded", html: `<p>Hi ${escapeHtml(tn.name.split(/\s+/)[0])},</p><p>Your card payment of $${Number(row.amount).toFixed(2)} was refunded because the name on the card (${escapeHtml(holder)}) is not a tenant on your lease. Rent must be paid from your own card or bank account. The refund reaches your card in 5 to 10 days. Please pay again with your own card or bank account, or by Zelle. Questions: (262) 236-5443.</p>` });
            await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "Card payment refunded: name mismatch", html: `<p>${escapeHtml(tn?.name || "")} paid $${Number(row.amount).toFixed(2)} with a card in the name of ${escapeHtml(holder)}. It was refunded automatically and not posted.</p>` });
            await flushOutbox(admin);
            return Response.json({ received: true, refunded: "name mismatch" });
          }
          if (!holder) await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "Card payment with no name on it", html: `<p>A $${Number(row.amount).toFixed(2)} card payment came with no cardholder name, so the name check could not run. Please look at it in Stripe (payment ${escapeHtml(o.id)}).</p>` });
        }
        const { data: posted, error } = await admin.rpc("stripe_payment_succeeded", { p_intent: o.id, p_method_type: mt }); if (error) throw error;
        if (!(posted as { already?: boolean } | null)?.already) await tellSellers(row, "cleared");
        if (row.origin === "autopay") await admin.rpc("autopay_debit_result", { p_stripe_payment: row.id, p_kind: "debit_succeeded", p_reason: null });
      } else {
        // Money was taken but no payment row matches it: never let that pass silently.
        await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "Stripe payment received but not posted", html: `<p>Stripe reports a successful payment of $${(Number(o.amount_received ?? o.amount) / 100).toFixed(2)} (${escapeHtml(o.id)}, ${escapeHtml(account)} account) that matches no payment started on the site, so it was NOT posted to any ledger. Find it in the Stripe dashboard and post it by hand.</p>` });
      }
    } else if (ev.type === "payment_intent.payment_failed" && (await rowFor(o))?.status === "succeeded") {
      // A bank payment that failed after Stripe reported it succeeded (ACH return): reverse what was posted.
      const msg = o.last_payment_error?.message || "The bank returned the payment.";
      const { error } = await admin.rpc("stripe_payment_reverse", { p_intent: o.id, p_amount: null, p_reason: `Returned by the bank: ${msg}`, p_returned: true }); if (error) throw error;
      await catchup((await rowFor(o))?.lease_id);
      await tellSellers(await rowFor(o), "returned");
      { const r2 = await rowFor(o); if (r2?.origin === "autopay") await admin.rpc("autopay_debit_result", { p_stripe_payment: r2.id, p_kind: "debit_returned", p_reason: msg }); }
      await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "Stripe payment returned after it posted", html: `<p>Payment ${escapeHtml(o.id)} was returned: ${escapeHtml(msg)}. It was reversed on the ledger; the tenant or owner now owes it again.</p>` });
    } else if (ev.type === "payment_intent.payment_failed") {
      const row = await rowFor(o);
      if (row && Number(row.refunded_amount || 0) >= Number(row.amount)) {
        // Already refunded by us before it cleared (e.g. a duplicate payment): it failing is fine; no "didn't go through" emails.
        await admin.from("stripe_payments").update({ status: "canceled", updated_at: new Date().toISOString() }).eq("id", row.id);
      } else if (row) {
        const msg = o.last_payment_error?.message || "The payment didn't go through.";
        await admin.from("stripe_payments").update({ status: "failed", failure_message: msg, updated_at: new Date().toISOString() }).eq("id", row.id);
        await catchup(row.lease_id);   // the hold on notices and late fees ends now
        if (row.status !== "failed") await tellSellers(row, "failed");   // once, not on a repeated event
        if (row.origin === "autopay") await admin.rpc("autopay_debit_result", { p_stripe_payment: row.id, p_kind: "debit_failed", p_reason: msg });
        const isOwner = !!row.owner_id;
        const { data: t } = isOwner ? await admin.from("condo_owners").select("name, email").eq("id", row.owner_id).single()
                                    : await admin.from("tenants").select("name, email").eq("id", row.tenant_id).single();
        if (isOwner && t?.email) await sendEmail({ to: t.email, subject: "Your association dues payment didn't go through",
          html: `<p>Hi ${escapeHtml(t.name.split(/\s+/)[0])},</p><p>Your online payment of $${Number(row.amount).toFixed(2)} didn't go through: ${escapeHtml(msg)}</p><p>Please try again in your <a href="${new URL("/owners/", PORTAL_BASE_URL)}">owner portal</a> or call (262) 236-5443.</p><p>2nd Chance Housing, managing agent for ROCA1</p>` });
        else if (t?.email) await sendEmail({ to: t.email, subject: "Your rent payment didn't go through",
          html: `<p>Hi ${escapeHtml(t.name.split(/\s+/)[0])},</p><p>Your ${row.origin === "autopay" ? "automatic " : ""}payment of $${Number(row.amount).toFixed(2)} didn't go through: ${escapeHtml(msg)}</p><p>Please pay in your <a href="${new URL("/resident/", PORTAL_BASE_URL)}#payments">resident portal</a> or call (262) 236-5443.</p><p>2nd Chance Housing</p>` });
        await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: `Stripe payment failed — ${t?.name || ""}`, html: `<p>$${Number(row.amount).toFixed(2)} (${row.origin}) failed: ${escapeHtml(msg)}</p>` });
      }
    } else if (ev.type === "charge.refunded" && o.payment_intent) {
      // Refunds can be partial and repeated: reverse only what hasn't been reversed yet.
      const { data: sp } = await admin.from("stripe_payments").select("id, refunded_amount").eq("payment_intent", o.payment_intent).maybeSingle();
      if (sp) {
        const total = Number(o.amount_refunded || 0) / 100, delta = Math.round((total - Number(sp.refunded_amount || 0)) * 100) / 100;
        if (delta > 0) {
          const { error } = await admin.rpc("stripe_payment_reverse", { p_intent: o.payment_intent, p_amount: delta, p_reason: "Refunded in Stripe" }); if (error) throw error;
          await admin.from("stripe_payments").update({ refunded_amount: total, updated_at: new Date().toISOString() }).eq("id", sp.id);
        }
      }
    } else if (ev.type === "charge.dispute.created" && o.payment_intent) {
      { const dr = await rowFor({ id: o.payment_intent }); if (dr?.origin === "autopay") await admin.rpc("autopay_debit_result", { p_stripe_payment: dr.id, p_kind: "debit_returned", p_reason: "The withdrawal was disputed with the bank." }); }   // a disputed autopay withdrawal pauses autopay
      await admin.from("stripe_payments").update({ status: "disputed", failure_message: `Disputed: ${o.reason || ""}`, updated_at: new Date().toISOString() }).eq("payment_intent", o.payment_intent).eq("status", "succeeded");
      await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "Stripe payment disputed", html: `<p>A payment of $${(Number(o.amount) / 100).toFixed(2)} (${escapeHtml(o.payment_intent)}) was disputed (${escapeHtml(o.reason || "no reason given")}). Respond in the Stripe dashboard by ${o.evidence_details?.due_by ? new Date(o.evidence_details.due_by * 1000).toDateString() : "the deadline Stripe shows"}. If the dispute is lost, the payment is reversed on the ledger automatically.</p>` });
    } else if (ev.type === "charge.dispute.closed" && o.payment_intent) {
      if (o.status === "lost") {
        const { error } = await admin.rpc("stripe_payment_reverse", { p_intent: o.payment_intent, p_amount: Number(o.amount) / 100, p_reason: `Dispute lost (${o.reason || "chargeback"})`, p_returned: true }); if (error) throw error;
        await catchup((await rowFor({ id: o.payment_intent }))?.lease_id);   // a lost chargeback: the rent is unpaid again, so the late fee and notice follow now
      } else if (o.status === "won") {
        await admin.from("stripe_payments").update({ status: "succeeded", updated_at: new Date().toISOString() }).eq("payment_intent", o.payment_intent).eq("status", "disputed");
      }
    } else if (ev.type === "payout.paid" || ev.type === "payout.failed") {
      const { error } = await admin.rpc("stripe_payout_record", { p_id: o.id, p_amount: Number(o.amount) / 100,
        p_arrival: o.arrival_date ? new Date(o.arrival_date * 1000).toISOString().slice(0, 10) : null, p_status: ev.type === "payout.paid" ? "paid" : "failed", p_description: o.statement_descriptor || o.description || null, p_account: account });
      if (error) throw error;
      if (ev.type === "payout.failed") await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "Stripe payout failed", html: `<p>Stripe payout ${escapeHtml(o.id)} of $${(Number(o.amount) / 100).toFixed(2)} failed: ${escapeHtml(o.failure_message || "")}</p>` });
    }
    await flushOutbox(admin);   // receipts, "keys can be released"
    return Response.json({ received: true });
  } catch (err) {
    await admin.from("stripe_events").delete().eq("id", ev.id);   // let Stripe retry
    console.error("stripe-webhook: error", err instanceof Error ? err.message : String(err));
    return new Response("error", { status: 500 });
  }
});
