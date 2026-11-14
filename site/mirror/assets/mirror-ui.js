// @ts-check
// The Human Mirror: page shell and small UI components (T1.1). No data calls here (see mirror-client.js, T1.3).
//
// A page is:   <body data-area="public|my|workspace|admin">  <main id="main" class="mm-main"> ... </main>
//              <script type="module" src="/mirror/assets/mirror-ui.js?v=..."></script>
// The shell (skip link, header, nav, footer) is added around <main> on load, so every page stays a few lines of HTML.

/** @typedef {"public" | "my" | "workspace" | "admin"} Area */
/** @typedef {{ href: string, label: string }} NavLink */

/** Navigation per area. Kept short (prompt Part 12: simple navigation, no overwhelming dashboards). @type {Record<Area, NavLink[]>} */
export const NAV = {
  public: [
    { href: "/mirror/", label: "Home" },
    { href: "/mirror/how-it-works/", label: "How it works" },
    { href: "/mirror/life-dimensions/", label: "Life dimensions" },
    { href: "/mirror/daily-number/", label: "Daily Number" },
    { href: "/mirror/about/", label: "About" },
    { href: "/mirror/privacy/", label: "Privacy" },
    { href: "/mirror/sign-in/", label: "Sign in" },
  ],
  // Only pages that exist (11/13/2026); each area's other pages are added here as they are built.
  my: [
    { href: "/mirror/my-mirror/", label: "My Mirror" },
    { href: "/mirror/my-mirror/life/", label: "Areas of life" },
    { href: "/mirror/my-mirror/daily-number/", label: "Daily Number" },
    { href: "/mirror/my-mirror/settings/", label: "Settings" },
    { href: "/mirror/how-it-works/", label: "How it works" },
    { href: "/mirror/privacy/", label: "Privacy" },
  ],
  workspace: [
    { href: "/mirror/workspace/", label: "Dashboard" },
    { href: "/mirror/workspace/people/", label: "People" },
    { href: "/mirror/demo/conversation/", label: "Conversation guide" },
    { href: "/mirror/admin/", label: "Admin" },
  ],
  admin: [
    { href: "/mirror/admin/", label: "Organizations and members" },
    { href: "/mirror/workspace/", label: "Workspace" },
    { href: "/mirror/workspace/people/", label: "People" },
  ],
};

const AREA_NAME = { public: "", my: "My Mirror", workspace: "Workspace", admin: "Administration" };

/** Escapes text for HTML. @param {unknown} s */
export const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => /** @type {Record<string,string>} */ ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

/** localStorage that never throws (private windows, blocked storage). */
const store = {
  /** @param {string} k */ get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  /** @param {string} k @param {string} v */ set(k, v) { try { localStorage.setItem(k, v); } catch { /* ignore */ } },
};

/** Applies the person's remembered text size before the page paints. */
function applyTextSize() {
  if (store.get("mm-text") === "large") document.documentElement.dataset.text = "large";
}

/** True when `href` is the current page or (for section links) a parent of it. @param {string} href */
function isCurrent(href) {
  const here = location.pathname.endsWith("/") ? location.pathname : location.pathname + "/";
  return here === href;
}

/** Builds the skip link, header, nav and footer around <main id="main">. */
export function renderShell() {
  applyTextSize();
  const body = document.body;
  const area = /** @type {Area} */ (body.dataset.area && body.dataset.area in NAV ? body.dataset.area : "public");
  const main = document.getElementById("main");
  if (!main) return;
  main.tabIndex = -1;

  const skip = document.createElement("a");
  skip.className = "mm-skip"; skip.href = "#main"; skip.textContent = "Skip to main content";

  const links = NAV[area].map((l) =>
    `<li><a href="${esc(l.href)}"${isCurrent(l.href) ? ' aria-current="page"' : ""}>${esc(l.label)}</a></li>`).join("");
  const header = document.createElement("header");
  header.className = "mm-header";
  header.innerHTML = `
    <div class="mm-header-inner">
      <a class="mm-wordmark" href="${area === "public" ? "/mirror/" : esc(NAV[area][0].href)}">
        <strong>The Human Mirror</strong>
        <span>${AREA_NAME[area] ? esc(AREA_NAME[area]) : "Discover Yourself. Define Your Future. Build Your Life."}</span>
      </a>
      <button type="button" class="mm-btn mm-btn-quiet" data-mm-text aria-pressed="false">Larger text</button>
      <button type="button" class="mm-btn mm-btn-secondary mm-nav-toggle" aria-expanded="false" aria-controls="mm-nav">Menu</button>
      <nav class="mm-nav" id="mm-nav" aria-label="${esc(AREA_NAME[area] || "The Human Mirror")}" data-open="false"><ul>${links}</ul></nav>
    </div>`;

  const footer = document.createElement("footer");
  footer.className = "mm-footer";
  footer.innerHTML = `
    <div class="mm-footer-inner">
      <span>The Human Mirror, a 2nd Chance Housing project</span>
      <a href="/mirror/privacy/">Privacy</a>
      <a href="/mirror/accessibility/">Accessibility</a>
      <a href="/mirror/forgot-password/">Can't sign in?</a>
    </div>`;

  body.prepend(skip, header);
  body.append(footer);

  // mobile menu
  const toggle = /** @type {HTMLButtonElement} */ (header.querySelector(".mm-nav-toggle"));
  const nav = /** @type {HTMLElement} */ (header.querySelector(".mm-nav"));
  toggle.addEventListener("click", () => {
    const open = nav.dataset.open !== "true";
    nav.dataset.open = String(open); toggle.setAttribute("aria-expanded", String(open));
  });

  // text size
  const textBtn = /** @type {HTMLButtonElement} */ (header.querySelector("[data-mm-text]"));
  const syncText = () => {
    const large = document.documentElement.dataset.text === "large";
    textBtn.setAttribute("aria-pressed", String(large));
    textBtn.textContent = large ? "Standard text" : "Larger text";
  };
  textBtn.addEventListener("click", () => {
    const large = document.documentElement.dataset.text !== "large";
    if (large) document.documentElement.dataset.text = "large"; else delete document.documentElement.dataset.text;
    store.set("mm-text", large ? "large" : "standard");
    syncText();
  });
  syncText();
}

/**
 * A count of things done, shown as words and a bar. Never a score of the person (D-09).
 * @param {number} done @param {number} total @param {string} label e.g. "questions answered"
 */
export function countBar(done, total, label) {
  const d = Math.max(0, Math.min(done, total));
  const pct = total > 0 ? Math.round((d / total) * 100) : 0;
  return `<div class="mm-count">
    <div class="mm-count-label"><span>${esc(d)} of ${esc(total)} ${esc(label)}</span></div>
    <div class="mm-count-bar" role="img" aria-label="${esc(d)} of ${esc(total)} ${esc(label)}"><span style="width:${pct}%"></span></div>
  </div>`;
}

/** @param {"info"|"ok"|"caution"|"urgent"} kind @param {string} html trusted HTML (escape any user text first) */
export function notice(kind, html) {
  return `<div class="mm-notice${kind === "info" ? "" : " mm-notice-" + kind}" role="${kind === "urgent" ? "alert" : "status"}">${html}</div>`;
}

let toastTimer = 0;
/** A short status message read out by screen readers. @param {string} text */
export function toast(text) {
  let el = document.getElementById("mm-toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "mm-toast"; el.className = "mm-toast"; el.setAttribute("role", "status"); el.setAttribute("aria-live", "polite");
    document.body.append(el);
  }
  el.textContent = text; el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => { if (el) el.hidden = true; }, 4000);
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", renderShell);
else renderShell();
