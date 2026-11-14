// Resident portal actions (resident two-step signed in; JWT in Authorization):
//   POST { action: "resend_signing_link", doc_id } -> new private signing link for a lease waiting on this resident
//   POST { action: "email_statement", lease_id }   -> emails the resident their account statement
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml, PORTAL_BASE_URL, SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const SIGN_BASE_URL = Deno.env.get("SIGN_BASE_URL") || new URL("/sign/", PORTAL_BASE_URL).toString();
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const money = (n: number) => (n < 0 ? "-" : "") + "$" + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const fmtDate = (d: string) => new Date(d + "T12:00:00").toLocaleDateString("en-US", { month: "numeric", day: "numeric", year: "2-digit" });

async function sha256(s: string) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const { data: ids } = await uc.rpc("resident_me");
    const { data: u } = await admin.auth.getUser(jwt);
    const tenantIds: string[] = (ids || []).map((x: unknown) => (typeof x === "string" ? x : Object.values(x as Record<string, string>)[0]));
    const email = u?.user?.email;
    if (!tenantIds.length || !email) return json(req, 403, { error: "Please sign in with the code we email you." });
    const body = await req.json().catch(() => ({}));

    if (body.action === "resend_signing_link") {
      const { data: s } = await admin.from("lease_signing_signers").select("*, lease_signing_docs!inner(status, unit_label)")
        .eq("doc_id", String(body.doc_id || "")).ilike("email", email).maybeSingle();
      if (!s || s.signed_at || s.lease_signing_docs.status !== "sent") return json(req, 404, { error: "There's no lease waiting for your signature." });
      const b = crypto.getRandomValues(new Uint8Array(32));
      const token = btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
      await admin.from("lease_signing_signers").update({ token_hash: await sha256(token), verified_at: null }).eq("id", s.id);
      await admin.from("lease_signing_events").insert({ doc_id: s.doc_id, signer_id: s.id, event: "link_reissued", detail: "requested from the resident portal" });
      const link = `${SIGN_BASE_URL}#t=${token}`;
      await sendEmail({ to: s.email, subject: `Your lease for ${s.lease_signing_docs.unit_label} is ready to sign`,
        html: `<p>Here's a new private link to review and sign your lease (any earlier link no longer works):</p><p><a href="${link}">Review and sign my lease</a></p><p>If the button doesn't work, copy this link into your browser:<br>${link}</p>` });
      return json(req, 200, { ok: true });
    }

    if (body.action === "email_statement") {
      const { data: lease } = await admin.from("leases").select("id, account_number, rental_units!inner(address)").eq("id", String(body.lease_id || "")).maybeSingle();
      const { count } = await admin.from("lease_tenants").select("tenant_id", { count: "exact", head: true }).eq("lease_id", lease?.id || "").in("tenant_id", tenantIds);
      if (!lease || !count) return json(req, 404, { error: "Lease not found." });
      const { data: lines } = await admin.from("lease_ledger_entries").select("entry_date, raw_type, description, amount, kind").eq("lease_id", lease.id).order("entry_date").order("id");
      let run = 0;
      const rowsHtml = (lines || []).map((e) => { run += Number(e.amount);
        return `<tr><td>${fmtDate(e.entry_date)}</td><td>${escapeHtml(e.kind === "in_kind" ? "Work in lieu of rent" : e.raw_type)}<br><span style="color:#666">${escapeHtml(e.description || "")}</span></td><td align="right">${money(Number(e.amount))}</td><td align="right">${money(run)}</td></tr>`; }).join("");
      await sendEmail({ to: email, subject: `Your account statement — ${lease.rental_units.address}`,
        html: `<p>Account ${escapeHtml(lease.account_number || "")} · ${escapeHtml(lease.rental_units.address)}</p>
          <table cellpadding="6" style="border-collapse:collapse;font:14px Arial" border="1" bordercolor="#ddd"><tr><th align="left">Date</th><th align="left">Memo</th><th align="right">Amount</th><th align="right">Balance</th></tr>${rowsHtml}</table>
          <p><b>Current balance: ${money(run)}</b></p><p>2nd Chance Housing</p>` });
      return json(req, 200, { ok: true });
    }
    return json(req, 400, { error: "Unknown action" });
  } catch (err) {
    console.error("resident-portal: error", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "Something went wrong. Try again." });
  }
});
