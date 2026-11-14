// 2nd Chance Housing owner portal — shared client + email-code sign-in.
// See supabase/migrations/*_condo_owner_portal.sql for how the pieces fit together.
//
//   email -> 6-digit code emailed (Supabase Auth OTP; the
//            auth-send-email hook writes the code email)
//
// Every data call is a database function that refuses to answer without a
// signed-in session and a matching owner / staff / agent / resident email.
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

import { SUPABASE_URL, SUPABASE_ANON_KEY } from "/assets/portal/config.js";
import { staffNav } from "/assets/portal/staff-nav.js";
import { turnstileToken } from "/assets/turnstile.js";

// Admin "View as" (see /staff/view-as/): the admin's view-as tab keeps its session in THIS TAB ONLY (sessionStorage), so
// the admin's own sign-in in other tabs is never replaced, and everything else on the page works as that person.
const VIEW_AS = (() => { try { return JSON.parse(sessionStorage.getItem("sch-view-as") || "null"); } catch (e) { return null; } })();

export const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: VIEW_AS
    ? { storageKey: "sch-view-as-auth", storage: window.sessionStorage, persistSession: true, autoRefreshToken: true }
    : { storageKey: "sch-owner-portal-auth", persistSession: true, autoRefreshToken: true },
});

if (VIEW_AS) {
  const bar = document.createElement("div");
  bar.setAttribute("role", "status");
  bar.style.cssText = "position:sticky;top:0;z-index:9999;background:#7a1f1f;color:#fff;padding:8px 14px;font:600 14px 'Source Sans 3',Arial,sans-serif;display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;justify-content:space-between";
  bar.innerHTML = '<span></span><button type="button" style="background:#fff;color:#7a1f1f;border:0;border-radius:4px;padding:4px 12px;font:inherit;cursor:pointer">Exit view</button>';
  bar.firstChild.textContent = "VIEW AS: " + (VIEW_AS.name || VIEW_AS.email) + " (" + VIEW_AS.email + "). You are seeing what they see, but you CANNOT pay or send any payment or bank information as them: the Pay buttons are switched off here. Other changes you save are made as them.";
  bar.lastChild.onclick = async () => {
    await client.auth.signOut({ scope: "local" });   // local only: never revoke the real person's own sign-ins
    try { sessionStorage.removeItem("sch-view-as"); } catch (e) { /* ignore */ }
    window.close();
    location.href = "/staff/view-as/";
  };
  document.body.prepend(bar);

  // View as is look-only for money. No payment, autopay or bank information can be sent as the owner or tenant:
  // the calls are refused here, and the buttons are switched off (Stephen, 10/12/2026).
  const NO_PAY_MSG = "View as: you cannot pay or send payment information as this person.";
  const NO_PAY_FUNCTIONS = /^(stripe-pay|plaid-|bank-feed|step-up)/;   // step-up would email the real person a code
  const NO_PAY_RPCS = /^(autopay_(request_code|start|cancel)|resident_bank_save|resident_[a-z_]*(pay|checkout)[a-z_]*|condo_[a-z_]*(pay|checkout)[a-z_]*)$/;
  const READ_ONLY_RPCS = /(_get|_options|_status|_reports|_account)$/;
  const blocked = () => ({ data: null, error: { message: NO_PAY_MSG, context: { json: async () => ({ error: NO_PAY_MSG }) } } });
  const realInvoke = client.functions.invoke.bind(client.functions);
  client.functions.invoke = (name, opts) => NO_PAY_FUNCTIONS.test(String(name)) ? Promise.resolve(blocked()) : realInvoke(name, opts);
  const realRpc = client.rpc.bind(client);
  client.rpc = (name, ...rest) => (NO_PAY_RPCS.test(String(name)) && !READ_ONLY_RPCS.test(String(name))) ? Promise.resolve(blocked()) : realRpc(name, ...rest);
  const lock = () => document.querySelectorAll("#spPay,#apOn,#apOff,#stripeGo,#spAmount,#stripeAmt").forEach((el) => {
    if (el.dataset.viewAsLocked) return;
    el.dataset.viewAsLocked = "1"; el.disabled = true; el.title = NO_PAY_MSG; el.style.opacity = "0.5"; el.style.cursor = "not-allowed";
    if (el.tagName === "BUTTON") el.textContent += " (off in View as)";
  });
  new MutationObserver(lock).observe(document.documentElement, { childList: true, subtree: true });
  lock();
}

