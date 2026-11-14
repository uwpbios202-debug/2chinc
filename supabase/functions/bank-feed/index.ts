// Bank feed (Plaid): connects the two Chase accounts (tenant rent and ROCA1 owner dues, kept separate), pulls new
// deposits, and hands them to the payments autopilot. Deposits become bank_receipts; bank_autopilot() matches and posts them.
//
// POST { action: "link_token", kind }                      staff    -> { link_token }   (opens Plaid Link in the browser)
// POST { action: "exchange", public_token, kind, name }    staff    -> connects the account(s) and syncs
// POST { action: "sync", bank_account_id? }                staff, or x-cycle-secret (the daily job) -> pulls new deposits
// POST { webhook_type: "TRANSACTIONS", item_id, ... }      Plaid   -> triggers a sync for that item (idempotent: it only pulls)
//
// Secrets: PLAID_CLIENT_ID, PLAID_SECRET, PLAID_ENV (sandbox | production), BANK_TOKEN_KEY (base64, 32 bytes).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml, PORTAL_BASE_URL, SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";
import { decryptToken, encryptToken, plaidBase, plaidCall, toReceipt, type PlaidTxn } from "../_shared/plaid.ts";

const CLIENT_ID = Deno.env.get("PLAID_CLIENT_ID") || "", SECRET = Deno.env.get("PLAID_SECRET") || "";
const ENV = Deno.env.get("PLAID_ENV") || "sandbox", KEY = Deno.env.get("BANK_TOKEN_KEY") || "";
const CYCLE_SECRET = Deno.env.get("RENT_CYCLE_SECRET") || "";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const base = plaidBase(ENV);
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const call = (path: string, body: Record<string, unknown>) => plaidCall(base, path, body, CLIENT_ID, SECRET);

async function staffEmail(req: Request) {
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u } = await admin.auth.getUser(jwt);
  const email = u?.user?.email?.toLowerCase();
  if (!email) return null;
  const { data: st } = await admin.from("condo_staff").select("email").ilike("email", email).maybeSingle();
  return st ? email : null;
}

// Pull everything new for one connected account, insert the deposits, and run the autopilot afterwards.
async function syncAccount(acct: { id: string; plaid_item_id: string; plaid_account_id: string; access_token_enc: string; cursor: string | null }) {
  const token = await decryptToken(acct.access_token_enc, KEY);
  let cursor = acct.cursor || undefined, added = 0, more = true, inserted = 0;
  while (more) {
    const r = await call("/transactions/sync", { access_token: token, cursor, count: 250, options: { include_original_description: true } });
    for (const t of (r.added || []) as PlaidTxn[]) {
      if (t.account_id !== acct.plaid_account_id) continue;
      const row = toReceipt(t, acct.id);
      if (!row) continue;
      const { error, count } = await admin.from("bank_receipts").upsert(row, { onConflict: "fingerprint", ignoreDuplicates: true, count: "exact" });
      if (error) throw error;
      added++; inserted += count || 0;
    }
    // The bank can take a transaction back or change it after we saw it. Not yet posted: follow the bank. Already posted: tell the office.
    for (const gone of (r.removed || []) as { transaction_id: string }[]) {
      const { data: rows } = await admin.from("bank_receipts").select("id, status, amount, posted_on").eq("provider_id", gone.transaction_id);
      for (const x of rows || []) {
        if (x.status === "posted") await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "A posted bank deposit was removed by the bank", html: `<p>The bank removed a ${Number(x.amount).toFixed(2)} transaction from ${escapeHtml(String(x.posted_on))} that was already posted to a ledger. Check it on the bank page and reverse the payment if the money is not there.</p>` }).catch(() => {});
        else await admin.from("bank_receipts").update({ status: "ignored", ignored: true, review_reason: "Removed by the bank" }).eq("id", x.id);
      }
    }
    for (const t of (r.modified || []) as PlaidTxn[]) {
      if (t.account_id !== acct.plaid_account_id || t.pending) continue;
      const row = toReceipt(t, acct.id); if (!row) continue;
      const { data: ex } = await admin.from("bank_receipts").select("id, status, amount").eq("provider_id", t.transaction_id).maybeSingle();
      if (!ex || Number(ex.amount) === Number(row.amount)) continue;
      if (ex.status === "posted") await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: "A posted bank deposit changed amount", html: `<p>The bank changed a posted deposit from ${Number(ex.amount).toFixed(2)} to ${Number(row.amount).toFixed(2)} (${escapeHtml(String(row.posted_on))}). Check it on the bank page.</p>` }).catch(() => {});
      else await admin.from("bank_receipts").update({ amount: row.amount, description: row.description, payer_name: row.payer_name, posted_on: row.posted_on }).eq("id", ex.id);
    }
    cursor = r.next_cursor; more = !!r.has_more;
  }
  await admin.from("bank_accounts").update({ cursor: cursor || null, last_synced_at: new Date().toISOString(), last_error: null }).eq("id", acct.id);
  return { seen: added, new_receipts: inserted };
}

