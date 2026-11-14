import fs from "fs";
const f = "site/staff/efile/index.html";
let s = fs.readFileSync(f, "utf8");
const BTN = `<a class="btn" href="https://efiling.wicourts.gov/" target="_blank" rel="noopener">Open the court's eFiling sign-in</a>`;
const rep = (a, b) => { if (!s.includes(a)) throw new Error("missing: " + a.slice(0, 60)); s = s.replace(a, b); };
rep(`Rent only: late fees are never part of a filing.</p></header>`,
  `Rent only: late fees are never part of a filing.</p>
    <p class="noprint" style="margin-top:8px">${BTN} <span class="meta">Sign in to the shared 2nd Chance/ROCA1 eFiling account. Chrome's password manager fills the username and password; the court then emails a 6-digit code.</span></p></header>`);
rep(`"Open the sheet and checklist"}</a></div>`, `"Open the sheet and checklist"}</a>${BTN}</div>`);
rep(`<a class="btn" href="\${SC500_ES}" target="_blank" rel="noopener">English/Spanish SC-500 (wicourts.gov)</a>`,
  `${BTN}<a class="btn" href="\${SC500_ES}" target="_blank" rel="noopener">English/Spanish SC-500 (wicourts.gov)</a>`);
rep(`as <b>Albert Harris</b> (his own account, never a former member's).`,
  `with the <b>shared 2nd Chance/ROCA1 eFiling account</b> (the court emails a 6-digit code to sign in).`);
fs.writeFileSync(f, s);
console.log("ok");
