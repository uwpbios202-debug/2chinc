// One staff menu for every staff page. A page opts in with data-nav="staff" on its .appbar;
// after sign-in, portal.js calls staffNav(who) and the page's own links in #userBar are
// replaced by this menu (links with an id, like "My owner page", are kept). Add a page here
// once and it shows up everywhere.

const OFFICE = [
  ["My units", [["My units", "/staff/"]]],
  ["Leasing", [
    ["Applications", "/leasing/applications/"],
    ["Rentals", "/leasing/leases/"],
    ["Countersign", "/leasing/countersign/"],
    ["Renewals", "/leasing/renewals/"],
    ["Household", "/leasing/household/"],
    ["Work in lieu", "/leasing/work/"],
  ]],
  ["Move-ins & inspections", [
    ["Move-ins", "/inspections/move-in/"],
    ["Move-outs", "/inspections/move-out/"],
    ["Inspection reports", "/inspections/review/"],
    ["Inspection schedule", "/inspections/schedule/"],
  ]],
  ["Residents", [
    ["Maintenance", "/maintenance/"],
    ["Messages", "/resident/messages/"],
    ["Problem reports", "/staff/reports/"],
    ["Letters", "/documents/letters/"],
    ["Notices", "/documents/notices/"],
    ["Parking", "/parking/"],
    ["Keys", "/staff/keys/"],
    ["Email a unit", "/staff/email/"],
    ["Email a W-9", "/staff/w9/"],
    ["Caseworkers", "/staff/caseworkers/"],
    ["Snow removal", "/staff/snow/"],
    ["Waitlist", "/staff/waitlist/"],
    ["Quit claim deeds", "/staff/deeds/"],
    ["Transfer after a death", "/staff/deeds/transfer/"],
    ["Title transfer: 8135 S. Stony Island", "/staff/deeds/transfer/"],
  ]],
  ["Money", [
    ["Payments", "/accounting/tenant-side/payments/"],
    ["Bank deposits", "/accounting/bank/"],
    ["Autopay", "/accounting/autopay/"],
    ["Housing assistance", "/accounting/assistance/"],
    ["Charge disputes", "/accounting/disputes/"],
    ["Reports", "/accounting/reports/"],
  ]],
  ["ROCA1", [
    ["Owners", "/association-owners/roca1/staff/"],
    ["Owner requests", "/association-owners/roca1/requests/"],
    ["Dues", "/association-owners/roca1/dues/"],
    ["Board & budget", "/association-owners/roca1/board/"],
    ["Violations", "/association-owners/roca1/violations/"],
    ["Violations, notes & board", "/association-owners/roca1/records/"],
    ["Rent deductions", "/association-owners/roca1/distributions/"],
  ]],
];

// Field staff see only what the My units page offers them.
const FIELD = [
  ["My units", [["My units", "/staff/"]]],
  ["Field work", [
    ["Inspection reports", "/inspections/review/"],
    ["Parking", "/parking/"],
    ["Work in lieu", "/leasing/work/"],
  ]],
];

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

export function staffNav(who) {
  const bar = document.querySelector('.appbar[data-nav="staff"] #userBar');
  if (!bar || !who || !["staff", "field"].includes(who.role)) return;
  const groups = who.role === "staff" ? OFFICE : FIELD;
  // The current page is the menu link with the longest address that this page's address starts with.
  const current = groups.flatMap(([, ls]) => ls.map(([, h]) => h)).filter((h) => location.pathname.startsWith(h)).sort((a, b) => b.length - a.length)[0];
  const here = (h) => h === current;
  bar.querySelectorAll("a.linkbtn:not([id])").forEach((a) => a.remove());
  const nav = document.createElement("nav");
  nav.className = "staffnav";
  nav.setAttribute("aria-label", "Staff");
  nav.innerHTML = groups.map(([name, links]) => {
    const on = links.some(([, h]) => here(h));
    if (links.length === 1) {
      const [label, h] = links[0];
      return `<a class="navtop${on ? " on" : ""}" href="${h}"${on ? ' aria-current="page"' : ""}>${esc(label)}</a>`;
    }
    return `<details class="navgrp${on ? " on" : ""}"><summary>${esc(name)}</summary><div class="navpop">${
      links.map(([label, h]) => `<a href="${h}"${here(h) ? ' aria-current="page"' : ""}>${esc(label)}</a>`).join("")
    }</div></details>`;
  }).join("");
  bar.prepend(nav);
  // One menu open at a time; a click outside or Escape closes it.
  const all = [...nav.querySelectorAll("details")];
  all.forEach((d) => d.addEventListener("toggle", () => { if (d.open) all.forEach((o) => { if (o !== d) o.open = false; }); }));
  document.addEventListener("click", (e) => { if (!nav.contains(e.target)) all.forEach((d) => { d.open = false; }); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") all.forEach((d) => { d.open = false; }); });
}
