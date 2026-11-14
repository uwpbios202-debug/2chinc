// Emails an owner their association account statement for one unit.
//   POST { unit_number, from?, to? }  (owner JWT in Authorization) -> { sent: true, to }
// The statement is built here from the signed-in owner's own account, and
// goes only to the email they signed in with.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml as esc, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const money = (n: number) => (n < 0 ? "-" : "") + "$" + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const bal = (n: number) => (n < -0.004 ? money(-n) + " credit" : money(n));
const fmt = (iso: string) => new Date(iso + "T12:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
const isDate = (s: unknown) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const { data: u } = await uc.auth.getUser(jwt);
    const to = u?.user?.email;
    if (!to) return json(req, 401, { error: "Please sign in." });
    const body = await req.json().catch(() => ({}));
    const from = isDate(body.from) ? body.from : null, until = isDate(body.to) ? body.to : null;
    const { data: acct, error } = await uc.rpc("condo_my_account");
    if (error || !acct) return json(req, 403, { error: "Sign in as an owner first." });
    const unit = (acct.units || []).find((x: { unit_number: string }) => x.unit_number === String(body.unit_number || ""));
    if (!unit) return json(req, 400, { error: "Choose one of your units." });

    let opening = 0, closing = 0;
    const sections = (unit.accounts || []).map((a: { owner: string; entries: { date: string; amount: number; description?: string; type?: string; check_number?: string }[] }) => {
      const before = a.entries.filter((e) => from && e.date < from).reduce((t, e) => t + Number(e.amount), 0);
      const rows = a.entries.filter((e) => (!from || e.date >= from) && (!until || e.date <= until)).sort((x, y) => (x.date > y.date ? 1 : -1));
      opening += before; closing += a.entries.filter((e) => !until || e.date <= until).reduce((t, e) => t + Number(e.amount), 0);
      let run = before;
      const tr = rows.map((e) => { run += Number(e.amount);
        return `<tr><td>${fmt(e.date)}</td><td>${esc(e.description || e.type || "")}${e.check_number ? ` #${esc(e.check_number)}` : ""}</td><td align="right">${e.amount > 0 ? money(e.amount) : ""}</td><td align="right">${e.amount < 0 ? money(-e.amount) : ""}</td><td align="right">${bal(run)}</td></tr>`; }).join("");
      return tr ? `<table cellpadding="6" cellspacing="0" style="border-collapse:collapse;width:100%;font-size:14px"><thead><tr style="background:#eef1f5"><th align="left">Date</th><th align="left">Description</th><th align="right">Charges</th><th align="right">Payments &amp; credits</th><th align="right">Balance</th></tr></thead><tbody>${from ? `<tr><td>${fmt(from)}</td><td><i>Balance forward</i></td><td></td><td></td><td align="right">${bal(before)}</td></tr>` : ""}${tr}</tbody></table>` : "";
    }).join("");

    const html = `<div style="font-family:Arial,sans-serif;max-width:720px;color:#1b2430">
      <p><b>Royal Orleans Condominium – Addition One</b><br>managed by 2nd Chance Housing Inc.<br>6626 N. Bourbon St., Milwaukee, WI 53224</p>
      <h2 style="margin:16px 0 4px">Account statement</h2>
      <p style="margin:0 0 12px">${from ? fmt(from) : "All history"} – ${until ? fmt(until) : fmt(new Date().toISOString().slice(0, 10))}<br>
        <b>${esc(acct.owner)}</b> · Unit ${esc(unit.unit_number)} · ${esc(unit.address || "")}${unit.pin ? ` · Account # ${esc(unit.pin)}` : ""}</p>
      <p>Opening balance <b>${bal(opening)}</b> · Amount due <b>${money(Math.max(closing, 0))}</b>${closing < -0.004 ? `<br>Credit <b>${money(-closing)}</b>: you owe nothing. This credit reduces your next charge.` : ""}</p>
      ${sections || "<p>No activity in this period.</p>"}
      ${acct.pay_instructions ? `<p style="margin-top:16px">${esc(acct.pay_instructions)}</p>` : ""}
      <p style="color:#5b6573;font-size:13px">Questions: ${esc(acct.office_phone || "")}</p></div>`;
    await sendEmail({ to, subject: `Your account statement, Unit ${unit.unit_number}`, html });
    return json(req, 200, { sent: true, to });
  } catch (err) {
    console.error("owner-statement:", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "We couldn't send the statement. Try again." });
  }
});