export const $ = (id) => document.getElementById(id);
export const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
export const fmtDate = (iso) => {
  if (!iso) return "—";
  const d = new Date(iso.length === 10 ? iso + "T12:00:00" : iso);
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
};
// How a balance reads everywhere: money owed is "$X due"; money in your favor is "Credit $X" and never a negative number.
export const CREDIT_NOTE = "You owe nothing. This credit reduces your next charge.";
export const balanceText = (n) => { n = Number(n) || 0; return n > 0.004 ? `${money(n)} due` : n < -0.004 ? `Credit ${money(-n)}` : "Paid up"; };
export const balCell = (n) => { n = Number(n) || 0; return n < -0.004 ? `${money(-n)} credit` : money(n); };
// A ledger amount: charges are plain; money coming off the account reads "paid" or "credit", not "-$X".
export const amtCell = (e) => { const a = Number(e.amount) || 0; return a < 0 ? `${money(-a)} ${e.kind === "payment" ? "paid" : "credit"}` : money(a); };

// The calendar date (YYYY-MM-DD) in Central time: deadlines and "today" follow the office, not UTC.
export const ctDate = (when) => new Date(when).toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
export const todayCT = () => ctDate(Date.now());
export const money = (n) => (n == null || n === "" || isNaN(n)) ? "—" : Number(n).toLocaleString("en-US", { style: "currency", currency: "USD" });

// Turns a database or edge-function error into one sentence for the page.
export async function errorText(error) {
  if (!error) return "";
  if (error.context && typeof error.context.json === "function") {
    try { const b = await error.context.json(); if (b && b.error) return b.error; } catch (e) { /* fall through */ }
  }
  return error.message || "Something went wrong. Try again.";
}

// Asks the server to email staff about any new change record. Best effort:
// the daily reminder run sends anything this misses.
export function notifyStaff() {
  client.functions.invoke("condo-notify-update", { body: {} }).catch(() => {});
}

export async function signOut() {
  await client.auth.signOut(VIEW_AS ? { scope: "local" } : undefined);
  location.reload();
}

