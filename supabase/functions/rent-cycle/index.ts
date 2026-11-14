// The monthly rent cycle (tenant-journey-spec.md, Stage 4). Run daily by
// pg_cron at 12:05 am Central with header x-cycle-secret. Each job runs at
// most once per day (rent_cycle_runs). Also sends queued emails (receipts).
//
// Land contracts (Wisconsin): default 10 days after the due date (contract),
// Notice of Default and Right to Cure (30-day cure), then, if uncured, staff
// alert and a "what happens next" email (strict foreclosure, Wis. Stat. 846.30).
//
// Local testing only: POST { as_of: "YYYY-MM-DD" } pretends it's that date.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { escapeHtml, IS_LOCAL, PORTAL_BASE_URL, SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL } from "../_shared/config.ts";
import { flushOutbox, sendEmail } from "../_shared/mail.ts";
import { fillTemplate } from "../_shared/letters.ts";
import { stripe } from "../_shared/stripe.ts";

const SECRET = Deno.env.get("RENT_CYCLE_SECRET") || "";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const money = (n: number) => "$" + Number(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const iso = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (s: string, n: number) => { const d = new Date(s + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return iso(d); };
const pretty = (s: string) => new Date(s + "T12:00:00Z").toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: "numeric", timeZone: "UTC" });
const chicagoToday = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
const portal = () => new URL("/resident/", PORTAL_BASE_URL).toString();

type Unpaid = { lease_id: string; unit_label: string; address: string; rent_due: number; pending_reported: number; tenants: { name: string; email: string }[]; account_number: string; property_key: string };

// retryOnError: for a job that only posts what is still missing (monthly rent and dues), release the day's claim when it throws, so the
// next run (the second daily call) tries again instead of skipping it until next month. The error email to staff still goes out.
async function once(job: string, day: string, fn: () => Promise<unknown>, retryOnError = false) {
  const { error } = await admin.from("rent_cycle_runs").insert({ job, run_date: day });
  if (error) return { job, skipped: "already ran today" };
  let result: unknown;
  try { result = await fn(); }
  catch (e) { if (retryOnError) await admin.from("rent_cycle_runs").delete().eq("job", job).eq("run_date", day); throw e; }
  await admin.from("rent_cycle_runs").update({ result }).eq("job", job).eq("run_date", day);
  return { job, result };
}
async function settings() {
  const { data } = await admin.from("portal_settings").select("key, value");
  return Object.fromEntries((data || []).map((r) => [r.key, r.value])) as Record<string, string>;
}
async function unpaid(day: string): Promise<Unpaid[]> {
  const { data, error } = await admin.rpc("rent_unpaid", { p_as_of: day });
  if (error) throw error;
  return (data || []).map((u: Unpaid) => ({ ...u, rent_due: Number(u.rent_due), pending_reported: Number(u.pending_reported), tenants: u.tenants || [] }));
}
async function agents() {
  const { data } = await admin.from("lease_agents").select("name, email").eq("active", true);
  return data || [];
}
// Our pay-or-vacate notice for one lease, mailed on `mailOn`: 5 or 30 days and
// the deadline come from the lease (pay_or_vacate_notice / lease_notice_rules).
type PayOrVacate = { template_id: string; template_name: string; subject: string; html: string; email_subject: string; email_html: string;
  days: number; deadline: string; amount_required: number; federal_program: string | null };
async function payOrVacate(leaseId: string, mailOn: string, sender = ""): Promise<PayOrVacate> {
  const { data, error } = await admin.rpc("pay_or_vacate_notice", { p_lease: leaseId, p_mail_on: mailOn, p_sender_email: sender });
  if (error) throw error;
  return data as PayOrVacate;
}

// The projected sequence if rent stays unpaid, from the day the notice is mailed:
// notice ends -> case filed -> court date -> writ decision -> sheriff. Every gap is a
// portal setting (court_days_after_filing, writ_days_after_court, sheriff_days_after_writ).
async function evictionTimeline(leaseId: string, served: string, s: Record<string, string>) {
  const { days, deadline: noticeEnd } = await payOrVacate(leaseId, served);
  const { data: filing } = await admin.rpc("next_business_day", { p_day: addDays(noticeEnd, 1) });
  const { data: court } = await admin.rpc("next_business_day", { p_day: addDays(filing, Number(s.court_days_after_filing || 14)) });
  const { data: writ } = await admin.rpc("next_business_day", { p_day: addDays(court, Number(s.writ_days_after_court || 0)) });
  const sheriff = addDays(writ, Number(s.sheriff_days_after_writ || 10));
  return { days, noticeEnd: noticeEnd as string, filing: filing as string, court: court as string, writ: writ as string, sheriff };
}

async function emailTenants(u: Unpaid, subject: string, body: (first: string) => string) {
  let n = 0;
  for (const t of u.tenants) if (t.email) { await sendEmail({ to: t.email, subject, html: body(escapeHtml(t.name.split(/\s+/)[0])) }); n++; }
  return n;
}

// ---------------------------------------------------------------------------
// Autopay: one withdrawal at a time.
// Stripe accounts whose secret key is set here (autopay never tries an account it cannot reach).
const keyedAccounts = () => ([["main", "STRIPE_SECRET_KEY"], ["yawdcour", "STRIPE_SECRET_KEY_YAWDCOUR"], ["roca1", "STRIPE_SECRET_KEY_ROCA1"]] as const)
  .filter(([, k]) => !!Deno.env.get(k)).map(([a]) => a);
type AutopayDue = { authorization_id: string; tenant_id: string; lease_id: string | null; land_contract_id: string | null; customer_id: string; payment_method: string; stripe_account: string; amount: number };
const autopayHold = (a: AutopayDue, day: string, reason: string) => admin.rpc("autopay_hold", { p_auth: a.authorization_id, p_cycle: day, p_kind: "held", p_reason: reason, p_alert: true });

