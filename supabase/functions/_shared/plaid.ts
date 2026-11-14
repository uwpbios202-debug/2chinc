// Plaid helpers for the bank feed. Pure functions (toReceipt, payerFrom) are unit-tested without Plaid.
// Plaid reports money OUT as positive amounts and money IN as negative amounts; we flip that so deposits are positive.

export type PlaidTxn = {
  transaction_id: string; account_id: string; amount: number; date: string; authorized_date?: string | null; pending: boolean;
  name?: string | null; merchant_name?: string | null; original_description?: string | null; payment_channel?: string | null;
  counterparties?: { name?: string | null; type?: string | null }[] | null;
  personal_finance_category?: { primary?: string | null; detailed?: string | null } | null;
  payment_meta?: { payer?: string | null; payee?: string | null; reference_number?: string | null; payment_processor?: string | null } | null;
};

const clean = (s: unknown) => String(s ?? "").replace(/\s+/g, " ").trim();

// Best guess at who sent the money: Plaid's counterparty, then payment_meta, then a "from NAME" in the bank's description.
export function payerFrom(t: PlaidTxn): string {
  const cp = (t.counterparties || []).find((c) => c?.name && /^(financial_institution|marketplace|payment_terminal|person)?$/i.test(String(c.type || "")) ) || (t.counterparties || [])[0];
  if (cp?.name) return clean(cp.name);
  if (t.payment_meta?.payer) return clean(t.payment_meta.payer);
  const text = `${t.original_description || ""} ${t.name || ""}`;
  const m = /(?:from|by)\s+([A-Za-z][A-Za-z'.-]+(?:\s+[A-Za-z][A-Za-z'.-]+){0,3})/i.exec(text);
  if (m) return clean(m[1].split(/\s+/).filter((w, i, arr) => !/^(unit|apt|apartment|rent|dues|for|memo|ref|payment|zelle)$/i.test(w) && arr.slice(0, i).every((x) => !/^(unit|apt|apartment|rent|dues|for|memo|ref)$/i.test(x))).join(" "));
  return clean(t.merchant_name || "");
}

// Turn a Plaid transaction into a bank_receipts row (posted transactions only; pending ones are picked up when they post).
export function toReceipt(t: PlaidTxn, bankAccountId: string) {
  if (t.pending) return null;
  const amount = Math.round(-Number(t.amount) * 100) / 100;     // money in = positive
  const description = clean([t.original_description, t.name].filter((x, i, a) => x && a.indexOf(x) === i).join(" | "));
  return {
    source: "plaid", bank_account_id: bankAccountId, provider_id: t.transaction_id, posted_on: t.authorized_date || t.date, amount,
    description, payer_name: amount > 0 ? payerFrom(t) : null, reference: clean(t.payment_meta?.reference_number || ""),
    fingerprint: "plaid|" + t.transaction_id,
    raw: { id: t.transaction_id, name: t.name, original: t.original_description, channel: t.payment_channel, category: t.personal_finance_category?.detailed || null },
  };
}

// AES-256-GCM for the access token: "v1:" + base64(iv || ciphertext). The key lives only in the function's secrets.
export async function encryptToken(plain: string, keyB64: string) {
  const key = await crypto.subtle.importKey("raw", Uint8Array.from(atob(keyB64), (c) => c.charCodeAt(0)), "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(plain)));
  const all = new Uint8Array(iv.length + ct.length); all.set(iv); all.set(ct, iv.length);
  return "v1:" + btoa(String.fromCharCode(...all));
}
export async function decryptToken(enc: string, keyB64: string) {
  const all = Uint8Array.from(atob(enc.replace(/^v1:/, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("raw", Uint8Array.from(atob(keyB64), (c) => c.charCodeAt(0)), "AES-GCM", false, ["decrypt"]);
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: all.slice(0, 12) }, key, all.slice(12)));
}

export function plaidBase(env: string) {
  return env === "production" ? "https://production.plaid.com" : env === "development" ? "https://development.plaid.com" : "https://sandbox.plaid.com";
}
export async function plaidCall(base: string, path: string, body: Record<string, unknown>, clientId: string, secret: string) {
  const r = await fetch(base + path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ client_id: clientId, secret, ...body }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`Plaid ${path} failed: ${j.error_code || r.status} ${j.error_message || ""}`.trim());
  return j;
}