// Renders the sign-in step into `el` and resolves with the whoami result
// once the emailed code is entered (immediately, if this browser is already
// signed in).
export function signIn(el, { audience = "owner" } = {}) {
  return new Promise((resolve) => {
    let email = "";

    const step = (html) => { el.innerHTML = html; el.hidden = false; };
    const msg = (text, kind = "err") => { const m = el.querySelector(".msg"); if (m) { m.className = "msg " + kind; m.textContent = text; } };
    const busy = (on) => el.querySelectorAll("button, input").forEach((x) => { x.disabled = on; });

    async function afterEmailStep() {
      const { data: who, error } = await client.rpc("condo_whoami");
      if (error) return askEmail(await errorText(error));
      if (who.role === "expired") {
        await client.auth.signOut();
        return askEmail("For your security, this device was signed out after a while. Please sign in again with a new code.");
      }
      if (who.role === "none") {
        await client.auth.signOut();
        return askEmail("That email isn't on file as a current owner. Use the email we send association notices to, or contact the office.");
      }
      const forceSetup = new URLSearchParams(location.search).get("mfa") === "setup";   // lets anyone try the authenticator setup before it is required
      if ((who.mfa_required || forceSetup) && !(await mfaGate())) return;
      el.hidden = true;
      // The page title's "Staff" or "Owner Portal" becomes "Hi <first name>" once we know who is signed in.
      const tag = document.querySelector(".appbar .org span");
      if (tag && who.first_name) tag.textContent = tag.textContent.replace(/(Staff|Owner Portal)\s*$/, "Hi " + who.first_name);
      staffNav(who);
      resolve(who);
    }

    // Second step for staff, field staff and agents: the 6-digit code from an authenticator app.
    async function mfaGate() {
      const { data: a } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
      if (a && a.currentLevel === "aal2") return true;
      const { data: f } = await client.auth.mfa.listFactors();
      const verified = ((f && f.totp) || []).find((x) => x.status === "verified");
      return new Promise((done) => (verified ? askApp(verified.id, done) : setupApp(f, done)));
    }
    function askApp(factorId, done, error = "") {
      step(`
        <div class="panel">
          <div><h2>Enter your authenticator code</h2>
            <p class="sub">Open your authenticator app and type the 6-digit code shown for <strong>2nd Chance Housing</strong>. The code changes every 30 seconds.</p></div>
          <form id="appForm" class="panel" style="padding:0;border:none" novalidate>
            <label class="f">Authenticator code<input class="field code" id="appCode" inputmode="numeric" autocomplete="one-time-code" maxlength="6" required></label>
            <div class="row"><button class="btn primary" type="submit">Continue</button><button class="linkbtn" type="button" id="appOut">Sign out</button></div>
            <div class="msg err" role="alert">${esc(error)}</div>
            <p class="sub">Lost your phone or changed apps? Email <a href="mailto:info@2ndchinc.org">info@2ndchinc.org</a> from your work address and the office will reset it.</p>
          </form>
        </div>`);
      $("appCode").focus();
      $("appOut").addEventListener("click", async () => { await client.auth.signOut(); location.reload(); });
      $("appForm").addEventListener("submit", async (e) => {
        e.preventDefault(); busy(true);
        const { error: err } = await client.auth.mfa.challengeAndVerify({ factorId, code: $("appCode").value.replace(/\D/g, "") });
        busy(false);
        if (err) return msg(err.message && /invalid|expired/i.test(err.message) ? "That code didn't work. Wait for the next code and try again." : (err.message || "That code didn't work."));
        done(true);
      });
    }
    async function setupApp(f, done, error = "") {
      for (const x of ((f && f.all) || []).filter((y) => y.status === "unverified")) await client.auth.mfa.unenroll({ factorId: x.id });
      const { data, error: err } = await client.auth.mfa.enroll({ factorType: "totp", friendlyName: "2nd Chance Housing " + new Date().toISOString().slice(0, 10) });
      if (err) { step(`<div class="panel"><div><h2>Set up your authenticator</h2><div class="msg err" role="alert">${esc(err.message || "We couldn't start the setup.")}</div><p class="sub">Email <a href="mailto:info@2ndchinc.org">info@2ndchinc.org</a> for help.</p></div></div>`); return; }
      step(`
        <div class="panel">
          <div><h2>Set up your authenticator app</h2>
            <p class="sub">Your account needs a second step. It takes about a minute, and you only do it once.</p>
            <ol class="sub" style="margin:8px 0 0 1.2rem">
              <li>Install an authenticator app on your phone (Google Authenticator, Microsoft Authenticator, Authy or 1Password).</li>
              <li>In the app, add an account and <strong>scan this code</strong>.</li>
              <li>Type the 6-digit code the app shows.</li>
            </ol></div>
          <div style="text-align:center;margin:12px 0"><img alt="QR code to scan with your authenticator app" src="${esc(data.totp.qr_code)}" style="width:190px;height:190px;background:#fff;padding:6px;border-radius:8px"></div>
          <p class="sub" style="text-align:center">Can't scan? Type this key into the app instead:<br><code style="user-select:all;word-break:break-all">${esc(data.totp.secret)}</code></p>
          <form id="appForm" class="panel" style="padding:0;border:none" novalidate>
            <label class="f">Code from the app<input class="field code" id="appCode" inputmode="numeric" autocomplete="one-time-code" maxlength="6" required></label>
            <div class="row"><button class="btn primary" type="submit">Turn on and continue</button><button class="linkbtn" type="button" id="appOut">Sign out</button></div>
            <div class="msg err" role="alert">${esc(error)}</div>
          </form>
        </div>`);
      $("appCode").focus();
      $("appOut").addEventListener("click", async () => { await client.auth.signOut(); location.reload(); });
      $("appForm").addEventListener("submit", async (e) => {
        e.preventDefault(); busy(true);
        const { error: err2 } = await client.auth.mfa.challengeAndVerify({ factorId: data.id, code: $("appCode").value.replace(/\D/g, "") });
        busy(false);
        if (err2) return msg("That code didn't match. Make sure you scanned the code above, then type the new 6-digit number.");
        done(true);
      });
    }

    // Remember the last email on this device so a returning owner only taps "Email me a code".
    const REMEMBER_KEY = "sch-owner-portal-email";
    const remembered = () => { try { return localStorage.getItem(REMEMBER_KEY) || ""; } catch (e) { return ""; } };
    const remember = (v) => { try { v ? localStorage.setItem(REMEMBER_KEY, v) : localStorage.removeItem(REMEMBER_KEY); } catch (e) { /* storage blocked: fine */ } };
    let cooldownUntil = 0, cooldownTimer = null;

    async function sendCode() {
      let captchaToken;
      try { captchaToken = await turnstileToken(); } catch (e) { return e; }
      const { error } = await client.auth.signInWithOtp({ email, options: { shouldCreateUser: true, captchaToken } });
      if (!error) cooldownUntil = Date.now() + 60000;
      return error;
    }

    function askEmail(error = "") {
      if (!email) email = remembered();
      step(`
        <div class="panel">
          <div><h2>Sign in</h2>
            <p class="sub">${audience === "staff" ? "Staff sign-in." : audience === "field" ? "Staff sign-in (inspections and your assigned units)." : audience === "contractor" ? "Contractor and vendor sign-in (your assigned jobs)." : audience === "investor" ? "Investor research sign-in." : audience === "agent" ? "Lease agent sign-in." : audience === "seller" ? "Land contract seller sign-in (your contract, payments and schedule)." : audience === "caseworker" ? "Caseworker sign-in (your clients' lease, W-9 and ways to pay)." : audience === "resident" ? "For residents of 2nd Chance Housing." : "For owners at Royal Orleans Condominium – Addition One."} We'll email you a 6-digit code. No password to remember.</p></div>
          <form id="emailForm" class="panel" style="padding:0;border:none" novalidate>
            <label class="f">Email address<input class="field" type="email" id="emailInput" autocomplete="email" required value="${esc(email)}"></label>
            <div class="row"><button class="btn primary" type="submit">Email me a code</button></div>
            <label style="display:flex;gap:8px;align-items:center;margin-top:8px;font-size:0.85rem;color:var(--muted)"><input type="checkbox" id="rememberMe" ${remembered() ? "checked" : ""}> Remember my email on this device</label>
            <div class="msg err" role="alert">${esc(error)}</div>
            <p class="sub">${audience === "resident" ? `Email changed, or no code arrives? <a href="/register/">Update your info here</a> with the code on your notice. ` : ""}Trouble signing in? Email <a href="mailto:info@2ndchinc.org">info@2ndchinc.org</a> or call or text <a href="tel:2622365443">(262) 236-5443</a>.</p>
          </form>
        </div>`);
      $("emailInput").focus();
      $("emailForm").addEventListener("submit", async (e) => {
        e.preventDefault();
        email = $("emailInput").value.trim().toLowerCase();
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return msg("Enter a full email address.");
        busy(true);
        const error = await sendCode();
        busy(false);
        if (error) return msg(error.status === 429 ? "Too many requests. Wait a minute and try again." : await errorText(error));
        remember($("rememberMe").checked ? email : "");
        askEmailCode();
      });
    }

    function askEmailCode(error = "") {
      step(`
        <div class="panel">
          <div><h2>Check your email</h2>
            <p class="sub">If <strong>${esc(email)}</strong> is on file, a 6-digit code is on its way from 2nd Chance Housing. It can take a minute; check spam too.</p></div>
          <form id="codeForm" class="panel" style="padding:0;border:none" novalidate>
            <label class="f">Email code<input class="field code" id="codeInput" inputmode="numeric" autocomplete="one-time-code" maxlength="6" required></label>
            <div class="row"><button class="btn primary" type="submit">Continue</button>
              <button class="linkbtn" type="button" id="resend"></button>
              <button class="linkbtn" type="button" id="restart">Use a different email</button></div>
            <div class="msg err" role="alert">${esc(error)}</div>
          </form>
        </div>`);
      $("codeInput").focus();
      $("restart").addEventListener("click", () => { clearInterval(cooldownTimer); askEmail(); });

      // "Send a new code" is locked for 60 seconds after each send, so it can't hit the email rate limit.
      const tick = () => {
        const left = Math.ceil((cooldownUntil - Date.now()) / 1000), b = $("resend");
        if (!b) return clearInterval(cooldownTimer);
        b.disabled = left > 0;
        b.textContent = left > 0 ? `Send a new code in ${left}s` : "Send a new code";
        if (left <= 0) clearInterval(cooldownTimer);
      };
      clearInterval(cooldownTimer); cooldownTimer = setInterval(tick, 1000); tick();
      $("resend").addEventListener("click", async () => {
        busy(true);
        const err = await sendCode();
        busy(false);
        clearInterval(cooldownTimer); cooldownTimer = setInterval(tick, 1000); tick();
        if (err) return msg(err.status === 429 ? "Too many requests. Wait a minute and try again." : await errorText(err));
        msg("A new code is on its way. Use the newest email.", "ok");
        $("codeInput").value = ""; $("codeInput").focus();
      });

      let verifying = false;
      async function verify() {
        if (verifying) return;
        const token = $("codeInput").value.replace(/\D/g, "");
        if (token.length !== 6) return msg("Enter all 6 digits from the email.");
        verifying = true; busy(true);
        const { error } = await client.auth.verifyOtp({ email, token, type: "email" });
        verifying = false; busy(false); tick();
        if (error) { $("codeInput").select(); return msg("That code didn't work. It may have expired; tap Send a new code."); }
        clearInterval(cooldownTimer);
        afterEmailStep();
      }
      $("codeForm").addEventListener("submit", (e) => { e.preventDefault(); verify(); });
      // Typing or pasting the sixth digit signs in without another tap.
      $("codeInput").addEventListener("input", () => { if ($("codeInput").value.replace(/\D/g, "").length === 6) verify(); });
    }

    client.auth.getSession().then(({ data }) => {
      if (data.session) { email = data.session.user.email || ""; afterEmailStep(); }
      else askEmail();
    });
  });
}
