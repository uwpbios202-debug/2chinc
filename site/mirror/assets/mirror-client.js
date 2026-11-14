// @ts-check
// The Human Mirror: sign-in and "who am I" for /mirror/ pages (T1.3, D-22).
//
// Uses the site's existing Supabase client and sign-in (same browser session as every portal), so the "Sign in" button in
// the code email (https://2ndchinc.org/sign-in/) works unchanged. Nothing here changes any other portal.
// Who may get a code is decided in the database (signin_email_on_file + mirror_signin_enabled); what a signed-in person may
// see is decided by mirror.allowed(). This file only shows it.
//
//   signInBox(el)             the whole sign-in on /mirror/sign-in/: email -> code -> authenticator (coordinators) -> home
//   requireArea("my"|"workspace")   at the top of an area page: returns who, or sends the person to sign in / their own area
//   signOut()                 asks: this device only, or everywhere
//
// Sign-out limits (Phase 2 finding C, migration 20261119269500; the database enforces them, this file shows them):
//   coordinators and admins: the screen locks after 15 minutes without activity (authenticator code to unlock; nothing typed is lost);
//     signed out after 24 hours unused or 7 days after signing in.
//   a person on their own device: 30 days unused or 90 days after signing in.
//   a person on a shared device: 30 minutes without activity, and the sign-in is forgotten when the browser closes.
//   Before a short limit, a warning with "Keep me signed in" (2 minutes). After signing in again, the person returns to the same page.

import { client, errorText } from "/assets/portal/portal.js";
import { turnstileToken } from "/assets/turnstile.js";
import { esc } from "/mirror/assets/mirror-ui.js?v=20261113h";

export { client };

/** @typedef {{ member_idle_hours: number, member_max_days: number, member_lock_minutes: number, person_idle_days: number,
 *   person_max_days: number, shared_idle_minutes: number, warn_seconds: number }} Limits */
/** @typedef {{ signed_in: boolean, expired?: boolean, locked?: boolean, email?: string, aal?: string, view_as?: boolean,
 *   person?: {id: string, preferred_name: string}|null, session?: { device: "own"|"shared"|null, limits: Limits },
 *   memberships?: {organization_id: string, organization: string, role: string, name: string}[], needs_authenticator?: boolean, signin_enabled?: boolean }} Who */

/** @returns {Promise<Who>} */
export async function whoami() {
  const { data: s } = await client.auth.getSession();
  if (!s.session) return { signed_in: false };
  const { data, error } = await client.rpc("mirror_whoami");
  if (error) throw new Error(await errorText(error));
  return data;
}

/** Where a signed-in person belongs. @param {Who} w */
export function homeFor(w) {
  if (w.memberships && w.memberships.length) return "/mirror/workspace/";
  if (w.person) return "/mirror/my-mirror/";
  return "";
}

/** Only /mirror/ paths on this site (with a plain query string) may be returned to. @param {string|null} p */
const safeNext = (p) => (p && /^\/mirror\/[\w\-/]*(\?[\w\-=&%.]*)?$/.test(p) ? p : "");

// ---------------------------------------------------------------- this device: shared or own, activity, lock
const SHARED_COOKIE = "mm_shared";        // a session cookie: gone when the browser closes
const K_ACT = "mm-last-activity", K_TOUCH = "mm-last-touch", K_LOCK = "mm-locked", K_PENDING = "mm-device-pending";
const ls = {
  get: (/** @type {string} */ k) => { try { return localStorage.getItem(k) || ""; } catch { return ""; } },
  set: (/** @type {string} */ k, /** @type {string} */ v) => { try { v ? localStorage.setItem(k, v) : localStorage.removeItem(k); } catch { /* blocked */ } },
};
const hasSharedCookie = () => document.cookie.split("; ").includes(SHARED_COOKIE + "=1");
const setSharedCookie = (/** @type {boolean} */ on) => {
  document.cookie = on ? `${SHARED_COOKIE}=1; path=/; SameSite=Strict; Secure` : `${SHARED_COOKIE}=; path=/; max-age=0; SameSite=Strict; Secure`;
};
function clearDevice() {
  setSharedCookie(false);
  [K_ACT, K_TOUCH, K_LOCK].forEach((k) => ls.set(k, ""));
}

