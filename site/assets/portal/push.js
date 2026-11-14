// "Turn on phone alerts" (resident and owner portals, Parking page). Free web push; no text messages.
// Works out the phone and shows only the steps for it. iPhone: alerts work only from the portal added to the Home Screen (iOS 16.4+).
// Database: supabase/migrations/20261118160000_phone_alerts_push.sql. Alerts are shown by /sw.js.
import { client, esc, errorText } from "/assets/portal/portal.js";

const CSS = `
.ph{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px;margin:0 0 14px}
.ph h2{margin:0 0 6px;font-size:1.1rem}.ph p{margin:6px 0}.ph .sub{color:#5b6573;font-size:.9rem}
.ph ol{margin:6px 0 6px 20px;padding:0}.ph li{margin:4px 0}
.ph .go{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:10px 20px;font-weight:700;cursor:pointer;font-size:1rem}
.ph .go:disabled{opacity:.5;cursor:not-allowed}.ph .link{background:none;border:0;color:#5b6573;text-decoration:underline;cursor:pointer;padding:0;font:inherit;font-size:.85rem}
.ph .on{color:#2e7d1f;font-weight:700}.ph .err{color:#b3261e}.ph.okbox{border-color:#9fd18f;background:#f3faf0}`;

const ua = navigator.userAgent || "";
const isIOS = /iPhone|iPad|iPod/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const isAndroid = /Android/.test(ua);
const standalone = window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
const iosOtherBrowser = isIOS && /CriOS|FxiOS|EdgiOS|OPiOS/.test(ua);
const device = isIOS ? "iPhone" : isAndroid ? "Android" : "Computer";
const supported = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

function keyBytes(b64) {
  const s = atob((b64 + "=".repeat((4 - (b64.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

export async function mountPushCard(el) {
  if (!el) return;
  if (!document.getElementById("ph-css")) { const s = document.createElement("style"); s.id = "ph-css"; s.textContent = CSS; document.head.appendChild(s); }
  const home = location.pathname.startsWith("/association-owners/") ? "ROCA1 Owners" : location.pathname.startsWith("/unit-access/") ? "Parking & Keys" : "2nd Chance";
  let reg = null, sub = null;
  if (supported) {
    try { reg = await navigator.serviceWorker.register("/sw.js"); sub = await reg.pushManager.getSubscription(); } catch (e) { reg = null; }
  }
  const { data: cfg } = await client.rpc("push_config", { p_endpoint: sub ? sub.endpoint : "" });
  const C = cfg || {};

  const box = (inner, cls = "") => { el.innerHTML = `<div class="ph ${cls}"><h2>📱 Phone alerts</h2>${inner}<p class="err" id="phMsg" role="status"></p></div>`; };

  // iPhone not yet on the Home Screen (or in Chrome on iPhone): alerts cannot work there, so show how to add it.
  if (isIOS && !standalone) {
    box(`<p>Get a pop-up on your iPhone the moment someone parks in your stall (and other urgent notices). It is free. On iPhone it takes one minute:</p>
      <ol>${iosOtherBrowser ? `<li>Open this page in <b>Safari</b> (the blue compass app), not this browser.</li>` : ""}
        <li>Tap the <b>Share</b> button <span aria-hidden="true">(the square with an arrow pointing up)</span> at the bottom of Safari.</li>
        <li>Scroll down and tap <b>Add to Home Screen</b>, then <b>Add</b>.</li>
        <li>Close Safari. Open the new <b>${esc(home)}</b> icon on your Home Screen and sign in.</li>
        <li>Go to <b>Parking</b> and tap <b>Turn on phone alerts</b>, then <b>Allow</b>.</li></ol>
      <p class="sub">Needs iOS 16.4 or newer (Settings, General, About, iOS Version). Until then you still get every alert by email.</p>`);
    return;
  }
  if (!supported || !reg) {
    box(`<p class="sub">This browser cannot show phone alerts. You still get every alert by email. On a phone, use <b>Chrome</b> (Android) or <b>Safari</b> (iPhone) and open this page again.</p>`);
    return;
  }
  if (Notification.permission === "denied") {
    box(`<p><b>Alerts are blocked on this ${esc(device === "Computer" ? "computer" : "phone")}.</b> To allow them:</p>
      ${isIOS ? `<ol><li>Open <b>Settings</b>, then <b>Notifications</b>.</li><li>Tap <b>${esc(home)}</b> and switch on <b>Allow Notifications</b>.</li><li>Come back here; it will say alerts are on.</li></ol>`
        : isAndroid ? `<ol><li>In Chrome, tap the icon left of the web address (a lock or sliders).</li><li>Tap <b>Permissions</b> (or <b>Notifications</b>) and choose <b>Allow</b>.</li><li>Reload this page and tap <b>Turn on phone alerts</b>.</li></ol>`
        : `<ol><li>Click the icon left of the web address.</li><li>Set <b>Notifications</b> to <b>Allow</b>, then reload this page.</li></ol>`}`);
    return;
  }
  if (sub && C.on && Notification.permission === "granted") {
    box(`<p class="on">✓ Phone alerts are on for this ${esc(device === "Computer" ? "computer" : "phone")}.</p>
      <p class="sub">You'll get a pop-up when someone parks in a stall without permission. Email alerts continue too.${isIOS ? " Keep the " + esc(home) + " icon on your Home Screen." : ""}</p>
      <button class="link" type="button" id="phOff">Turn off phone alerts on this device</button>`, "okbox");
    el.querySelector("#phOff").onclick = async () => {
      await client.rpc("push_unsubscribe", { p_endpoint: sub.endpoint }); try { await sub.unsubscribe(); } catch (e) { /* ignore */ } mountPushCard(el);
    };
    return;
  }
  box(`<p>Get a <b>pop-up on this ${esc(device === "Computer" ? "computer" : "phone")}</b> the moment someone parks in your stall without permission, so you can move your car or have one towed. It is free.</p>
    <button class="go" type="button" id="phOn" ${C.view_as ? "disabled" : ""}>Turn on phone alerts</button>
    <p class="sub">${C.view_as ? "Off in View as: it would send this person's alerts to your device." : "When your phone asks, tap <b>Allow</b>."}${C.devices ? ` You have alerts on for ${C.devices} other device${C.devices === 1 ? "" : "s"}.` : ""}</p>`);
  el.querySelector("#phOn").onclick = async () => {
    const m = el.querySelector("#phMsg"), b = el.querySelector("#phOn");
    b.disabled = true; m.textContent = "";
    try {
      if (!C.public_key) throw new Error("Phone alerts are not switched on yet. You still get email alerts.");
      const perm = await Notification.requestPermission();
      if (perm !== "granted") { mountPushCard(el); return; }
      const s = sub || await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(C.public_key) });
      const j = s.toJSON();
      const { error } = await client.rpc("push_subscribe", { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_device: device });
      if (error) throw new Error(await errorText(error));
      mountPushCard(el);
    } catch (e) { m.textContent = e.message || String(e); b.disabled = false; }
  };
}
