// Minimal Stripe REST client (form-encoded, no SDK) and webhook signature check.
// Three Stripe accounts: "main" (2nd Chance Housing Inc, STRIPE_SECRET_KEY), "yawdcour" (Yawdcour LLC, paying out to its
// own Chase account, STRIPE_SECRET_KEY_YAWDCOUR) and "roca1" (ROCA1, paying out to its First Citizens account, STRIPE_SECRET_KEY_ROCA1). Ids from Stripe are unique across accounts, so rows are not tagged by account
// except stripe_customers.stripe_account (which account a tenant's customer lives in).
const STRIPE_SECRET_KEYS: Record<string, string> = { main: Deno.env.get("STRIPE_SECRET_KEY") || "", yawdcour: Deno.env.get("STRIPE_SECRET_KEY_YAWDCOUR") || "", roca1: Deno.env.get("STRIPE_SECRET_KEY_ROCA1") || "" };

function encode(params: Record<string, unknown>, prefix = "", out: string[] = []) {
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (Array.isArray(v)) v.forEach((item, i) => typeof item === "object" ? encode(item as Record<string, unknown>, `${key}[${i}]`, out) : out.push(`${encodeURIComponent(`${key}[]`)}=${encodeURIComponent(String(item))}`));
    else if (typeof v === "object") encode(v as Record<string, unknown>, key, out);
    else out.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(v))}`);
  }
  return out;
}

export async function stripe(method: "GET" | "POST", path: string, params: Record<string, unknown> = {}, idempotencyKey?: string, account = "main") {
  const STRIPE_SECRET_KEY = STRIPE_SECRET_KEYS[account] || "";
  if (!STRIPE_SECRET_KEY) throw new Error(`The Stripe key for the "${account}" account is not set`);
  const qs = encode(params).join("&");
  const res = await fetch(`https://api.stripe.com/v1/${path}${method === "GET" && qs ? "?" + qs : ""}`, {
    method,
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET_KEY}`, "Content-Type": "application/x-www-form-urlencoded",
      ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
    },
    body: method === "POST" ? qs : undefined,
  });
  const body = await res.json().catch(() => null);
  // status on the error: 4xx = Stripe answered and refused (definite); 5xx or none (network) = the outcome is unknown.
  if (!res.ok || !body) throw Object.assign(new Error(`Stripe ${path}: ${body?.error?.message || res.status}`), { status: res.status, stripeError: body?.error || null });
  return body;
}

// Stripe-Signature: "t=<unix>,v1=<hex hmac of `${t}.${payload}`>" (5-minute tolerance).
export async function verifyStripeSignature(payload: string, header: string | null, secret: string, toleranceSec = 300) {
  if (!header || !secret) return false;
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=") as [string, string]).filter((p) => p.length === 2));
  const sigs = header.split(",").filter((p) => p.startsWith("v1=")).map((p) => p.slice(3));
  const t = Number(parts.t);
  if (!t || !sigs.length || Math.abs(Date.now() / 1000 - t) > toleranceSec) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${payload}`)));
  const hex = Array.from(mac).map((b) => b.toString(16).padStart(2, "0")).join("");
  return sigs.some((s) => s.length === hex.length && [...s].reduce((d, c, i) => d | (c.charCodeAt(0) ^ hex.charCodeAt(i)), 0) === 0);
}