/** @param {"local"|"global"} scope @param {string} [to] */
async function endSession(scope, to = "/mirror/") {
  try { await client.auth.signOut({ scope }); } catch { /* already gone */ }
  if (scope === "global") { try { await client.auth.signOut({ scope: "local" }); } catch { /* already gone */ } }
  clearDevice();
  location.href = to;
}

/** A small modal. Returns the chosen value. @param {string} html @param {string} [focus] @returns {{ el: HTMLElement, close: () => void }} */
function modal(html, focus) {
  const wrap = document.createElement("div");
  wrap.setAttribute("style", "position:fixed;inset:0;z-index:1000;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;padding:16px");
  wrap.innerHTML = `<div class="mm-card" role="dialog" aria-modal="true" style="max-width:32rem;width:100%;max-height:90vh;overflow:auto">${html}</div>`;
  document.body.append(wrap);
  const others = [...document.body.children].filter((x) => x !== wrap && !x.hasAttribute("inert"));
  others.forEach((x) => x.setAttribute("inert", ""));
  /** @type {HTMLElement|null} */ (wrap.querySelector(focus || "button, input"))?.focus();
  return { el: wrap, close: () => { others.forEach((x) => x.removeAttribute("inert")); wrap.remove(); } };
}

export function signOut() {
  const m = modal(`<h2 style="margin-top:0">Sign out</h2>
    <p>Sign out of this phone or computer only, or everywhere you are signed in (for example if you lost a phone or used someone else's).</p>
    <p class="mm-muted mm-small">"Everywhere" also signs you out of the 2nd Chance Housing website on those devices.</p>
    <div class="mm-row"><button class="mm-btn" type="button" data-s="local">Sign out here</button>
      <button class="mm-btn mm-btn-secondary" type="button" data-s="global">Sign out everywhere</button>
      <button class="mm-btn mm-btn-quiet" type="button" data-s="">Cancel</button></div>`);
  m.el.querySelectorAll("[data-s]").forEach((b) => b.addEventListener("click", () => {
    const s = /** @type {HTMLElement} */ (b).dataset.s;
    if (!s) return m.close();
    m.el.querySelectorAll("button").forEach((x) => { x.disabled = true; });
    endSession(/** @type {"local"|"global"} */ (s));
  }));
}

/** "Is this your own phone or computer?" (asked once per sign-in, no default). @returns {Promise<"own"|"shared">} */
function askDevice() {
  return new Promise((done) => {
    const m = modal(`<form id="mmDev" novalidate><h2 style="margin-top:0">Is this your own phone or computer?</h2>
      <p>This decides how long you stay signed in here.</p>
      <div class="mm-row" style="flex-direction:column;align-items:stretch">
        <button class="mm-btn" type="button" data-d="own">Yes, it's mine. Only I use it.</button>
        <button class="mm-btn mm-btn-secondary" type="button" data-d="shared">No, it's shared or public (library, shelter, a friend's phone)</button></div>
      <p class="mm-muted mm-small">Your own: you stay signed in for up to 90 days. Shared: you are signed out after 30 minutes without activity and when the browser closes.</p>
      <div data-msg></div></form>`, "[data-d]");
    m.el.querySelectorAll("[data-d]").forEach((b) => b.addEventListener("click", async () => {
      const d = /** @type {"own"|"shared"} */ (/** @type {HTMLElement} */ (b).dataset.d);
      try { await applyDevice(d); } catch (e) {
        const box = m.el.querySelector("[data-msg]");
        if (box) box.innerHTML = `<div class="mm-notice mm-notice-urgent" role="alert"><p>${esc(e instanceof Error ? e.message : String(e))}</p></div>`;
        return;
      }
      m.close(); done(d);
    }));
  });
}

/** Records the answer for this sign-in. @param {"own"|"shared"} d */
async function applyDevice(d) {
  const { error } = await client.rpc("mirror_device_choose", { p_shared: d === "shared" });
  if (error) throw new Error(await errorText(error));
  setSharedCookie(d === "shared");
  if (d === "shared") ls.set("mm-signin-email", "");
  try { sessionStorage.removeItem(K_PENDING); } catch { /* blocked */ }
}

/** After sign-in or on any page: make sure this sign-in has its answer. @param {Who} w */
async function ensureDevice(w) {
  if (!w.session || w.session.device) return;
  let pending = "";
  try { pending = sessionStorage.getItem(K_PENDING) || ""; } catch { /* blocked */ }
  if (pending === "own" || pending === "shared") { try { await applyDevice(pending); return; } catch { /* ask instead */ } }
  asking = asking || askDevice();          // two page modules may ask at once: one question
  await asking;
}
let asking = /** @type {Promise<string>|null} */ (null);

