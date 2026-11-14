// One color system for every balance, in every portal (tenants, owners, staff). Stephen, 10/30/2026.
//   Balance due   = red    (the person owes money)     "$X due"
//   Zero balance  = green  (settled)                   "Paid up"
//   Credit        = blue   (money in their favor)      "Credit $X"
// New file on purpose: portal.js is cached by browsers for hours, so new exports live here.
import { money } from "/assets/portal/portal.js";

if (typeof document !== "undefined" && !document.getElementById("balColors")) {
  const st = document.createElement("style");
  st.id = "balColors";
  st.textContent = `:root{--b-due:#b03a2e;--b-zero:#237347;--b-credit:#1f5f99}
@media (prefers-color-scheme:dark){:root{--b-due:#ef8a7e;--b-zero:#6cc593;--b-credit:#6ea8de}}
.b-due{color:var(--b-due);font-weight:700}.b-zero{color:var(--b-zero);font-weight:700}.b-credit{color:var(--b-credit);font-weight:700}`;
  document.head.appendChild(st);
}

const num = (n) => Number(n) || 0;
// "b-due", "b-zero" or "b-credit" for a balance (positive = owed).
export const balClass = (n) => num(n) > 0.004 ? "b-due" : num(n) < -0.004 ? "b-credit" : "b-zero";
// Words: "$X due", "Paid up", "Credit $X", colored.
export const balText = (n) => `<span class="${balClass(n)}">${num(n) > 0.004 ? `${money(n)} due` : num(n) < -0.004 ? `Credit ${money(-num(n))}` : "Paid up"}</span>`;
// The amount only, colored (for tables and key/value rows): $X, $0.00, or "Credit $X".
export const balAmt = (n) => n == null || n === "" ? "—" : `<span class="${balClass(n)}">${num(n) < -0.004 ? `Credit ${money(-num(n))}` : money(n)}</span>`;