async function syncAll(only?: string, force = false) {
  let q = admin.from("bank_accounts").select("id, name, kind, plaid_item_id, plaid_account_id, access_token_enc, cursor").eq("active", true).not("plaid_item_id", "is", null);
  if (only) q = q.eq("id", only);
  const { data: accts } = await q;
  const out: unknown[] = [];
  for (const a of accts || []) {
    try { out.push({ account: a.name, ...(await syncAccount(a)) }); }
    catch (e) { const msg = e instanceof Error ? e.message : String(e); await admin.from("bank_accounts").update({ last_error: msg.slice(0, 300) }).eq("id", a.id); out.push({ account: a.name, error: msg }); }
  }
  // Deposits are always collected. They are matched and posted when bank_autopost is on (its own switch, so payments
  // post without turning on late fees and notices), when automation_mode is "live", or when staff ask for it.
  const { data: sets } = await admin.from("portal_settings").select("key, value").in("key", ["automation_mode", "bank_autopost"]);
  const setting = (k: string) => (sets || []).find((x) => x.key === k)?.value;
  if (!force && setting("bank_autopost") !== "on" && (setting("automation_mode") || "off") !== "live")
    return { accounts: out, autopilot: { held: "bank_autopost and automation_mode are off: deposits are saved and will post when either is switched on" } };
  const { data: res, error } = await admin.rpc("bank_autopilot");
  if (error) throw error;
  // One short email to the office when the autopilot posted something or a deposit NEWLY needs a person. Each waiting
  // deposit is claimed once (review_notified_at), so repeated or parallel syncs do not repeat the same email.
  const posted = Number(res?.posted || 0);
  const { data: fresh } = await admin.from("bank_receipts").update({ review_notified_at: new Date().toISOString() })
    .eq("status", "needs_review").is("review_notified_at", null).select("id");
  const review = (fresh || []).length;
  if (posted + review > 0) {
    const link = new URL("/accounting/bank/", PORTAL_BASE_URL).toString().replace("/association-owners/roca1/", "/");
    await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: `Bank deposits: ${posted} posted automatically${review ? `, ${review} need a look` : ""}`,
      html: `<p>The bank feed just checked in.</p><ul><li><b>${posted}</b> deposit(s) matched a tenant or owner and were posted to the ledger.</li>${review ? `<li><b>${review}</b> deposit(s) need you to say who they are: <a href="${escapeHtml(link)}">open the bank page</a>.</li>` : ""}</ul>` }).catch(() => {});
  }
  return { accounts: out, autopilot: res };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const body = await req.json().catch(() => ({}));
    if (!CLIENT_ID || !SECRET || !KEY) return json(req, 503, { error: "The bank connection is not set up yet (Plaid keys are missing)." });

    // Plaid webhook: a sync is safe to trigger (it only pulls), so no data is trusted from the webhook body.
    if (body.webhook_type === "TRANSACTIONS" && body.item_id) {
      const { data: a } = await admin.from("bank_accounts").select("id").eq("plaid_item_id", body.item_id).maybeSingle();
      if (a) await syncAll(a.id);
      return json(req, 200, { ok: true });
    }

    const viaCron = !!CYCLE_SECRET && req.headers.get("x-cycle-secret") === CYCLE_SECRET;
    const staff = viaCron ? "cron" : await staffEmail(req);
    if (!staff) return json(req, 401, { error: "Staff sign-in required." });

    if (body.action === "link_token") {
      const which = body.kind === "owner" ? "owner" : body.kind === "yawdcour" ? "yawdcour" : "tenant";
      // OAuth banks (Chase) need the redirect address registered in the Plaid dashboard; it is used only once portal_settings
      // plaid_redirect_uri is set, so Connect cannot break before that is done.
      const { data: ru } = await admin.from("portal_settings").select("value").eq("key", "plaid_redirect_uri").maybeSingle();
      const r = await call("/link/token/create", {
        user: { client_user_id: `2ndchinc-${which}` }, client_name: "2nd Chance Housing", products: ["transactions"], country_codes: ["US"], language: "en",
        webhook: `${SUPABASE_URL}/functions/v1/bank-feed`, transactions: { days_requested: 90 },
        ...(ru?.value ? { redirect_uri: ru.value } : {}),
      });
      return json(req, 200, { link_token: r.link_token });
    }
    if (body.action === "exchange") {
      const which = body.kind === "owner" ? "owner" : body.kind === "yawdcour" ? "yawdcour" : "tenant";
      const kind = which === "owner" ? "owner" : "tenant";   // Yawdcour's Chase is a tenant-rent account
      const ex = await call("/item/public_token/exchange", { public_token: String(body.public_token || "") });
      const accts = await call("/accounts/get", { access_token: ex.access_token });
      const enc = await encryptToken(ex.access_token, KEY);
      const inst = accts.item?.institution_id || null;
      const dep = (accts.accounts || []).filter((a: { type: string }) => a.type === "depository");
      // The account the person picked in Plaid Link; otherwise the checking account.
      const pick = dep.find((a: { account_id: string }) => a.account_id === body.account_id) || dep.find((a: { subtype: string }) => a.subtype === "checking") || dep[0];
      if (!pick) return json(req, 400, { error: "No checking or savings account was shared. Connect again and choose the account." });
      // The official account of that side (Chase for 2nd Chance, First Citizens for ROCA1) takes the Plaid link, and
      // from then on Plaid is its bank truth (a CSV for it only confirms).
      const officialKey = which === "owner" ? "first_citizens_roca1" : which === "yawdcour" ? "chase_yawdcour" : "chase_2ch";
      const { data: official } = await admin.from("bank_accounts").select("id, plaid_item_id").eq("bank_key", officialKey).maybeSingle();
      const fields = { kind, institution: inst, mask: pick.mask || null, plaid_item_id: ex.item_id, plaid_account_id: pick.account_id, access_token_enc: enc, active: true, truth_source: "plaid" };
      let error;
      if (official && !official.plaid_item_id) {
        ({ error } = await admin.from("bank_accounts").update(fields).eq("id", official.id));
      } else {
        ({ error } = await admin.from("bank_accounts").upsert({
          name: `${String(body.name || (which === "owner" ? "ROCA1 owner dues account" : which === "yawdcour" ? "Yawdcour tenant rent account" : "2nd Chance tenant rent account")).slice(0, 80)} ••${pick.mask || ""}`, ...fields,
        }, { onConflict: "plaid_item_id,plaid_account_id", ignoreDuplicates: false }));
      }
      if (error) throw error;
      const checking = [pick];
      return json(req, 200, { connected: checking.length, sync: await syncAll(undefined, !viaCron) });
    }
    if (body.action === "sync") return json(req, 200, await syncAll(body.bank_account_id, !viaCron));
    return json(req, 400, { error: "Unknown action" });
  } catch (err) {
    console.error("bank-feed: error", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: err instanceof Error ? err.message : "Something went wrong." });
  }
});