const goSignIn = (/** @type {string} */ why) =>
  location.replace("/mirror/sign-in/?next=" + encodeURIComponent(location.pathname + location.search) + (why ? "&why=" + why : ""));

let locking = /** @type {Promise<void>|null} */ (null);
/** The coordinator screen lock: hides the page until the authenticator code is entered again. Nothing on the page is lost. */
function lockScreen() {
  if (locking) return locking;
  ls.set(K_LOCK, "1");
  locking = new Promise((done) => {
    const m = modal(`<form id="mmLock" novalidate>
      <h2 style="margin-top:0">Screen locked</h2>
      <p>To protect the people you work with, the Mirror locks after a few minutes without activity. Enter your authenticator code to continue where you were.</p>
      <div class="mm-field"><label for="mmLockCode">Authenticator code</label>
        <input class="mm-input" id="mmLockCode" inputmode="numeric" autocomplete="one-time-code" maxlength="6" data-mm-no-voice required></div>
      <div data-msg></div>
      <div class="mm-row"><button class="mm-btn" type="submit">Unlock</button><button class="mm-btn mm-btn-quiet" type="button" id="mmLockOut">Sign out</button></div>
    </form>`, "#mmLockCode");
    m.el.style.background = "var(--mm-bg, #fff)";          // opaque: nothing behind it can be read
    const msg = (/** @type {string} */ t) => { const b = m.el.querySelector("[data-msg]"); if (b) b.innerHTML = `<div class="mm-notice mm-notice-urgent" role="alert"><p>${esc(t)}</p></div>`; };
    m.el.querySelector("#mmLockOut")?.addEventListener("click", () => endSession("local"));
    const finish = () => { ls.set(K_LOCK, ""); markActive(true); m.close(); locking = null; done(); };
    window.addEventListener("storage", (e) => { if (e.key === K_LOCK && !e.newValue && locking) finish(); });   // unlocked in another tab
    m.el.querySelector("#mmLock")?.addEventListener("submit", async (e) => {
      e.preventDefault();
      const input = /** @type {HTMLInputElement} */ (m.el.querySelector("#mmLockCode"));
      const { data: f } = await client.auth.mfa.listFactors();
      const factor = ((f && f.totp) || []).find((x) => x.status === "verified");
      if (!factor) return msg("No authenticator is set up for this sign-in. Sign out and sign in again.");
      const { error } = await client.auth.mfa.challengeAndVerify({ factorId: factor.id, code: input.value.replace(/\D/g, "") });
      if (error) { input.select(); return msg("That code didn't work. Wait for the next code and try again."); }
      const s = await touch(true);
      if (s === "ok") return finish();
      if (s === "expired") return endSession("local", "/mirror/sign-in/?why=expired");
      msg("The code was accepted, but the Mirror is still locked. Please sign out and sign in again.");
    });
  });
  return locking;
}

/** Tells the database this sign-in is in use. Returns the session state ("ok", "locked", "expired", "signed_out"). @param {boolean} [force] */
async function touch(force = false) {
  const now = Date.now();
  if (!force && now - Number(ls.get(K_TOUCH) || 0) < 60000) return "ok";
  ls.set(K_TOUCH, String(now));
  const { data, error } = await client.rpc("mirror_session_touch");
  return error ? "ok" : (data && data.state) || "ok";      // a network hiccup is not a sign-out; the database still decides
}

/** @param {boolean} [now] */
function markActive(now = false) {
  const t = Date.now();
  if (now || t - Number(ls.get(K_ACT) || 0) > 5000) ls.set(K_ACT, String(t));
}