// Returns true when the withdrawal was started at the bank.
async function autopayOne(a: AutopayDue, day: string): Promise<boolean> {
  const account = a.stripe_account || "main";
  const { data: row, error: ierr } = await admin.from("stripe_payments").insert({ tenant_id: a.tenant_id, lease_id: a.lease_id, land_contract_id: a.land_contract_id, amount: a.amount, origin: "autopay", method_type: "us_bank_account" }).select("id").single();
  if (ierr || !row) { await autopayHold(a, day, "of a problem on our side (nothing was sent to your bank)"); throw new Error(`could not record the withdrawal, nothing withdrawn: ${ierr?.message || "no row"}`); }
  // Logged BEFORE Stripe is called, so a crash can never lead to a second withdrawal the same day. If it cannot be logged, no money is taken.
  const { error: rerr } = await admin.rpc("autopay_record", { p_auth: a.authorization_id, p_kind: "debit_started", p_detail: { cycle: day, stripe_payment_id: row.id, amount: a.amount } });
  if (rerr) {
    await admin.from("stripe_payments").update({ status: "canceled", failure_message: `Not sent to the bank: the autopay log could not be written (${rerr.message})` }).eq("id", row.id);
    await autopayHold(a, day, "of a problem on our side (nothing was sent to your bank)");
    throw new Error(`autopay log not written, nothing withdrawn: ${rerr.message}`);
  }

  // The same idempotency key on every try: Stripe makes at most one withdrawal for it, however many times it is sent.
  const params = {
    amount: Math.round(Number(a.amount) * 100), currency: "usd", customer: a.customer_id, payment_method: a.payment_method,
    payment_method_types: ["us_bank_account"], confirm: true, off_session: true, description: `Autopay ${day.slice(0, 7)}`,
    metadata: { stripe_payment_id: row.id, tenant_id: a.tenant_id, lease_id: a.lease_id || "", land_contract_id: a.land_contract_id || "", authorization_id: a.authorization_id },
  };
  const idem = `autopay-${a.authorization_id}-${day}`;
  const since = Math.floor(Date.now() / 1000) - 300;
  // deno-lint-ignore no-explicit-any
  let pi: any = null, refused: string | null = null, lastErr = "";
  for (let attempt = 0; attempt < 3 && !pi && !refused; attempt++) {
    if (attempt) await new Promise((r) => setTimeout(r, 2000 * attempt));
    // deno-lint-ignore no-explicit-any
    try { pi = await stripe("POST", "payment_intents", params, idem, account); } catch (e: any) {
      lastErr = e?.message || String(e);
      // Stripe answered and refused (4xx other than "busy" / "same request still running"): definite, nothing was taken.
      if (e?.status >= 400 && e?.status < 500 && e.status !== 409 && e.status !== 429) refused = lastErr;
    }
  }
  if (!pi && !refused) {
    // The outcome is unknown (Stripe could not be reached, or had an error). Look for the withdrawal itself before deciding anything.
    try {
      const list = await stripe("GET", "payment_intents", { customer: a.customer_id, created: { gte: since }, limit: 100 }, undefined, account);
      // deno-lint-ignore no-explicit-any
      pi = (list?.data || []).find((x: any) => x?.metadata?.stripe_payment_id === row.id) || null;
    } catch (e) {
      // Still unknown. The row stays "created", which blocks any new autopay withdrawal for this lease until it is resolved; the office
      // is told; the tenant is told nothing yet, because the Stripe webhook posts the payment if the withdrawal exists.
      await admin.from("stripe_payments").update({ failure_message: `Outcome unknown: check Stripe (${lastErr})` }).eq("id", row.id);
      await admin.rpc("autopay_record", { p_auth: a.authorization_id, p_kind: "debit_unknown", p_detail: { cycle: day, stripe_payment_id: row.id, error: lastErr.slice(0, 300) } });
      throw new Error(`outcome unknown for withdrawal ${row.id}: ${lastErr}; the lookup failed too: ${e instanceof Error ? e.message : e}`);
    }
    if (!pi) {
      // Stripe answered and there is no such withdrawal: nothing was taken. Not the tenant's fault, so autopay is NOT paused.
      await admin.from("stripe_payments").update({ status: "canceled", failure_message: `Not sent to the bank: Stripe could not be reached (${lastErr})` }).eq("id", row.id);
      await autopayHold(a, day, "our payment system could not reach the bank today (nothing was withdrawn)");
      return false;
    }
  }
  if (refused) {
    await admin.from("stripe_payments").update({ status: "failed", failure_message: refused }).eq("id", row.id);
    await admin.rpc("autopay_debit_result", { p_stripe_payment: row.id, p_kind: "debit_failed", p_reason: refused });   // pauses autopay and tells the tenant
    throw new Error(`refused by Stripe: ${refused}`);
  }
  const failedNow = pi.status === "requires_payment_method" || pi.status === "canceled";
  const why = pi.last_payment_error?.message || "The bank did not accept the withdrawal.";
  await admin.from("stripe_payments").update({ payment_intent: pi.id, status: failedNow ? "failed" : (pi.status === "succeeded" || pi.status === "processing") ? "processing" : "created",
    ...(failedNow ? { failure_message: why } : {}) }).eq("id", row.id);
  if (failedNow) { await admin.rpc("autopay_debit_result", { p_stripe_payment: row.id, p_kind: "debit_failed", p_reason: why }); return false; }
  await admin.rpc("autopay_debit_submitted", { p_auth: a.authorization_id, p_stripe_payment: row.id, p_amount: a.amount, p_intent: pi.id });
  if (pi.status === "succeeded") {
    await admin.rpc("stripe_payment_succeeded", { p_intent: pi.id, p_method_type: "us_bank_account" });
    await admin.rpc("autopay_debit_result", { p_stripe_payment: row.id, p_kind: "debit_succeeded", p_reason: null });
  }
  return true;
}

