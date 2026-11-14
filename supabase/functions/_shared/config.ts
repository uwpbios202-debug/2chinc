// Settings shared by 2nd Chance Housing's edge functions. Everything that
// differs between local development and the live 2ndchinc.org site comes
// from environment variables (supabase/functions/.env locally, `supabase
// secrets set` in production) — nothing here needs editing at launch.

export const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
export const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Where the owner portal lives, with a trailing slash.
export const PORTAL_BASE_URL = Deno.env.get("PORTAL_BASE_URL") || "http://localhost:8000/owners/";

export const MAIL_FROM = Deno.env.get("MAIL_FROM") || "2nd Chance Housing <info@2ndchinc.org>";
export const MAIL_REPLY_TO = Deno.env.get("MAIL_REPLY_TO") || "info@2ndchinc.org";
// Who receives "owner updated their details" alerts.
export const STAFF_NOTIFY_EMAIL = Deno.env.get("STAFF_NOTIFY_EMAIL") || "info@2ndchinc.org";

// Browser origins allowed to call functions directly (the portal pages).
export const ALLOWED_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") || "http://localhost:8000,http://127.0.0.1:8000,https://2ndchinc.org")
  .split(",").map((s) => s.trim()).filter(Boolean);

// True only when running under `supabase start` on this machine. Dev-only
// shortcuts (printing emails instead of sending, the fixed text code) are
// gated on this so they can never switch on in production.
export const IS_LOCAL = /^http:\/\/(kong|localhost|127\.0\.0\.1|host\.docker\.internal)(:\d+)?/.test(SUPABASE_URL || "");

export function cors(req: Request) {
  const origin = req.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
}

export function escapeHtml(s: unknown) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));
}