let watching = false;
/** Watches for inactivity on pages that have a short limit (coordinators: lock; shared device: sign out). @param {Who} w */
function watch(w) {
  if (watching || !w.session) return;
  watching = true;
  const L = w.session.limits;
  const member = !!(w.memberships && w.memberships.length) && w.aal === "aal2";
  const limitMin = member ? L.member_lock_minutes : (w.session.device === "own" ? 0 : L.shared_idle_minutes);
  const warnMs = (L.warn_seconds || 120) * 1000;
  const toExpired = () => endSession("local", "/mirror/sign-in/?next=" + encodeURIComponent(location.pathname + location.search) + "&why=expired");
  /** @param {string} s */
  const follow = (s) => { if (s === "locked") return lockScreen(); if (s === "expired" || s === "signed_out") return toExpired(); };
  // Activity is sent to the database at most once a minute (touch). The limits count from the last one sent, exactly as the database does.
  const onActivity = () => { if (locking) return; markActive(); touch().then(follow); };
  ["pointerdown", "keydown", "input", "touchstart", "wheel", "scroll"].forEach((ev) => addEventListener(ev, onActivity, { passive: true, capture: true }));
  markActive(true);

  /** @type {{ el: HTMLElement, close: () => void }|null} */ let warning = null;
  const check = async () => {
    if (locking || !limitMin) return;
    const idle = Date.now() - Number(ls.get(K_TOUCH) || Date.now());
    const left = limitMin * 60000 - idle;
    if (left <= 0) {
      warning?.close(); warning = null;
      if (member) return lockScreen();
      return endSession("local", "/mirror/sign-in/?next=" + encodeURIComponent(location.pathname + location.search) + "&why=idle");
    }
    if (left <= warnMs && !warning) {
      warning = modal(`<div role="alertdialog" aria-labelledby="mmWarnH"><h2 id="mmWarnH" style="margin-top:0">Are you still here?</h2>
        <p>${member ? "The screen will lock" : "You will be signed out"} in about ${Math.max(1, Math.round(left / 60000))} minute${left > 90000 ? "s" : ""} to keep this private.</p>
        <div class="mm-row"><button class="mm-btn" type="button" id="mmStay">Keep me signed in</button></div></div>`, "#mmStay");
      warning.el.querySelector("#mmStay")?.addEventListener("click", async () => { warning?.close(); warning = null; markActive(true); follow(await touch(true)); });
    } else if (left > warnMs && warning) { warning.close(); warning = null; }   // activity in another tab
  };
  setInterval(check, 10000);
  addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") check(); });
  addEventListener("storage", (e) => { if (e.key === K_LOCK && e.newValue && member) lockScreen(); });   // locked in another tab
}

const $ = (/** @type {string} */ id) => /** @type {HTMLInputElement} */ (document.getElementById(id));

/**
 * The full sign-in inside `el`.
 * @param {HTMLElement} el
 */