const jobs = {
  async billing(day: string) { const { data, error } = await admin.rpc("billing_post_month", { p_month: day }); if (error) throw error; return data; },

  // Autopay (Stripe, bank account): ONLY withdrawals the tenant authorized themselves, reminded 10, 7, 3 and 1 day before, no more than they approved.
  // The list comes from autopay_due_v2: at most one per lease/contract a day, and every autopay due today that is NOT in the list
  // was already told why (held/skipped email). One try: a refused withdrawal pauses autopay, never a retry. Each withdrawal is handled
  // on its own, so a problem with one never stops the others or the rest of the day's jobs.
  async autopay(day: string) {
    const { data: due, error } = await admin.rpc("autopay_due_v2", { p_as_of: day, p_keyed: keyedAccounts() });
    if (error) throw error;
    let started = 0; const problems: string[] = [];
    for (const a of due || []) {
      try { if (await autopayOne(a, day)) started++; }
      catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        problems.push(msg);
        await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "Autopay: check this withdrawal in Stripe", html: `<p>The autopay job hit a problem for authorization ${escapeHtml(a.authorization_id)} (${escapeHtml(day)}): ${escapeHtml(msg)}. Check Stripe and the Autopay page before anything else is done.</p>` }).catch(() => {});
      }
    }
    const outbox_sent = await flushOutbox(admin).catch(() => 0);   // the "being withdrawn today" and "not made" emails go out at once
    return { autopay_started: started, problems, outbox_sent };
  },

  // Autopay reminders (10, 7, 3 and 1 day before) and the daily check that no withdrawal exists without an authorization.
  async autopay_reminders(day: string) {
    const { data: r, error } = await admin.rpc("autopay_send_reminders", { p_as_of: day, p_keyed: keyedAccounts() });
    if (error) throw error;
    const { data: au, error: aerr } = await admin.rpc("autopay_audit", { p_as_of: day });
    if (aerr) throw aerr;
    // Sent right away (not at the end of the run), so a reminder never waits on the other jobs.
    const outbox_sent = await flushOutbox(admin).catch(() => 0);
    return { ...r, audit: au, outbox_sent };
  },

  async reminder(day: string) {
    const { data: leases } = await admin.from("leases").select("id, rent, account_number, rental_units!inner(address), lease_tenants(tenants(name, email))").eq("status", "active").gt("rent", 0);
    let n = 0;
    for (const l of leases || []) {
      const { data: bal } = await admin.rpc("lease_rent_due", { p_lease: l.id, p_as_of: day });
      // With housing assistance the tenant pays only their portion (lease rent minus the agency's share).
      const { data: mine } = await admin.rpc("lease_tenant_rent", { p_lease: l.id });
      const rent = mine == null ? Number(l.rent) : Number(mine);
      if (!(rent > 0) && !(Number(bal) > 0)) continue;
      for (const x of (l as any).lease_tenants) if (x.tenants?.email) {
        await sendEmail({ to: x.tenants.email, subject: "Rent reminder: due on the 1st",
          html: `<p>Hi ${escapeHtml(x.tenants.name.split(/\s+/)[0])},</p><p>A friendly reminder that ${rent < Number(l.rent) ? "your portion of the rent" : "rent"} of <b>${money(rent)}</b> for ${escapeHtml((l as any).rental_units.address)} is due on the 1st.${Number(bal) > 0 ? ` Your account also shows <b>${money(Number(bal))}</b> unpaid rent.` : ""}</p>
            <p>Pay by Zelle or another option in your <a href="${portal()}">resident portal</a> and put your account number <b>${escapeHtml(l.account_number || "")}</b> in the memo.</p><p>Please keep your phone and email up to date in the portal.</p><p>2nd Chance Housing</p>` });
        n++;
      }
    }
    const { data: lcs } = await admin.from("land_contracts").select("id, monthly_payment, rental_properties!inner(street), land_contract_buyers(tenants(name, email))").eq("status", "active");
    for (const c of lcs || []) for (const b of (c as any).land_contract_buyers) if (b.tenants?.email) {
      await sendEmail({ to: b.tenants.email, subject: "Land contract payment reminder: due on the 1st",
        html: `<p>Hi ${escapeHtml(b.tenants.name.split(/\s+/)[0])},</p><p>A reminder that your land contract payment of <b>${money(c.monthly_payment)}</b> for ${escapeHtml((c as any).rental_properties.street)} is due on the 1st. Pay in your <a href="${portal()}">resident portal</a>.</p><p>2nd Chance Housing</p>` });
      n++;
    }
    return { emails: n };
  },

  async lc_default(day: string) {
    const s = await settings();
    const cure = addDays(day, Number(s.lc_cure_days || 30));
    const { data: rows, error } = await admin.rpc("lc_unpaid", { p_as_of: day });
    if (error) throw error;
    const { data: tpl } = await admin.from("letter_templates").select("id, name, subject, html").eq("template_key", "lc-default-notice").single();
    const agent = (await agents())[0];
    let n = 0; const problems: string[] = [];
    for (const u of rows || []) {
      const { data: ctx } = await admin.rpc("lc_notice_context", { p_contract: u.contract_id, p_sender_email: agent?.email || "", p_as_of: day, p_cure_deadline: cure });
      const filled = fillTemplate(tpl.html, ctx);
      if (filled.missing.length) problems.push(`blank: ${filled.missing.join(", ")}`);
      const { error: e } = await admin.from("notices").insert({ land_contract_id: u.contract_id, template_id: tpl.id, template_name: tpl.name, subject: tpl.subject,
        html: filled.html, sent_by: "rent cycle", status: "draft", batch: `${day.slice(0, 7)} land contract default`, emailed_to: [], cure_deadline: cure });
      if (e) { problems.push(e.message); continue; }
      n++;
      for (const b of u.buyers || []) if (b.email) await sendEmail({ to: b.email, subject: "Land contract payment past due: notice of default",
        html: `<p>Hi ${escapeHtml(b.name.split(/\s+/)[0])},</p><p>Your land contract payment for ${escapeHtml(u.property)} is more than ${escapeHtml(s.lc_default_days || "10")} days past due, so the contract is in default. A written Notice of Default and Right to Cure is being mailed to you.</p>
          <p><b>Amount to cure: ${money(Number(u.total))}</b> by <b>${pretty(cure)}</b>. Pay in your <a href="${portal()}">resident portal</a>, or call (262) 236-5443 to talk about a plan.</p><p>2nd Chance Housing</p>` });
    }
    if (n && agent) await sendEmail({ to: agent.email, subject: `${n} land contract default notice(s) ready to sign and mail`,
      html: `<p>${n} Notice(s) of Default and Right to Cure are ready. Sign them on the Notices page and mail them today (certified mail or hand delivery):</p><p><a href="${new URL("/documents/notices/", PORTAL_BASE_URL)}">Open Notices</a></p>` });
    return { drafts: n, cure_deadline: cure, problems };
  },

  // Royal Orleans association (20261026000000_association_dues.sql).
  async condo_dues(day: string) { const { data, error } = await admin.rpc("condo_billing_post_month", { p_month: day }); if (error) throw error; return data; },

  // Late fees on the flat-fee and percentage days; on the flat-fee day, one
  // past-due email per owner (all their units) and a digest to staff.
  async condo_late(day: string) {
    const s = await settings();
    const { data: fees, error } = await admin.rpc("condo_post_late_fees", { p_day: day });
    if (error) throw error;
    if (Number(day.slice(8, 10)) !== Number(s.dues_late_flat_day || 10)) return fees;
    const { data: rows, error: pdErr } = await admin.rpc("condo_past_due", { p_as_of: day });
    if (pdErr) throw pdErr;
    type Row = { unit_number: string; address: string; owner_name: string; email: string | null; balance: number };
    const byOwner = new Map<string, Row[]>();
    for (const r of (rows || []) as Row[]) byOwner.set(r.owner_name, [...(byOwner.get(r.owner_name) || []), r]);
    let emailed = 0;
    if ((s.dues_past_due_email || "on") === "on") {
      for (const [name, units] of byOwner) {
        const to = units[0].email;
        if (!to) continue;
        // The owner's "email me when past due" choice, except a balance more than 60 days old is always emailed.
        const { data: okToEmail } = await admin.rpc("condo_past_due_email_ok", { p_email: to, p_as_of: day });
        if (okToEmail === false) continue;
        const total = units.reduce((t, u) => t + Number(u.balance), 0);
        await sendEmail({ to, subject: "Royal Orleans association dues past due", html: `<p>Hi ${escapeHtml(name.split(/\s+/)[0])},</p>
          <p>Your Royal Orleans Condominium association account is past due:</p>
          <ul>${units.map((u) => `<li>Unit ${escapeHtml(u.unit_number)} (${escapeHtml(u.address)}): <b>${money(Number(u.balance))}</b></li>`).join("")}</ul>
          ${units.length > 1 ? `<p>Total: <b>${money(total)}</b></p>` : ""}
          <p>A ${money(Number(s.dues_late_flat || 25))} late fee was added today, and interest of ${s.dues_interest_annual_pct || "4.5"}% a year (simple, on unpaid dues only) is added tomorrow if they are still unpaid.</p>
          <p>${escapeHtml(s.dues_pay_instructions || "")}</p>
          <p>See every charge and payment in your <a href="${PORTAL_BASE_URL}">owner portal</a>. Questions or a payment plan: call ${escapeHtml(s.org_phone || s.office_phone || "the office")}.</p>
          <p>Royal Orleans Condominium – Addition One<br>managed by 2nd Chance Housing</p>` });
        emailed++;
      }
    }
    const list = ((rows || []) as Row[]).map((u) => `<tr><td>Unit ${escapeHtml(u.unit_number)}</td><td>${escapeHtml(u.owner_name)}</td><td style="text-align:right">${money(Number(u.balance))}</td><td>${u.email ? "" : "no email on file"}</td></tr>`).join("");
    if (rows?.length) await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: `Association dues: ${rows.length} unit(s) past due`,
      html: `<p>Past due after the ${Number(day.slice(8, 10)) - 1}th, with late fees posted:</p><table cellpadding="4">${list}</table><p><a href="${new URL("/association-owners/roca1/dues/", PORTAL_BASE_URL)}">Open Association dues</a></p>` });
    return { ...fees, past_due: rows?.length || 0, owners_emailed: emailed };
  },

  async lc_cure_ended(day: string) {
    const s = await settings();
    const { data: due } = await admin.from("notices").select("id, land_contract_id, cure_deadline").not("land_contract_id", "is", null).eq("cure_deadline", addDays(day, -1));
    const { data: rows } = await admin.rpc("lc_unpaid", { p_as_of: day });
    let n = 0;
    for (const notice of due || []) {
      const u = (rows || []).find((r: any) => r.contract_id === notice.land_contract_id);
      if (!u) continue;   // cured
      n++;
      for (const b of u.buyers || []) if (b.email) await sendEmail({ to: b.email, subject: "Land contract default not cured: what happens next",
        html: `<p>Hi ${escapeHtml(b.name.split(/\s+/)[0])},</p><p>The cure period in your Notice of Default ended on ${pretty(notice.cure_deadline)}, and <b>${money(Number(u.total))}</b> is still unpaid for ${escapeHtml(u.property)}.</p>
          <p>${escapeHtml(s.lc_foreclosure_text || "")}</p><p>You can still pay the full past-due amount. Call (262) 236-5443 right away.</p><p>2nd Chance Housing</p>` });
      await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: `Land contract default not cured — ${u.property}`,
        html: `<p>The cure period for ${escapeHtml(u.property)} ended ${pretty(notice.cure_deadline)}. ${money(Number(u.total))} is still unpaid. Decide whether to accelerate the balance and file for strict foreclosure (Milwaukee County Circuit Court).</p>` });
    }
    return { uncured: n };
  },

  async agent_reminder(day: string) {
    const list = await unpaid(day), second = addDays(day, 2);
    const rows = list.map((u) => `<li>Unit ${escapeHtml(u.unit_label)} — ${escapeHtml(u.tenants.map((t) => t.name).join(", "))}: ${money(u.rent_due)} unpaid rent${u.pending_reported ? ` (${money(u.pending_reported)} reported, being verified)` : ""}</li>`).join("");
    for (const a of await agents()) await sendEmail({ to: a.email, subject: `Reminder: ${pretty(second)} is a work and post office day`,
      html: `<p>Hi ${escapeHtml(a.name.split(/\s+/)[0])},</p><p>The 2nd (${pretty(second)}) is a scheduled work day, including a post office trip for any pay-or-vacate notices (certified mail).</p>
        <p>Currently unpaid (before the 1st's rent posts):</p>${rows ? `<ul>${rows}</ul>` : "<p>Nobody.</p>"}<p>On the 2nd, the notices will be ready to sign and print on the Notices page.</p>` });
    return { unpaid: list.length };
  },

  async pay_or_vacate(day: string) {
    let warned = 0, verifying = 0;
    for (const u of await unpaid(day)) {
      if (u.pending_reported >= u.rent_due) {
        verifying += await emailTenants(u, "We're verifying your rent payment", (f) => `<p>Hi ${f},</p><p>You reported a payment of ${money(u.pending_reported)}. We're confirming it with our bank. Nothing more is needed from you unless we contact you.</p><p>2nd Chance Housing</p>`);
        continue;
      }
      const { days } = await payOrVacate(u.lease_id, day);
      warned += await emailTenants(u, "Pay or Vacate: your rent is past due", (f) => `<p>Hi ${f},</p>
        <p>Our records show <b>${money(u.rent_due - u.pending_reported)}</b> in unpaid rent for ${escapeHtml(u.address)} (account ${escapeHtml(u.account_number || "")}). Rent was due on the 1st.</p>
        <p><b>Pay now to avoid a ${days}-day notice to pay rent or vacate.</b> A written ${days}-day notice is being sent today. Pay by Zelle or another option in your <a href="${portal()}">resident portal</a>.</p>
        <p>If you already paid, send us a message in the portal with the date and amount, or call (262) 236-5443.</p><p>2nd Chance Housing</p>`);
    }
    return { pay_or_vacate_emails: warned, verifying_emails: verifying };
  },

  // A pay-or-vacate notice is never prepared while a payment is pending (a bank payment in flight, or a fresh "I've paid" report).
  // When that hold ends without the rent being paid (the bank payment failed, the report was rejected or went stale) the notice
  // is prepared right then, not on the next 2nd. Same drafts, batch, emails and agent mail as the 2nd. Once per lease per month.
  async notice_catchup(day: string, onlyLease?: string) {
    if (Number(day.slice(8, 10)) < 2) return { skipped: "rent is not late before the 2nd" };
    const batch = `${day.slice(0, 7)} pay-or-vacate notices`;
    const agent = (await agents())[0];
    let n = 0; const problems: string[] = []; const voucher: string[] = [];
    for (const u of (await unpaid(day)).filter((x) => x.pending_reported < x.rent_due && (!onlyLease || x.lease_id === onlyLease))) {
      const { data: have } = await admin.from("notices").select("id").eq("lease_id", u.lease_id).eq("batch", batch).limit(1);
      if (have?.length) continue;
      const pv = await payOrVacate(u.lease_id, day, agent?.email || "");
      if (/\[\[(?!SIGNATURE\]\]|FIRST\]\])[A-Za-z0-9_]+\]\]/.test(pv.html)) problems.push(`${u.address}: a field is still blank`);
      const { error } = await admin.from("notices").insert({ lease_id: u.lease_id, template_id: pv.template_id, template_name: pv.template_name, subject: pv.subject,
        html: pv.html, email_subject: pv.email_subject, email_html: pv.email_html, sent_by: "rent cycle", status: "draft", batch, emailed_to: [], signed_by_agent: false });
      if (error) { problems.push(error.message); continue; }
      n++;
      if (pv.federal_program === "section8") voucher.push(`Unit ${escapeHtml(u.unit_label)} — ${escapeHtml(u.tenants.map((t) => t.name).join(", "))}`);
      await emailTenants(u, "Pay or Vacate: your rent is past due", (f) => `<p>Hi ${f},</p>
        <p>Our records show <b>${money(u.rent_due - u.pending_reported)}</b> in unpaid rent for ${escapeHtml(u.address)} (account ${escapeHtml(u.account_number || "")}). Rent was due on the 1st, and the payment we were waiting on did not clear.</p>
        <p><b>Pay now to avoid a ${pv.days}-day notice to pay rent or vacate.</b> A written ${pv.days}-day notice is being sent. Pay by Zelle or another option in your <a href="${portal()}">resident portal</a>.</p>
        <p>If you already paid, send us a message in the portal with the date and amount, or call (262) 236-5443.</p><p>2nd Chance Housing</p>`);
    }
    if (n && agent) await sendEmail({ to: agent.email, subject: `${n} pay-or-vacate notice(s) ready to sign and send`,
      html: `<p>${n} notice(s) are ready because a pending payment did not clear. Sign in, sign, print, and send by certified mail. The deadline counts from the mailing day.</p>
        ${voucher.length ? `<p><b>Section 8 tenancies (30-day notices):</b> also send a copy of each to the housing authority:</p><ul>${voucher.map((v) => `<li>${v}</li>`).join("")}</ul>` : ""}
        <p><a href="${new URL("/documents/notices/", PORTAL_BASE_URL)}">Open Notices</a></p>` });
    return { drafts: n, section8: voucher.length, problems };
  },

  // Late fee (the lease's late_fee, $75 by default) on rent still unpaid with no payment pending. Once per lease per month. Runs daily from the
  // 2nd, so a fee held back while a payment was pending posts the day that payment fails, is returned, or a chargeback is lost.
  async late_fees(day: string) {
    const { data, error } = await admin.rpc("rent_late_fees", { p_day: day });
    if (error) throw error;
    const posted = (data?.posted || []) as { lease_id: string; amount: number }[];
    if (!posted.length) return { late_fees: 0 };
    const byLease = new Map((await unpaid(day)).map((u) => [u.lease_id, u]));
    let emailed = 0;
    for (const p of posted) {
      const u = byLease.get(p.lease_id); if (!u) continue;
      emailed += await emailTenants(u, "A late fee was added to your account", (f) => `<p>Hi ${f},</p>
        <p>Rent of <b>${money(u.rent_due)}</b> for ${escapeHtml(u.address)} was due on the 1st and has not been paid, so a late fee of <b>${money(p.amount)}</b> was added to your account, as your lease provides.</p>
        <p>Pay in your <a href="${portal()}">resident portal</a> (bank account, Zelle or another option shown there). If you already paid, send us a message in the portal with the date and amount, or call (262) 236-5443.</p><p>2nd Chance Housing</p>`);
    }
    return { late_fees: posted.length, emailed };
  },

  async five_day_drafts(day: string) {
    const list = (await unpaid(day)).filter((u) => u.pending_reported < u.rent_due);
    const agent = (await agents())[0];
    const batch = `${day.slice(0, 7)} pay-or-vacate notices`;
    let n = 0; const problems: string[] = []; const voucher: string[] = [];
    for (const u of list) {
      const { data: have } = await admin.from("notices").select("id").eq("lease_id", u.lease_id).eq("batch", batch).limit(1);
      if (have?.length) continue;   // already prepared (e.g. by notice_catchup)
      const pv = await payOrVacate(u.lease_id, day, agent?.email || "");
      if (/\[\[(?!SIGNATURE\]\]|FIRST\]\])[A-Za-z0-9_]+\]\]/.test(pv.html)) problems.push(`${u.address}: a field is still blank`);
      const { error } = await admin.from("notices").insert({ lease_id: u.lease_id, template_id: pv.template_id, template_name: pv.template_name, subject: pv.subject,
        html: pv.html, email_subject: pv.email_subject, email_html: pv.email_html, sent_by: "rent cycle", status: "draft", batch, emailed_to: [], signed_by_agent: false });
      if (error) problems.push(error.message); else n++;
      if (pv.federal_program === "section8") voucher.push(`Unit ${escapeHtml(u.unit_label)} — ${escapeHtml(u.tenants.map((t) => t.name).join(", "))}`);
    }
    if (n && agent) await sendEmail({ to: agent.email, subject: `${n} pay-or-vacate notice(s) ready to sign and send`,
      html: `<p>${n} notice(s) to pay rent or vacate are ready. Sign in, sign them all at once, print, and send them by certified mail today. Each notice's deadline counts from today's mailing.</p>
        ${voucher.length ? `<p><b>Section 8 tenancies (30-day notices):</b> also send a copy of each of these to the housing authority:</p><ul>${voucher.map((v) => `<li>${v}</li>`).join("")}</ul>` : ""}
        <p><a href="${new URL("/documents/notices/", PORTAL_BASE_URL)}">Open Notices</a></p>` });
    return { drafts: n, section8: voucher.length, problems };
  },

  // 12:01 am on the 2nd is a staff work day. One email to every agent with the whole
  // day's mailings: who gets a certified notice, how much each owes, and the post office
  // trip. It is sent even when there is nothing to mail, so the day is never a surprise.
  async mailing_day(day: string) {
    const s = await settings();
    const list = await unpaid(day);
    const owing = list.filter((u) => u.pending_reported < u.rent_due);
    const verifying = list.filter((u) => u.pending_reported >= u.rent_due);
    const rows: string[] = []; let section8 = 0;
    for (const u of owing) {
      const tl = await evictionTimeline(u.lease_id, day, s);
      if (tl.days !== 5) section8++;
      rows.push(`<tr><td>Unit ${escapeHtml(u.unit_label)}</td><td>${escapeHtml(u.tenants.map((t) => t.name).join(", "))}</td>
        <td style="text-align:right">${money(u.rent_due - u.pending_reported)}</td><td>${tl.days}-day, ends ${pretty(tl.noticeEnd)}</td>
        <td>file ${pretty(tl.filing)}<br>court ${pretty(tl.court)}<br>writ ${pretty(tl.writ)}<br>sheriff ~${pretty(tl.sheriff)}</td></tr>`);
    }
    // Rent increases: month-to-month changes that are scheduled but whose notice has not gone out.
    // A change effective on the 1st needs the notice mailed at least 28 days before.
    const { data: rcs } = await admin.from("lease_rent_changes")
      .select("id, new_rent, effective_on, notice_id, leases!inner(rent, rental_units(address, unit_number), lease_tenants(tenants(name)))")
      .eq("reason", "rent_change").is("applied_at", null).is("canceled_at", null).order("effective_on");
    const incRows: string[] = []; let incToSend = 0, incLate = 0;
    for (const c of (rcs || []) as any[]) {
      const unit = c.leases?.rental_units, who = (c.leases?.lease_tenants || []).map((x: any) => x.tenants?.name).filter(Boolean).join(", ");
      const mailBy = addDays(c.effective_on, -28);
      const state = c.notice_id ? "notice sent" : day > mailBy ? "<b>TOO LATE: set a new start date</b>" : "<b>send the notice today</b>";
      if (!c.notice_id) { if (day > mailBy) incLate++; else incToSend++; }
      incRows.push(`<tr><td>Unit ${escapeHtml(unit?.unit_number || unit?.address || "")}</td><td>${escapeHtml(who)}</td><td style="text-align:right">${money(Number(c.leases?.rent))} → ${money(Number(c.new_rent))}</td>
        <td>${pretty(c.effective_on)}</td><td>${state}${c.notice_id ? "" : ` (mail by ${pretty(mailBy)})`}</td></tr>`);
    }
    const notices = new URL("/documents/notices/", PORTAL_BASE_URL).toString();
    const renewals = new URL("/leasing/renewals/", PORTAL_BASE_URL).toString();
    const noticeBlock = owing.length
      ? `<h3>Pay-or-vacate notices: ${owing.length} to mail by certified mail</h3>
         <p>They are already drafted: open Notices, sign them all at once, print, and take them to the post office. Each notice's deadline counts from today's mailing.</p>
         <table cellpadding="6" style="border-collapse:collapse" border="1"><tr><th>Unit</th><th>Tenant(s)</th><th>Rent owed</th><th>Notice</th><th>If it stays unpaid (projected)</th></tr>${rows.join("")}</table>
         ${section8 ? `<p><b>${section8} Section 8 / federal tenancy(ies):</b> 30-day notice; also send a copy to the housing authority.</p>` : ""}
         <p>Past-due emails went to these tenants at 12:01 am. Tomorrow they get the second notice with the same sequence of dates.</p>`
      : `<h3>Pay-or-vacate notices</h3><p>Nothing to mail today. Every tenant is paid up or has a reported payment waiting to be verified.</p>`;
    const rentBlock = incRows.length
      ? `<h3>Rent increases</h3><table cellpadding="6" style="border-collapse:collapse" border="1"><tr><th>Unit</th><th>Tenant(s)</th><th>Rent</th><th>Takes effect</th><th>Status</th></tr>${incRows.join("")}</table>
         <p>Notices must go out at least 28 days before the 1st they take effect. <a href="${renewals}">Open Renewals</a> to schedule or change one.</p>`
      : `<h3>Rent increases</h3><p>None scheduled.</p>`;
    const verifyNote = verifying.length ? `<p>Waiting on bank verification (no notice sent): ${verifying.map((u) => `Unit ${escapeHtml(u.unit_label)} (${money(u.pending_reported)} reported)`).join(", ")}. Match these in Payments.</p>` : "";
    const total = owing.length + incToSend;
    for (const a of await agents()) await sendEmail({ to: a.email,
      subject: total || incLate ? `Mailing day: ${owing.length} notice(s), ${incToSend} rent increase(s) to mail${incLate ? ` (${incLate} too late)` : ""}` : "Mailing day: nothing to mail today",
      html: `<p>Hi ${escapeHtml(a.name.split(/\s+/)[0])},</p><p>Today, ${pretty(day)}, is a work day.</p>${noticeBlock}${rentBlock}${verifyNote}<p><a href="${notices}">Open Notices</a></p>` });
    return { owing: owing.length, verifying: verifying.length, section8, rent_increases_to_send: incToSend, rent_increases_late: incLate };
  },

  async process_email(day: string) {
    const s = await settings();
    const served = addDays(day, -1);                       // the notices are mailed on the 2nd
    let n = 0; const ends: Record<string, string> = {};
    for (const u of (await unpaid(day)).filter((x) => x.pending_reported < x.rent_due)) {
      const tl = await evictionTimeline(u.lease_id, served, s);   // this lease's own notice period (5 or 30 days)
      ends[u.unit_label] = tl.noticeEnd;
      n += await emailTenants(u, "What happens next if rent stays unpaid", (f) => `<p>Hi ${f},</p>
        <p>Rent of <b>${money(u.rent_due - u.pending_reported)}</b> for ${escapeHtml(u.address)} is still unpaid. A ${tl.days}-day notice to pay rent or vacate was sent to you on ${pretty(served)}. Here is what happens if it stays unpaid:</p>
        <ul><li><b>The notice ends:</b> ${pretty(tl.noticeEnd)}</li><li><b>Eviction case filed:</b> ${pretty(tl.filing)}</li>
        <li><b>Expected court date:</b> ${pretty(tl.court)} (usually 14 days after filing; the court sets the actual date)</li>
        <li><b>Writ decision:</b> ${pretty(tl.writ)} (if the court grants judgment, a writ of restitution is requested)</li>
        <li><b>Sheriff:</b> about ${pretty(tl.sheriff)} (typically 10 days after the writ is filed)</li>
        <li><b>If a writ is granted:</b> ${escapeHtml(s.writ_text || "")}</li></ul>
        <p><b>You can stop this by paying the full unpaid rent before the notice ends.</b> Pay in your <a href="${portal()}">resident portal</a>, or call (262) 236-5443 to talk about it.</p><p>2nd Chance Housing</p>`);
    }
    return { process_emails: n, notice_ends: ends };
  },
};

