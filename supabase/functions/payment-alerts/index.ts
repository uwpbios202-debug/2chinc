// Payment-alert emails -> bank_receipts -> auto-match tenant payment reports.
//
// Point the "money received" alerts at the inbound address (Chase alerts can
// be sent to any email; Cash App / PayPal alerts are forwarded by a mail rule).
// The inbound email service posts each message here as JSON
// ({ from, subject, text, html, date }) with header x-alert-secret.
//
// Only alerts from the payment services' own domains are accepted. An alert is a CONFIRMATION only: it marks a
// tenant's or owner's "I've paid" as "bank alert seen" but never posts money. Money posts when the bank's own record
// arrives (Plaid, or the CSV until Plaid is linked). Each alert is routed to Chase (2nd Chance) or First Citizens
// (ROCA1) by the bank_alert_routes setting (e.g. ROCA1's "rocaone" Zelle).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { flushOutbox } from "../_shared/mail.ts";

const SECRET = Deno.env.get("PAYMENT_ALERT_SECRET") || "";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const SENDERS: [RegExp, string][] = [
  [/@([a-z0-9-]+\.)*chase\.com>?$/i, "Chase"],
  [/@([a-z0-9-]+\.)*(cash\.app|square\.com|squareup\.com)>?$/i, "Cash App"],
  [/@([a-z0-9-]+\.)*paypal\.com>?$/i, "PayPal"],
];

export function parseAlert(subject: string, text: string) {
  const body = `${subject}\n${text}`.replace(/ /g, " ").replace(/[ \t]+/g, " ");
  // Only "money received" alerts; skip "you sent", statements, promos.
  if (!/(received|sent you|you've got money|deposited|payment from)/i.test(body) || /\byou sent\b/i.test(subject)) return null;
  const amt = /\$\s?([\d,]+(?:\.\d{2})?)/.exec(body);
  if (!amt) return null;
  const amount = Number(amt[1].replace(/,/g, ""));
  const name =
    /([A-Z][A-Za-z'.-]+(?: [A-Z][A-Za-z'.-]+){0,3}) sent you \$/.exec(body)?.[1] ||
    /(?:received|payment) (?:\$[\d,.]+ )?from ([A-Z][A-Za-z'.-]+(?: [A-Z][A-Za-z'.-]+){0,3})/i.exec(body)?.[1] ||
    /from:? ([A-Z][A-Za-z'.-]+(?: [A-Z][A-Za-z'.-]+){1,3})\b/.exec(text)?.[1] || null;
  const memo = /(?:memo|note|message|for)[:\s]+"?([^\n"]{2,80})/i.exec(text)?.[1]?.trim() || null;
  const ref = /(?:transaction (?:id|number)|confirmation(?: (?:number|code))?|reference)[:#\s]+([A-Z0-9-]{5,40})/i.exec(body)?.[1] || null;
  return { amount, payer_name: name, memo, reference: ref };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (!SECRET || req.headers.get("x-alert-secret") !== SECRET) return new Response("Unauthorized", { status: 401 });
  try {
    const m = await req.json();
    const from = String(m.from || "").trim();
    const service = SENDERS.find(([re]) => re.test(from))?.[1];
    if (!service) return Response.json({ skipped: "sender not accepted" });
    const subject = String(m.subject || ""), text = String(m.text || String(m.html || "").replace(/<[^>]+>/g, " "));
    const p = parseAlert(subject, text);
    if (!p || !(p.amount > 0)) return Response.json({ skipped: "not a money-received alert" });
    const posted = new Date(m.date || Date.now()).toISOString().slice(0, 10);
    const description = [service, p.payer_name, p.memo].filter(Boolean).join(" · ");
    const fingerprint = `email_alert|${service}|${posted}|${p.amount}|${p.reference || p.payer_name || subject}`;
    const { error } = await admin.from("bank_receipts").insert({
      source: "email_alert", account: service, posted_on: posted, amount: p.amount, description, payer_name: p.payer_name,
      reference: p.reference, fingerprint, raw: { from, to: String(m.to || ""), subject, memo: p.memo, excerpt: text.slice(0, 600) },
    });
    if (error && !String(error.message).includes("duplicate")) throw error;
    const { data: matched } = await admin.rpc("payments_auto_match");
    if (matched) await flushOutbox(admin);   // receipts, "keys can be released"
    return Response.json({ recorded: !error, matched });
  } catch (err) {
    console.error("payment-alerts: error", err instanceof Error ? err.message : String(err));
    return new Response("error", { status: 500 });
  }
});