export function signInBox(el) {
  let email = "";
  let cooldownUntil = 0, cooldownTimer = 0;
  const next = safeNext(new URLSearchParams(location.search).get("next"));

  const step = (/** @type {string} */ html) => { el.innerHTML = html; };
  const msg = (/** @type {string} */ text, kind = "urgent") => {
    const m = el.querySelector("[data-msg]");
    if (m) m.innerHTML = text ? `<div class="mm-notice mm-notice-${kind}" role="alert"><p>${esc(text)}</p></div>` : "";
  };
  const busy = (/** @type {boolean} */ on) => el.querySelectorAll("button, input").forEach((x) => { /** @type {HTMLInputElement} */ (x).disabled = on; });

  const REMEMBER = "mm-signin-email";
  const remembered = () => { try { return localStorage.getItem(REMEMBER) || ""; } catch { return ""; } };
  const remember = (/** @type {string} */ v) => { try { v ? localStorage.setItem(REMEMBER, v) : localStorage.removeItem(REMEMBER); } catch { /* blocked */ } };

  async function sendCode() {
    let captchaToken;
    try { captchaToken = await turnstileToken(); } catch (e) { return /** @type {any} */ (e); }
    const { error } = await client.auth.signInWithOtp({ email, options: { shouldCreateUser: true, captchaToken } });
    if (!error) {
      cooldownUntil = Date.now() + 60000;
      // The email's "Sign in" button opens /sign-in/, which comes back here on this device.
      try { localStorage.setItem("sch-signin-return", JSON.stringify({ p: location.pathname + location.search, at: Date.now() })); } catch { /* blocked */ }
    }
    return error;
  }

  /** After the email code: who is this, authenticator if a coordinator, then home. */
  async function afterCode() {
    let w;
    try { w = await whoami(); } catch (e) { return askEmail(e instanceof Error ? e.message : String(e)); }
    if (!w.signed_in) return askEmail();
    if (w.view_as) return step(`<div class="mm-notice mm-notice-caution" role="status"><p>The Mirror is not available while viewing as someone else.</p></div>`);
    const home = homeFor(w);
    if (!home) {
      return step(`<div class="mm-card">
        <h2 style="margin-top:0">You're signed in, but not on the Mirror yet</h2>
        <p>You are signed in as <strong>${esc(w.email)}</strong>. The Mirror opens for people and coordinators once they are invited.
          If you were expecting an invitation, ask your coordinator or the 2nd Chance office.</p>
        <p class="mm-row"><button class="mm-btn mm-btn-secondary" type="button" id="mmOut">Sign out</button> <a class="mm-btn mm-btn-quiet" href="/mirror/">The Mirror home page</a></p>
      </div>`), el.querySelector("#mmOut")?.addEventListener("click", signOut);
    }
    if (w.needs_authenticator && !(await mfaGate())) return;
    try { await ensureDevice(w); } catch { /* asked again on the next page */ }
    markActive(true); await touch(true);
    location.replace(next && (next.startsWith(home) || (home === "/mirror/workspace/" && next.startsWith("/mirror/"))) ? next : home);
  }

  // ---------------------------------------------------------------- authenticator (coordinators, D-13)
  async function mfaGate() {
    const { data: a } = await client.auth.mfa.getAuthenticatorAssuranceLevel();
    if (a && a.currentLevel === "aal2") return true;
    const { data: f } = await client.auth.mfa.listFactors();
    const verified = ((f && f.totp) || []).find((x) => x.status === "verified");
    return new Promise((done) => (verified ? askApp(verified.id, done) : setupApp(f, done)));
  }

  /** @param {string} factorId @param {(ok: boolean) => void} done */
  function askApp(factorId, done) {
    step(`<form class="mm-card" id="mmApp" novalidate>
      <h2 style="margin-top:0">Enter your authenticator code</h2>
      <p class="mm-muted">Coordinators use a second step. Open your authenticator app and type the 6-digit code for <strong>2nd Chance Housing</strong>. It changes every 30 seconds.</p>
      <div class="mm-field"><label for="mmAppCode">Authenticator code</label>
        <input class="mm-input" id="mmAppCode" inputmode="numeric" autocomplete="one-time-code" maxlength="6" data-mm-no-voice required></div>
      <div data-msg></div>
      <div class="mm-row"><button class="mm-btn" type="submit">Continue</button><button class="mm-btn mm-btn-quiet" type="button" id="mmOut">Sign out</button></div>
      <p class="mm-muted mm-small">Lost your phone or changed apps? Call the 2nd Chance office at <a href="tel:+12622365443">(262) 236-5443</a> and we'll reset it.</p>
    </form>`);
    $("mmAppCode").focus();
    el.querySelector("#mmOut")?.addEventListener("click", signOut);
    el.querySelector("#mmApp")?.addEventListener("submit", async (e) => {
      e.preventDefault(); busy(true);
      const { error } = await client.auth.mfa.challengeAndVerify({ factorId, code: $("mmAppCode").value.replace(/\D/g, "") });
      busy(false);
      if (error) return msg("That code didn't work. Wait for the next code and try again.");
      done(true);
    });
  }

  /** @param {any} f @param {(ok: boolean) => void} done */
  async function setupApp(f, done) {
    for (const x of ((f && f.all) || []).filter((/** @type {any} */ y) => y.status === "unverified")) await client.auth.mfa.unenroll({ factorId: x.id });
    const { data, error } = await client.auth.mfa.enroll({ factorType: "totp", friendlyName: "2nd Chance Housing " + new Date().toISOString().slice(0, 10) });
    if (error || !data) return step(`<div class="mm-notice mm-notice-urgent" role="alert"><p>${esc(error?.message || "We couldn't start the setup.")} Call (262) 236-5443 for help.</p></div>`);
    step(`<form class="mm-card" id="mmApp" novalidate>
      <h2 style="margin-top:0">Set up your authenticator app</h2>
      <p class="mm-muted">Coordinators use a second step to protect the people they work with. It takes a minute, once.</p>
      <ol class="mm-steps"><li>Install an authenticator app on your phone (Google Authenticator, Microsoft Authenticator, Authy or 1Password).</li>
        <li>In the app, add an account and scan this code.</li><li>Type the 6-digit code the app shows.</li></ol>
      <p style="text-align:center"><img alt="QR code to scan with your authenticator app" src="${esc(data.totp.qr_code)}" width="190" height="190" style="background:#fff;padding:6px;border-radius:8px"></p>
      <p class="mm-muted mm-small" style="text-align:center">Can't scan? Type this key into the app:<br><code style="user-select:all;word-break:break-all">${esc(data.totp.secret)}</code></p>
      <div class="mm-field"><label for="mmAppCode">Code from the app</label>
        <input class="mm-input" id="mmAppCode" inputmode="numeric" autocomplete="one-time-code" maxlength="6" data-mm-no-voice required></div>
      <div data-msg></div>
      <div class="mm-row"><button class="mm-btn" type="submit">Turn on and continue</button><button class="mm-btn mm-btn-quiet" type="button" id="mmOut">Sign out</button></div>
    </form>`);
    $("mmAppCode").focus();
    el.querySelector("#mmOut")?.addEventListener("click", signOut);
    el.querySelector("#mmApp")?.addEventListener("submit", async (e) => {
      e.preventDefault(); busy(true);
      const { error: err } = await client.auth.mfa.challengeAndVerify({ factorId: data.id, code: $("mmAppCode").value.replace(/\D/g, "") });
      busy(false);
      if (err) return msg("That code didn't match. Make sure you scanned the code above, then type the new 6-digit number.");
      done(true);
    });
  }

  // ---------------------------------------------------------------- email and code
  const WHY = /** @type {Record<string, string>} */ ({
    idle: "You were signed out after 30 minutes without activity, to keep your answers private on a shared device. Sign in again to continue where you were.",
    expired: "Your sign-in on this device has expired. Sign in again to continue where you were.",
    closed: "You were signed out because the browser was closed on a shared device. Sign in again to continue.",
  });
  let why = WHY[new URLSearchParams(location.search).get("why") || ""] || "";

  function askEmail(error = "") {
    if (!email) email = remembered();
    step(`<form class="mm-card" id="mmEmail" novalidate>
      <h2 style="margin-top:0">Sign in</h2>
      ${why ? `<div class="mm-notice mm-notice-info" role="status"><p>${esc(why)}</p></div>` : ""}
      <p class="mm-muted">We'll email you a 6-digit code. No password to remember.</p>
      <div class="mm-field"><label for="mmEmailInput">Your email address</label>
        <input class="mm-input" type="email" id="mmEmailInput" autocomplete="email" required value="${esc(email)}"></div>
      <fieldset class="mm-field" style="border:0;padding:0;margin-inline:0"><legend>Is this your own phone or computer?</legend>
        <label class="mm-choice"><input type="radio" name="mmDevice" value="own"> Yes, it's mine. Only I use it.</label>
        <label class="mm-choice"><input type="radio" name="mmDevice" value="shared"> No, it's shared or public (library, shelter, a friend's phone)</label>
        <span class="mm-hint">On a shared device you are signed out after 30 minutes without activity and when the browser closes.</span></fieldset>
      <label class="mm-choice" id="mmRememberRow" style="margin-bottom:var(--mm-space-4)"><input type="checkbox" id="mmRemember" ${remembered() ? "checked" : ""}> Remember my email on this device</label>
      <div data-msg></div>
      <div class="mm-row"><button class="mm-btn" type="submit">Email me a code</button></div>
    </form>`);
    why = "";
    if (error) msg(error);
    $("mmEmailInput").focus();
    const device = () => /** @type {HTMLInputElement|null} */ (el.querySelector('input[name="mmDevice"]:checked'))?.value || "";
    el.querySelectorAll('input[name="mmDevice"]').forEach((r) => r.addEventListener("change", () => {
      const shared = device() === "shared";
      /** @type {HTMLElement} */ (el.querySelector("#mmRememberRow")).hidden = shared;
      if (shared) { $("mmRemember").checked = false; remember(""); }
    }));
    el.querySelector("#mmEmail")?.addEventListener("submit", async (e) => {
      e.preventDefault();
      email = $("mmEmailInput").value.trim().toLowerCase();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return msg("Enter your full email address, for example name@example.com.");
      if (!device()) return msg("Choose whether this is your own phone or computer, or a shared one.");
      try { sessionStorage.setItem(K_PENDING, device()); } catch { /* asked again after the code */ }
      busy(true);
      const err = await sendCode();
      busy(false);
      if (err) return msg(err.status === 429 ? "Too many requests. Wait a minute and try again." : await errorText(err));
      remember(device() === "own" && $("mmRemember").checked ? email : "");
      askCode();
    });
  }

  function askCode() {
    step(`<form class="mm-card" id="mmCode" novalidate>
      <h2 style="margin-top:0">Check your email</h2>
      <p class="mm-muted">If <strong>${esc(email)}</strong> has been invited to the Mirror, a 6-digit code is on its way from 2nd Chance Housing.
        It can take a minute; check spam too. You can type the code here or press the Sign in button in the email.</p>
      <div class="mm-field"><label for="mmCodeInput">Code from the email</label>
        <input class="mm-input" id="mmCodeInput" inputmode="numeric" autocomplete="one-time-code" maxlength="6" data-mm-no-voice required></div>
      <div data-msg></div>
      <div class="mm-row"><button class="mm-btn" type="submit">Continue</button>
        <button class="mm-btn mm-btn-quiet" type="button" id="mmResend"></button>
        <button class="mm-btn mm-btn-quiet" type="button" id="mmRestart">Use a different email</button></div>
    </form>`);
    $("mmCodeInput").focus();
    const tick = () => {
      const left = Math.ceil((cooldownUntil - Date.now()) / 1000), b = /** @type {HTMLButtonElement|null} */ (el.querySelector("#mmResend"));
      if (!b) return clearInterval(cooldownTimer);
      b.disabled = left > 0; b.textContent = left > 0 ? `Send a new code in ${left}s` : "Send a new code";
      if (left <= 0) clearInterval(cooldownTimer);
    };
    clearInterval(cooldownTimer); cooldownTimer = window.setInterval(tick, 1000); tick();
    const { data: sub } = client.auth.onAuthStateChange((ev) => {     // the email's Sign in button used in another tab
      if (ev !== "SIGNED_IN" || verifying || !el.querySelector("#mmCodeInput")) return;
      sub.subscription.unsubscribe(); clearInterval(cooldownTimer); setTimeout(afterCode, 0);
    });
    el.querySelector("#mmRestart")?.addEventListener("click", () => { clearInterval(cooldownTimer); sub.subscription.unsubscribe(); askEmail(); });
    el.querySelector("#mmResend")?.addEventListener("click", async () => {
      busy(true); const err = await sendCode(); busy(false);
      clearInterval(cooldownTimer); cooldownTimer = window.setInterval(tick, 1000); tick();
      if (err) return msg(err.status === 429 ? "Too many requests. Wait a minute and try again." : await errorText(err));
      msg("A new code is on its way. Use the newest email.", "ok");
      $("mmCodeInput").value = ""; $("mmCodeInput").focus();
    });
    let verifying = false;
    const verify = async () => {
      if (verifying) return;
      const token = $("mmCodeInput").value.replace(/\D/g, "");
      if (token.length !== 6) return msg("Enter all 6 digits from the email.");
      verifying = true; busy(true);
      const { error } = await client.auth.verifyOtp({ email, token, type: "email" });
      verifying = false; busy(false); tick();
      if (error) { $("mmCodeInput").select(); return msg("That code didn't work. It may have expired; press Send a new code."); }
      clearInterval(cooldownTimer); sub.subscription.unsubscribe();
      afterCode();
    };
    el.querySelector("#mmCode")?.addEventListener("submit", (e) => { e.preventDefault(); verify(); });
    $("mmCodeInput").addEventListener("input", () => { if ($("mmCodeInput").value.replace(/\D/g, "").length === 6) verify(); });
  }

  client.auth.getSession().then(({ data }) => {
    if (data.session) { email = data.session.user.email || ""; afterCode(); } else askEmail();
  });
}