const sendOutbox = () => flushOutbox(admin);

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (!SECRET || req.headers.get("x-cycle-secret") !== SECRET) return new Response("Unauthorized", { status: 401 });
  try {
    // Master switch: nothing runs (no billing, no notices, no emails) until portal_settings.automation_mode is "live".
    if (!IS_LOCAL && ((await settings()).automation_mode || "off") !== "live") return new Response(JSON.stringify({ skipped: "automation_mode is off" }), { status: 200, headers: { "Content-Type": "application/json" } });
    const body = await req.json().catch(() => ({}));
    const day = IS_LOCAL && /^\d{4}-\d{2}-\d{2}$/.test(body.as_of || "") ? body.as_of : chicagoToday();
    const d = Number(day.slice(8, 10));
    // A pending payment just failed (called by stripe-webhook): act now instead of waiting for the next daily run.
    if (body.action === "catchup") {
      const notices = await jobs.notice_catchup(day, typeof body.lease_id === "string" ? body.lease_id : undefined);
      const { data: fees, error: fErr } = await admin.rpc("condo_post_late_fees", { p_day: day }); if (fErr) throw fErr;
      const tenantFees = await jobs.late_fees(day);
      return Response.json({ day, notices, tenant_late_fees: tenantFees, late_fees: fees, outbox_sent: await sendOutbox() });
    }
    const firstOfNext = addDays(day.slice(0, 8) + "01", 32).slice(0, 8) + "01";
    const ran: unknown[] = [];
    ran.push(await once("activate", day, async () => {
      const { data, error } = await admin.rpc("leases_activate_due", { p_as_of: day }); if (error) throw error;
      const { data: rc, error: rcErr } = await admin.rpc("leases_apply_rent_changes", { p_as_of: day }); if (rcErr) throw rcErr;   // Stage 7: before billing
      return { activated: data, rent_changes: rc };
    }));
    ran.push(await once("renewals", day, async () => { const { data, error } = await admin.rpc("renewals_daily", { p_as_of: day }); if (error) throw error; return data; }));
    // Stage 8: move-out reminders, 21-day deposit deadline warnings, and removing
    // former tenants' sign-ins when their read-only window (28 / 60 days) ends.
    ran.push(await once("move_outs", day, async () => {
      const { data, error } = await admin.rpc("moveouts_daily", { p_as_of: day }); if (error) throw error;
      const removed: string[] = [];
      for (const id of (data?.remove_user_ids || []) as string[]) {
        const { error: dErr } = await admin.auth.admin.deleteUser(id);
        if (!dErr) removed.push(id); else console.error("rent-cycle: could not remove sign-in", id, dErr.message);
      }
      return { ...data, remove_user_ids: undefined, sign_ins_removed: removed.length };
    }));
    if (d === 1) ran.push(await once("billing", day, () => jobs.billing(day), true));   // posts only the missing charges, so a retry is safe
    // Housing-assistance agencies set to "auto payment" (e.g. CVI): right after billing has posted each rent charge and the agency share,
    // post the agency's expected payment on the agency ledger and email the office to verify it. Posts only what is missing, so a retry is safe.
    if (d === 1) ran.push(await once("agency_payments", day, async () => { const { data, error } = await admin.rpc("assistance_auto_post", { p_day: day }); if (error) throw error; return data; }, true));
    ran.push(await once("autopay_reminders", day, () => jobs.autopay_reminders(day)));   // reminders go out before the withdrawal job below, every day
    if (d >= 1 && d <= 5) ran.push(await once("autopay", day, () => jobs.autopay(day)));   // withdrawals happen only on the day each tenant chose (1st to 5th)
    if (day === addDays(firstOfNext, -3)) ran.push(await once("reminder", day, () => jobs.reminder(day)));
    if (day === addDays(firstOfNext, 0 - 1)) ran.push(await once("agent_reminder", day, () => jobs.agent_reminder(day)));   // 2 days before the 2nd
    if (d === 2) { ran.push(await once("pay_or_vacate", day, () => jobs.pay_or_vacate(day))); ran.push(await once("five_day_drafts", day, () => jobs.five_day_drafts(day))); ran.push(await once("mailing_day", day, () => jobs.mailing_day(day))); }
    if (d >= 2) ran.push(await once("late_fees", day, () => jobs.late_fees(day)));   // tenants: unpaid with nothing pending (also the day a pending payment fails)
    if (d >= 3) ran.push(await once("notice_catchup", day, () => jobs.notice_catchup(day)));   // notices that were held while a payment was pending
    if (d === 3) ran.push(await once("process_email", day, () => jobs.process_email(day)));
    // Stage 6: remind staff to record next month's rule letter if it isn't sent yet.
    if (d === 25) ran.push(await once("letter_reminder", day, async () => { const { data, error } = await admin.rpc("letters_due_reminder", { p_as_of: day }); if (error) throw error; return data; }));
    const lcDays = Number((await settings()).lc_default_days || 10);
    if (d === 1 + lcDays) ran.push(await once("lc_default", day, () => jobs.lc_default(day)));
    ran.push(await once("lc_cure_ended", day, () => jobs.lc_cure_ended(day)));
    if (d === 1) ran.push(await once("condo_dues", day, () => jobs.condo_dues(day), true));   // posts only the missing dues, so a retry is safe
    ran.push(await once("condo_late", day, () => jobs.condo_late(day)));   // only acts on the late-fee days
    ran.push(await once("condo_goodwill", day, async () => { const { data, error } = await admin.rpc("condo_goodwill_credits", { p_day: day }); if (error) throw error; return data; }));   // owner goodwill credit, the day after interest (20261112030000)
    ran.push(await once("payments_stale", day, async () => { const { data, error } = await admin.rpc("payments_stale_pending", { p_as_of: day }); if (error) throw error; return data; }));
    // ROCA1 board business: close ended votes, post adopted assessments/fines, propose liens, rent deductions (20261106060000+).
    ran.push(await once("roca_automation", day, async () => { const { data, error } = await admin.rpc("roca_automation_run", { p_today: day }); if (error) throw error; return data; }));
    const sent = await sendOutbox();
    return Response.json({ day, ran, outbox_sent: sent });
  } catch (err) {
    console.error("rent-cycle: error", err instanceof Error ? err.stack || err.message : String(err));
    await sendOutbox().catch(() => 0);   // emails already queued (reminders, notices) still go out when a later job fails
    try { await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "Rent cycle error", html: `<p>The daily rent cycle hit an error: ${escapeHtml(err instanceof Error ? err.message : String(err))}</p>` }); } catch { /* ignore */ }
    return new Response("error", { status: 500 });
  }
});
