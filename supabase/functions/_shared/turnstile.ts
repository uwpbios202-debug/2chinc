// Cloudflare Turnstile check for public edge functions. Enforced only when the TURNSTILE_SECRET_KEY
// function secret is set, so the check can be switched on or off without a code change.
const SECRET = Deno.env.get("TURNSTILE_SECRET_KEY") || "";

export async function turnstileOk(token: unknown, req: Request): Promise<boolean> {
  if (!SECRET) return true;
  const t = typeof token === "string" ? token.slice(0, 2048) : "";
  if (!t) return false;
  const form = new URLSearchParams({ secret: SECRET, response: t });
  const ip = req.headers.get("cf-connecting-ip");
  if (ip) form.set("remoteip", ip);
  try {
    const r = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: form });
    const j = await r.json();
    return j.success === true;
  } catch (e) {
    console.error("turnstile: verify call failed", e instanceof Error ? e.message : String(e));
    return false;   // fail closed
  }
}