/**
 * Guard for an area page. Resolves with who when the person belongs here; otherwise sends them on and never resolves.
 * @param {"my"|"workspace"} area
 * @returns {Promise<Who>}
 */
/**
 * A "My Mirror" page opened by a sign-in that has no Mirror of its own (for example the office's organization login).
 * Says so plainly instead of jumping to another page without a word (Stephen 11/13/2026: "link does not work").
 * @param {Who} w @param {boolean} isMember
 */
function noMirrorHere(w, isMember) {
  const main = document.querySelector("main") || document.body;
  main.innerHTML = `<div class="mm-read">
    <p class="mm-eyebrow">My Mirror</p>
    <h1>This sign-in has no Mirror of its own</h1>
    <p>You are signed in as <strong>${esc(w.email || "")}</strong>.
      ${isMember ? "That is an organization login: it works with other people's Mirrors in the Workspace, but it has no Mirror of its own."
        : "There is no Mirror for this sign-in yet. The Mirror opens for people once an organization invites them."}</p>
    <p>To see your own Mirror, sign out and sign in with the email that has one.</p>
    <p class="mm-row">${isMember ? '<a class="mm-btn" href="/mirror/workspace/">Go to the Workspace</a>' : ""}
      <button class="mm-btn mm-btn-secondary" type="button" id="mmNoMirrorOut">Sign out</button></p>
  </div>`;
  main.querySelector("#mmNoMirrorOut")?.addEventListener("click", signOut);
}

