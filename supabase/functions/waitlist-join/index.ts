// Public waitlist (https://2ndchinc.org/waitlist/). verify_jwt is off, so the protections live here: honeypot, Turnstile,
// length limits and rate limits.
//   POST { email, name?, state?, bedrooms?, note?, website, turnstile } -> signs up as PENDING and emails a confirm link
//   POST { confirm: "<token>" } -> the emailed link was used: the entry becomes active (only active entries get announcements)
//   POST { leave: "<token>" } -> takes that person off the list
// Bot protection: honeypot, Turnstile, per-email and overall hourly limits, and a per-network-address daily limit. Shared
// addresses that staff have verified (shelters, libraries, caseworker offices: table waitlist_trusted_networks) get a higher limit.
// Every attempt is logged with its address for 30 days (waitlist_ip_log) so staff can spot patterns and trust an address.
// The reply never says whether an address was already on the list.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";
import { turnstileOk } from "../_shared/turnstile.ts";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const PER_IP_DAY = 10, PER_IP_DAY_TRUSTED = 200;
const clientIp = (req: Request) => (req.headers.get("cf-connecting-ip") || (req.headers.get("x-forwarded-for") || "").split(",")[0] || "unknown").trim().slice(0, 64);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const b = await req.json().catch(() => ({}));
    if (typeof b.leave === "string") {
      if (!UUID_RE.test(b.leave)) return json(req, 400, { error: "That link is not valid." });
      await admin.from("waitlist").delete().eq("token", b.leave);
      return json(req, 200, { ok: true });
    }
    if (typeof b.confirm === "string") {
      if (!UUID_RE.test(b.confirm)) return json(req, 400, { error: "That link is not valid." });
      await admin.from("waitlist").update({ status: "active", confirmed_at: new Date().toISOString() }).eq("token", b.confirm).neq("status", "active");
      return json(req, 200, { ok: true });
    }
    const ip = clientIp(req);
    if (String(b.website || "").trim() !== "") return json(req, 200, { ok: true });          // honeypot: pretend it worked
    const email = String(b.email || "").trim().toLowerCase().slice(0, 200);
    const name = String(b.name || "").trim().slice(0, 120) || null;
    const state = ["WI", "IL"].includes(String(b.state)) ? String(b.state) : "other";
    const bedrooms = ["1", "2", "3"].includes(String(b.bedrooms)) ? String(b.bedrooms) : "any";
    // "note" is a fixed choice, never free text: we do not ask about or keep anyone's past.
    const note = ["As soon as possible", "Within 1 to 3 months", "Later than 3 months", "Just looking"].includes(String(b.note)) ? String(b.note) : null;
    if (!EMAIL_RE.test(email)) return json(req, 400, { error: "Enter a full email address so we can reach you." });
    if (!(await turnstileOk(b.turnstile, req))) {
      await admin.from("waitlist_ip_log").insert({ ip, email, outcome: "bad_check" });
      return json(req, 400, { error: "The security check did not pass. Reload the page and try again." });
    }
    // Housekeeping: attempts older than 30 days and confirmations never used after 7 days.
    await admin.from("waitlist_ip_log").delete().lt("created_at", new Date(Date.now() - 30 * 86400_000).toISOString());
    await admin.from("waitlist").delete().eq("status", "pending").lt("created_at", new Date(Date.now() - 7 * 86400_000).toISOString());
    const day = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const [{ count: ipDay }, { data: trusted }] = await Promise.all([
      admin.from("waitlist_ip_log").select("id", { count: "exact", head: true }).eq("ip", ip).eq("outcome", "joined").gte("created_at", day),
      admin.from("waitlist_trusted_networks").select("id").eq("ip", ip).maybeSingle()]);
    if ((ipDay || 0) >= (trusted ? PER_IP_DAY_TRUSTED : PER_IP_DAY)) {
      await admin.from("waitlist_ip_log").insert({ ip, email, outcome: "blocked" });
      return json(req, 429, { error: "Too many sign-ups came from this connection today. Please call (262) 236-5443 and we will add you." });
    }
    const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const [{ count: mine }, { count: all }] = await Promise.all([
      admin.from("waitlist").select("id", { count: "exact", head: true }).ilike("email", email).gte("created_at", since),
      admin.from("waitlist").select("id", { count: "exact", head: true }).gte("created_at", since)]);
    if ((mine || 0) >= 3 || (all || 0) >= 100) return json(req, 429, { error: "Please call (262) 236-5443 or try again in an hour." });
    const { data: ex } = await admin.from("waitlist").select("id, token, status").ilike("email", email).maybeSingle();
    let token: string;
    await admin.from("waitlist_ip_log").insert({ ip, email, outcome: "joined" });
    if (ex) {
      token = ex.token;
      await admin.from("waitlist").update({ name, state, bedrooms, note }).eq("id", ex.id);
      if (ex.status === "active") return json(req, 200, { ok: true });       // already confirmed: nothing more to send
      await admin.from("waitlist").update({ status: "pending" }).eq("id", ex.id);
    } else {
      const { data, error } = await admin.from("waitlist").insert({ email, name, state, bedrooms, note }).select("token").single();
      if (error) throw error;
      token = data.token;
    }
    await sendEmail({
      to: email, subject: "Confirm your place on the 2nd Chance Housing waitlist",
      html: `<p>Hello${name ? " " + escapeHtml(name) : ""},</p><p>Someone asked to put this email address on the 2nd Chance Housing waitlist. To get an email when a home opens up, please confirm:</p>` +
        `<p><a href="https://2ndchinc.org/waitlist/?confirm=${token}"><b>Yes, put me on the waitlist</b></a></p><p>If this was not you, ignore this email and nothing will happen.</p>` +
        `<p>Questions? Reply to this email or call (262) 236-5443. You can see what is available now at <a href="https://2ndchinc.org/#units">https://2ndchinc.org/#units</a>.</p>` +
        `<p style="color:#666;font-size:12px"><a href="https://2ndchinc.org/waitlist/?leave=${token}">Take me off the list</a></p>`,
    });
    return json(req, 200, { ok: true });
  } catch (err) {
    console.error("waitlist-join: error", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "We couldn't save that. Please email info@2ndchinc.org or call (262) 236-5443." });
  }
});