export async function requireArea(area) {
  const toSignIn = (why = "") => { goSignIn(why); return new Promise(() => {}); };
  let w;
  try { w = await whoami(); } catch { return toSignIn(); }
  if (!w.signed_in || w.view_as) return toSignIn(w.expired ? "expired" : "");
  if (w.session && w.session.device === "shared" && !hasSharedCookie()) {   // the browser was closed since: forget this sign-in
    try { await client.auth.signOut({ scope: "local" }); } catch { /* already gone */ }
    clearDevice();
    return toSignIn("closed");
  }
  const isMember = !!(w.memberships && w.memberships.length);
  if (area === "workspace" && (!isMember || w.needs_authenticator)) { if (isMember) return toSignIn(); location.replace(homeFor(w) || "/mirror/sign-in/"); return new Promise(() => {}); }
  if (area === "my" && !w.person) { noMirrorHere(w, isMember); return new Promise(() => {}); }
  if (w.locked || (isMember && ls.get(K_LOCK))) {
    if (!w.locked && (await touch(true)) === "ok") ls.set(K_LOCK, "");     // the flag was stale (unlocked elsewhere)
    else { await lockScreen(); w = await whoami(); }
  }
  try { await ensureDevice(w); w = await whoami(); } catch { /* the database still applies the shared-device limit */ }
  const s = await touch(true);
  if (s === "expired" || s === "signed_out") return toSignIn("expired");
  if (s === "locked") await lockScreen();
  watch(w);
  changeNotice(w);
  return w;
}

/**
 * The privacy page's promise (migration 20261119698000): a change in how information is used or shared is shown at sign-in,
 * before it starts, until the person presses "I've read it". Built with textContent, so the notice text is never read as HTML.
 * @param {any} w
 */
function changeNotice(w) {
  const n = w && w.change_notice;
  const main = document.querySelector("main");
  if (!n || !n.id || !main || document.getElementById("mmChangeNotice")) return;
  const box = document.createElement("section");
  box.id = "mmChangeNotice"; box.className = "mm-card"; box.setAttribute("aria-labelledby", "mmChangeNoticeH");
  box.style.cssText = "margin-bottom:var(--mm-space-5);border:2px solid var(--mm-accent, #1f5f8b)";
  const h = document.createElement("h2"); h.id = "mmChangeNoticeH"; h.style.marginTop = "0"; h.textContent = "A change to how we use or share information";
  const p = document.createElement("p"); p.textContent = String(n.text || "");
  const when = document.createElement("p"); when.className = "mm-small";
  when.textContent = n.starts ? "It starts on " + new Date(String(n.starts) + "T12:00:00").toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }) + ". " : "";
  const a = document.createElement("a"); a.href = "/mirror/privacy/"; a.textContent = "Read the privacy page"; when.append(a);
  const b = document.createElement("button"); b.type = "button"; b.className = "mm-btn"; b.textContent = "I've read it";
  b.addEventListener("click", async () => {
    b.disabled = true;
    const { error } = await client.rpc("mirror_notice_seen", { p_id: String(n.id) });
    if (error) { b.disabled = false; return; }
    box.remove();
  });
  box.append(h, p, when, b);
  main.prepend(box);
}

/**
 * Calls a public.mirror_* database function. Throws an Error with a plain message the page can show.
 * When the refusal is the screen lock or an expired sign-in, it shows the lock or goes to sign in instead.
 * @param {string} fn @param {Record<string, unknown>} [args]
 */
export async function rpc(fn, args) {
  const { data, error } = await client.rpc(fn, args);
  if (error) {
    const text = await errorText(error);
    if (error.code === "42501" && fn !== "mirror_session_touch") {
      const s = await touch(true);
      if (s === "locked") { await lockScreen(); return rpc(fn, args); }      // try again once unlocked
      if (s === "expired" || s === "signed_out") { goSignIn("expired"); return new Promise(() => {}); }
    }
    throw new Error(text);
  }
  return data;
}
