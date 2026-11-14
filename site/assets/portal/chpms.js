// CHPMS housing resource directory: one module for office staff (/staff/resources/), field staff (same page) and
// Housing Navigators (Resources tab of /navigator/). The database decides what each person may do (chpms_* functions);
// this file only shows it. New file on purpose (11/12/2026): shared portal scripts that change keep their old address cached.
//
//   mountChpms(root, { prefix, say })   prefix = hash prefix ("" on the staff page, "resources" in the Navigator portal)
//   returns { route(path) }             call route() with the part of location.hash after the prefix
import { client, esc, fmtDate, money, errorText } from "/assets/portal/portal.js";

// Every call gets a time limit: a stalled request (for example the browser's saved sign-in waiting on another tab) must
// never leave the page sitting on "Loading" with no word (Stephen, 11/12/2026: the page "got hung up").
const LIMIT_MS = 20000;
const rpc = async (fn, args) => {
  let timer;
  const late = new Promise((_, no) => { timer = setTimeout(() => no(new Error("The directory did not answer within 20 seconds. Reload the page (close other 2nd Chance tabs first). If it happens again, tell the office.")), LIMIT_MS); });
  try { const { data, error } = await Promise.race([client.rpc(fn, args), late]); if (error) throw new Error(await errorText(error)); return data; }
  finally { clearTimeout(timer); }
};
const flush = () => client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});

export const POPS = ["Veterans", "Seniors", "Fixed income (SS/SSI/SSDI/VA)", "Families with children", "Experiencing homelessness",
  "At risk of eviction", "Disabilities", "Returning citizens", "Low-income working", "No current income"];
export const HELP = ["Emergency rental assistance", "Monthly rental assistance", "Security deposit assistance", "First month's rent",
  "Last month's rent", "Eviction prevention", "Utility assistance", "Moving expenses", "Furniture and household items", "Transitional housing",
  "Permanent housing", "Housing vouchers", "Rapid rehousing", "Supportive housing", "Case management", "Housing navigation", "Landlord mediation",
  "Financial counseling", "Benefits enrollment", "Other housing support"];
const VERS = ["Verified – Current", "Verified – Limited", "Verified – Limited (imported)", "Needs Confirmation", "Unverified Lead", "Inactive/Expired"];
const VER_PILL = { "Verified – Current": "ok", "Verified – Limited": "warn", "Verified – Limited (imported)": "warn", "Needs Confirmation": "warn", "Unverified Lead": "off", "Inactive/Expired": "bad" };
const REL = { none: "No contact yet", contacted: "Contacted", talking: "In talks", partner: "Partner", do_not_refer: "Do not refer" };
const RESULT = { open: "Taking applications", limited: "Limited (some help, ask)", waitlist: "Waitlist only", paused: "Paused", closed: "Closed / ended",
  no_answer: "No answer / left a message", wrong_number: "Wrong or dead number", other: "Other (see note)" };
const RESULT_PILL = { open: "ok", limited: "warn", waitlist: "warn", paused: "bad", closed: "bad", no_answer: "off", wrong_number: "bad", other: "off" };
const FUNDS = { unknown: "Money today: unknown", available: "Money today: available", low: "Money today: running low", none: "Money today: none" };
const METHOD = { phone: "Phone call", website: "Their website", in_person: "In person", email: "Email", other: "Other" };
const RSTATUS = { new: "Recorded, not sent yet", sent: "Sent to the organization", in_process: "Organization working on it", approved: "Approved",
  denied: "Denied", closed: "Closed", withdrawn: "Withdrawn" };
const RSTATUS_PILL = { new: "warn", sent: "info", in_process: "info", approved: "ok", denied: "bad", closed: "off", withdrawn: "off" };
const SENT_HOW = { email: "Email", phone: "Phone", online: "Their online form", walk_in: "Walk-in / in person", fax: "Fax", other: "Other" };
const ROLE_TXT = { staff: "Office", field: "Field staff", navigator: "Housing Navigator", research: "Research" };

const STYLE = `
.cx-tabs{display:flex;flex-wrap:wrap;gap:4px;border-bottom:1px solid var(--line);margin:4px 0 12px}
.cx-tabs a{padding:7px 12px;text-decoration:none;color:var(--fg);font-weight:600;border-bottom:3px solid transparent;font-size:.95rem}
.cx-tabs a.on{border-color:var(--accent);color:var(--accent)}
.cx-filters{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:8px;margin-bottom:10px}
.cx-filters .q{grid-column:1/-1}
.cx-card{background:var(--panel);border:1px solid var(--line);border-radius:4px;padding:12px 14px;margin-bottom:10px;display:grid;gap:6px;min-width:0}
.cx-card h3{margin:0;font-size:1.05rem}
.cx-card h3 a{color:inherit}
.cx-meta{color:var(--muted);font-size:.9rem}
.cx-pills{display:flex;flex-wrap:wrap;gap:4px;align-items:center}
.cx-tag{display:inline-block;font-size:.78rem;padding:0 7px;border:1px solid var(--line);border-radius:999px;color:var(--muted);white-space:nowrap}
.cx-prog{border-top:1px solid var(--line);padding-top:10px;margin-top:4px;display:grid;gap:6px}
.cx-prog h4{margin:0;font-size:1rem}
.cx-dl{display:grid;grid-template-columns:minmax(120px,190px) 1fr;gap:3px 12px;margin:0;font-size:.92rem}
.cx-dl dt{color:var(--muted)} .cx-dl dd{margin:0;min-width:0;overflow-wrap:anywhere}
@media (max-width:560px){.cx-dl{grid-template-columns:1fr}.cx-dl dt{margin-top:6px}}
.cx-box{border:1px solid var(--line);border-radius:4px;padding:12px;background:var(--head);display:grid;gap:10px}
.cx-checks{display:flex;flex-wrap:wrap;gap:4px 14px}
.cx-checks label{display:flex;gap:6px;align-items:center;font-weight:400;color:var(--fg);font-size:.92rem}
.cx-small{font-size:.85rem}
.cx-stats{display:flex;flex-wrap:wrap;gap:6px 18px;color:var(--muted);font-size:.92rem;margin-bottom:8px}
.cx-stats b{color:var(--fg)}
.cx-warn{color:var(--warn)} .cx-bad{color:var(--bad)}
.cx-steps{margin:0;padding-left:1.3rem;display:grid;gap:6px}
`;

const pill = (t, c = "off") => `<span class="pill ${c}">${esc(t)}</span>`;
const tag = (t) => `<span class="cx-tag">${esc(t)}</span>`;
const href = (u) => { const s = String(u || "").trim(); return /^https?:\/\//i.test(s) ? s : /^www\./i.test(s) ? "https://" + s : ""; };
const link = (u, text) => { const h = href(u); return h ? `<a href="${esc(h)}" target="_blank" rel="noopener">${esc(text || h.replace(/^https?:\/\//, "").replace(/\/$/, ""))}</a>` : esc(u || ""); };
const firstEmail = (s) => (String(s || "").match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/) || [])[0] || "";
const phoneHtml = (s) => { const t = String(s || ""); const m = t.match(/\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}|\b211\b|\b2-1-1\b/); if (!m) return esc(t); const i = t.indexOf(m[0]);
  return esc(t.slice(0, i)) + `<a href="tel:${m[0].replace(/[^0-9]/g, "")}">${esc(m[0])}</a>` + esc(t.slice(i + m[0].length)); };
const dd = (label, v, html) => (v == null || v === "" ? "" : `<dt>${esc(label)}</dt><dd>${html ? v : esc(v)}</dd>`);
const field = (name, label, value = "", type = "text", extra = "") => `<label class="f">${esc(label)}<input class="field" name="${name}" type="${type}" value="${esc(value ?? "")}" ${extra}></label>`;
const area = (name, label, value = "", rows = 3) => `<label class="f">${esc(label)}<textarea class="field" name="${name}" rows="${rows}">${esc(value ?? "")}</textarea></label>`;
const select = (name, label, map, cur, blank) => `<label class="f">${esc(label)}<select class="field" name="${name}">${blank != null ? `<option value="">${esc(blank)}</option>` : ""}${
  (Array.isArray(map) ? map.map((v) => [v, v]) : Object.entries(map)).map(([k, v]) => `<option value="${esc(k)}" ${k === cur ? "selected" : ""}>${esc(v)}</option>`).join("")}</select></label>`;
const checks = (name, all, on = []) => `<div class="cx-checks">${all.map((v) => `<label><input type="checkbox" name="${name}" value="${esc(v)}" ${on.includes(v) ? "checked" : ""}>${esc(v)}</label>`).join("")}</div>`;
const read = (root) => {
  const o = {};
  root.querySelectorAll("input[name], select[name], textarea[name]").forEach((el) => {
    if (el.type === "checkbox") { if (el.dataset.single != null) o[el.name] = el.checked; else (o[el.name] ||= []).push(...(el.checked ? [el.value] : [])); }
    else o[el.name] = el.value;
  });
  return o;
};
const today = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
const sourceList = (ids, S) => String(ids || "").split(/[;,]\s*/).map((s) => s.trim()).filter(Boolean)
  .map((id) => (S[id] ? `${link(S[id].url, id)}` : esc(id))).join(", ");
const checkLine = (c) => c ? `${pill(c.result ? RESULT[c.result] : c.status || "Checked", c.result ? RESULT_PILL[c.result] : "info")} ${c.funds_today && c.funds_today !== "unknown" ? pill(FUNDS[c.funds_today], c.funds_today === "available" ? "ok" : c.funds_today === "none" ? "bad" : "warn") : ""}
  <span class="cx-meta">${fmtDate(c.checked_on)} · ${esc(c.by_name || ROLE_TXT[c.by_role] || "")}${c.by_role && c.by_role !== "research" ? " (" + esc(ROLE_TXT[c.by_role]) + ")" : ""}${c.method ? " · " + esc(METHOD[c.method] || c.method) : ""}</span>${c.notes ? `<div class="cx-small">${esc(c.notes)}</div>` : ""}` : "";

export function mountChpms(root, { prefix = "", say = () => {} } = {}) {
  if (!document.getElementById("cx-css")) { const st = document.createElement("style"); st.id = "cx-css"; st.textContent = STYLE; document.head.appendChild(st); }
  let D = null, X = null, REFS = null, L = null;   // L: life areas (Human Mirror TN.3, migration 20261119630000)
  const F = { q: "", pop: "", help: "", area: "", ver: "", show: "" };
  const areasOf = (pid) => (L && L.links[pid]) || [];
  const areaTitle = (k) => ((L && L.areas.find((a) => a.key === k)) || { title: k }).title;
  const go = (path) => { location.hash = prefix ? prefix + (path ? "/" + path : "") : path || "find"; };
  const h = (path) => "#" + (prefix ? prefix + (path ? "/" + path : "") : path);
  const orgById = (id) => D.orgs.find((o) => o.org_id === id);
  const progById = (id) => { for (const o of D.orgs) { const p = o.programs.find((x) => x.program_id === id); if (p) return [o, p]; } return [null, null]; };
  const canAct = () => D && D.can_act;
  const fail = (e) => say(e.message || String(e), true);

  root.innerHTML = `<nav class="cx-tabs" id="cxTabs">
      <a href="${h("find")}" data-t="find">Find help</a><a href="${h("pathways")}" data-t="pathways">Pathways</a>
      <a href="${h("landlords")}" data-t="landlords">Landlord programs</a><a href="${h("funding")}" data-t="funding">Funding &amp; gaps</a>
      <a href="${h("referrals")}" data-t="referrals">Referrals</a><a href="${h("about")}" data-t="about">About the data</a></nav>
    <div id="cxBody"><p class="sub">Loading the directory ...</p></div>`;
  const body = root.querySelector("#cxBody");
  const setTab = (t) => root.querySelectorAll("#cxTabs a").forEach((a) => a.classList.toggle("on", a.dataset.t === t));

  async function load() {
    D = await rpc("chpms_directory");
    try { L = await rpc("chpms_life_areas"); } catch (e) { L = null; }   // the directory still works without it
    D.orgs.forEach((o) => { o._hay = JSON.stringify([o.legal_name, o.dba, o.org_type, o.classifications, o.service_area, o.verification_notes, o.our_note, o.physical_address,
      o.programs.map((p) => [p.program_name, p.eligibility_summary, p.how_to_apply, p.max_assistance, p.current_status, p.notes, p.income_limits, p.assist, p.pops])]).toLowerCase(); });
  }

  async function route(path) {
    path = (path || "").replace(/^\/+/, "") || "find";
    const [t, a, b] = path.split("/");
    try {
      if (!D) await load();
      say("");
      if (t === "org" && a) { setTab("find"); return orgView(a, b); }
      if (t === "refer" && a) { setTab("referrals"); return referForm(a, b); }
      if (t === "referrals") { setTab("referrals"); return a ? refView(a) : refList(); }
      if (t === "pathways") { setTab("pathways"); return pathwaysView(); }
      if (t === "landlords") { setTab("landlords"); return landlordView(); }
      if (t === "funding") { setTab("funding"); return fundingView(); }
      if (t === "about") { setTab("about"); return aboutView(); }
      if (t === "addorg") { setTab("find"); return orgEdit(null); }
      setTab("find"); return findView();
    } catch (e) { body.innerHTML = `<div class="banner bad">${esc(e.message || String(e))} <button class="btn small" type="button" onclick="location.reload()">Reload</button></div>`; fail(e); }
  }

  // ---------------------------------------------------------------- Find help
  function progMatches(p) {
    if (F.pop && !p.pops.includes(F.pop)) return false;
    if (F.help && !p.assist.includes(F.help)) return false;
    if (F.area && !areasOf(p.program_id).includes(F.area)) return false;
    if (F.show === "money" && !p.is_direct_financial) return false;
    return true;
  }
  function orgMatches(o) {
    if ((F.pop || F.help || F.area || F.show === "money") && !o.programs.some(progMatches)) return false;
    if (F.ver && o.verification_status !== F.ver) return false;
    if (F.show === "referrals" && !/^yes/i.test(o.accepts_outside_referrals || "")) return false;
    if (F.show === "landlord" && !o.landlord) return false;
    if (F.show === "partner" && !["partner", "talking", "contacted"].includes(o.our_relationship)) return false;
    if (F.show === "checked" && !(o.last_check && (Date.now() - new Date(o.last_check.checked_on + "T12:00:00")) < 30 * 864e5) && !o.programs.some((p) => p.last_check && (Date.now() - new Date(p.last_check.checked_on + "T12:00:00")) < 30 * 864e5)) return false;
    if (F.show === "copied" && !(o.import_version === "aid-11/11" || o.programs.some((p) => p.import_version === "aid-11/11"))) return false;
    if (F.show === "tn3" && !(o.import_version === "tn3-11/13" || o.programs.some((p) => p.import_version === "tn3-11/13"))) return false;
    if (F.show === "unchecked" && (o.last_check || o.programs.some((p) => p.last_check))) return false;
    if (F.show === "inactive" ? o.verification_status !== "Inactive/Expired" : (F.show !== "all" && !F.ver && o.verification_status === "Inactive/Expired")) return false;
    if (F.q) { const words = F.q.toLowerCase().split(/\s+/).filter(Boolean); if (!words.every((w) => o._hay.includes(w))) return false; }
    return true;
  }
  function findView() {
    const progs = D.orgs.flatMap((o) => o.programs);
    body.innerHTML = `
      ${D.role === "navigator_preview" ? '<div class="banner warn"><b>Preview:</b> you can search everything. Logging checks and referring people opens once your partner and confidentiality agreements are signed.</div>' : ""}
      ${D.view_as ? '<div class="banner warn">Viewing as someone else: you can look, not act.</div>' : ""}
      <div class="banner"><b>Call before you refer.</b> Programs open and close with their funding. Confirm by phone the same day, then tap <b>Log a check</b> so everyone sees what you found. Amounts show only where the organization published one; nothing here is estimated.</div>
      <div class="cx-stats"><span><b>${D.orgs.length}</b> organizations</span><span><b>${progs.length}</b> programs</span><span><b>${progs.filter((p) => p.is_direct_financial).length}</b> pay money</span>
        <span><b>${D.orgs.filter((o) => o.landlord).length}</b> landlord programs</span><span>Research ${esc(D.version || "")}, checked by us: <b>${D.orgs.filter((o) => o.last_check || o.programs.some((p) => p.last_check)).length}</b> organizations</span></div>
      <div class="cx-filters">
        <input class="field q" id="cxQ" type="search" placeholder="Search: name, program, ZIP, service, eligibility ..." value="${esc(F.q)}">
        ${select("pop", "Who", POPS, F.pop, "Anyone")}${select("help", "Kind of help", HELP, F.help, "Any help")}
        ${L ? select("area", "Life area", Object.fromEntries(L.areas.map((a) => [a.key, a.title])), F.area, "Any area of life") : ""}
        ${select("ver", "Organization verification", VERS, F.ver, "Any status")}
        ${select("show", "Show", { "": "Active organizations", money: "Pays money (direct financial help)", referrals: "Takes outside referrals", landlord: "Has a landlord program",
          partner: "We have a relationship", checked: "Checked by us in the last 30 days", unchecked: "Never checked by us", copied: "Copied from the 11/11 directory (to audit)", tn3: "Added 11/13 beyond housing (ID, health, food, phone, work, education)", inactive: "Inactive / expired only", all: "Everything, inactive too" }, F.show)}
      </div>
      <div class="row" style="margin-bottom:8px"><span class="cx-meta" id="cxCount"></span><button class="linkbtn" id="cxClear" type="button">Clear filters</button>
        ${D.can_edit ? `<a class="btn small" href="${h("addorg")}">Add an organization</a>` : ""}</div>
      <div id="cxList"></div>`;
    const draw = () => {
      const shown = D.orgs.filter(orgMatches);
      body.querySelector("#cxCount").textContent = `Showing ${shown.length} of ${D.orgs.length}`;
      body.querySelector("#cxList").innerHTML = shown.slice(0, 200).map((o) => {
        const ps = (F.pop || F.help || F.area || F.show === "money") ? o.programs.filter(progMatches) : o.programs;
        const lc = o.last_check || o.programs.map((p) => p.last_check).filter(Boolean).sort((a, b) => (b.checked_on > a.checked_on ? 1 : -1))[0];
        return `<div class="cx-card"><div class="row" style="justify-content:space-between;align-items:flex-start">
            <h3><a href="${h("org/" + o.org_id)}">${esc(o.legal_name)}</a></h3>
            <span class="cx-pills">${pill(o.verification_status, VER_PILL[o.verification_status])}${o.our_relationship !== "none" ? pill(REL[o.our_relationship], o.our_relationship === "do_not_refer" ? "bad" : "info") : ""}</span></div>
          <div class="cx-meta">${esc([o.org_type, o.service_area].filter(Boolean).join(" · "))}</div>
          ${o.main_phone ? `<div class="cx-small">${phoneHtml(o.main_phone)}</div>` : ""}
          ${ps.length ? `<div class="cx-small">${ps.slice(0, 6).map((p) => `<div>• <a href="${h("org/" + o.org_id + "/" + p.program_id)}">${esc(p.program_name)}</a>${p.is_direct_financial ? " " + tag("pays money") : ""}${p.max_assistance && !/not (publicly )?disclosed|not stated/i.test(p.max_assistance) ? ` <span class="cx-meta">· ${esc(p.max_assistance.slice(0, 90))}</span>` : ""}</div>`).join("")}${ps.length > 6 ? `<div class="cx-meta">and ${ps.length - 6} more</div>` : ""}</div>` : '<div class="cx-meta cx-small">No programs listed (services, access point or funder).</div>'}
          ${lc ? `<div class="cx-small">Last checked: ${checkLine(lc)}</div>` : ""}</div>`;
      }).join("") || '<p class="sub">Nothing matches. Clear a filter or search fewer words.</p>';
    };
    let t;
    body.querySelector("#cxQ").addEventListener("input", (e) => { clearTimeout(t); t = setTimeout(() => { F.q = e.target.value; draw(); }, 150); });
    body.querySelectorAll(".cx-filters select").forEach((s) => s.addEventListener("change", () => { F[s.name] = s.value; draw(); }));
    body.querySelector("#cxClear").onclick = () => { Object.keys(F).forEach((k) => (F[k] = "")); findView(); };
    draw();
  }

  // ---------------------------------------------------------------- One organization
  function programHtml(o, p) {
    const S = D.sources;
    return `<div class="cx-prog" id="p-${esc(p.program_id)}">
      <div class="row" style="justify-content:space-between;align-items:flex-start"><h4>${esc(p.program_name)}</h4>
        <span class="cx-pills">${pill(p.verification_status, VER_PILL[p.verification_status])}${p.is_direct_financial ? pill("Pays money", "info") : ""}${p.import_version === "aid-11/11" ? tag("from the 11/11 directory") : p.is_local ? tag("added by the office") : ""}</span></div>
      ${p.last_check ? `<div>Last checked: ${checkLine(p.last_check)}</div>` : ""}
      ${p.assist.length ? `<div class="cx-pills">${p.assist.map(tag).join("")}</div>` : ""}
      ${p.pops.length ? `<div class="cx-small"><span class="cx-meta">Serves:</span> ${esc(p.pops.join(", "))}</div>` : ""}
      ${L ? `<div class="cx-small"><span class="cx-meta">Life areas:</span> ${areasOf(p.program_id).length ? esc(areasOf(p.program_id).map(areaTitle).join("; ")) : "none yet"}
        ${L.can_tag ? ` <button class="linkbtn" data-areas="${esc(p.program_id)}">Change life areas</button>` : ""}</div>` : ""}
      <dl class="cx-dl">
        ${dd("Status (research)", p.current_status)}${dd("Most it pays", p.max_assistance)}${dd("Form of help", p.assistance_form)}${dd("Paid to", p.payment_goes_to)}
        ${dd("Months covered", p.months_covered)}${dd("How often", p.frequency)}${dd("Pays security deposit", p.pays_security_deposit)}${dd("Pays back rent", p.pays_arrears)}
        ${dd("Pays application fees", p.pays_application_fees)}${dd("Moving help", p.moving_assistance)}${dd("Waiting list", p.waiting_list)}${dd("Application window", p.application_window)}
        ${dd("Income limits", p.income_limits)}${dd("Landlord must agree", p.landlord_agreement_required)}${dd("Who qualifies", p.eligibility_summary)}
        ${p.eligibility.length ? dd("Requirements", `<ul style="margin:0;padding-left:1.1rem">${p.eligibility.map((e) => `<li><b>${esc(e.type || "")}</b>${e.type ? ": " : ""}${esc(e.requirement)}</li>`).join("")}</ul>`, true) : ""}
        ${dd("How to apply", p.how_to_apply)}${dd("Application method", p.application_method && p.application_method !== p.how_to_apply ? p.application_method : "")}
        ${dd("Self-referral", p.self_referral)}${dd("Agency referral needed", p.agency_referral_required)}${dd("Landlord can start it", p.landlord_can_initiate)}
        ${dd("Referral rule", p.referral_requirement)}${dd("Intake phone", p.intake_phone ? phoneHtml(p.intake_phone) : "", true)}
        ${dd("Apply online", p.application_url ? link(p.application_url) : "", true)}${dd("Funding", p.funding_dependency)}${dd("Amount published", p.amount_publicly_disclosed)}
        ${dd("Notes", p.notes)}${dd("Office note", p.our_note)}${dd("Sources", sourceList(p.source_ids, S), true)}
        ${dd("Researched", p.date_accessed ? fmtDate(p.date_accessed) + (p.provenance ? " · " + esc(p.provenance) : "") : "", true)}
      </dl>
      <div class="row">
        ${canAct() ? `<a class="btn small primary" href="${h("refer/" + o.org_id + "/" + p.program_id)}">Refer someone</a><button class="btn small" data-check="program:${esc(p.program_id)}">Log a check</button>` : ""}
        <button class="linkbtn" data-hist="program:${esc(p.program_id)}">History</button>
        ${D.can_edit ? `<button class="linkbtn" data-editprog="${esc(p.program_id)}">Edit program</button>` : ""}
      </div><div data-slot="program:${esc(p.program_id)}"></div></div>`;
  }

  function orgView(id, focusProg) {
    const o = orgById(id);
    if (!o) { body.innerHTML = `<p><a href="${h("find")}">← Back</a></p><p class="sub">That organization is not in the directory.</p>`; return; }
    const S = D.sources, L = o.landlord;
    const linkOrg = (r) => { const x = orgById(r.org_id); return `<li>${x ? `<a href="${h("org/" + x.org_id)}">${esc(x.legal_name)}</a>` : esc(r.org_id)}: ${esc(r.relationship || "")}</li>`; };
    const email = firstEmail(o.general_email);
    body.innerHTML = `<p><a href="${h("find")}">← All organizations</a></p>
      <div class="panel">
        <div class="row" style="justify-content:space-between;align-items:flex-start"><div><h2 style="margin:0">${esc(o.legal_name)}</h2>${o.dba ? `<div class="cx-meta">${esc(o.dba)}</div>` : ""}</div>
          <span class="cx-pills">${pill(o.verification_status, VER_PILL[o.verification_status])}${pill(REL[o.our_relationship], o.our_relationship === "do_not_refer" ? "bad" : o.our_relationship === "none" ? "off" : "info")}${o.import_version === "aid-11/11" ? tag("from the 11/11 directory") : o.is_local ? tag("added by the office") : ""}</span></div>
        ${o.our_relationship === "do_not_refer" ? '<div class="banner bad">The office marked this organization <b>Do not refer</b>. Ask the office first.</div>' : ""}
        ${o.verification_status === "Inactive/Expired" ? '<div class="banner bad">Research marked this organization <b>inactive or expired</b>. Do not refer without checking.</div>' : ""}
        ${o.last_check ? `<div>Last checked: ${checkLine(o.last_check)}</div>` : ""}
        <dl class="cx-dl">
          ${dd("Type", o.org_type)}${dd("Role", o.classifications)}${dd("Phone", o.main_phone ? phoneHtml(o.main_phone) : "", true)}
          ${dd("Email", o.general_email ? (email ? `<a href="mailto:${esc(email)}">${esc(o.general_email)}</a>` : esc(o.general_email)) : "", true)}
          ${dd("Website", o.website ? link(o.website) : "", true)}${dd("Address", o.physical_address)}${dd("Area served", o.service_area)}${dd("Languages", o.languages)}
          ${dd("Takes outside referrals", o.accepts_outside_referrals)}${dd("Research notes", o.verification_notes)}${dd("Office note", o.our_note)}
          ${dd("Sources", sourceList(o.source_ids, S), true)}${dd("Main source", o.primary_source_url ? link(o.primary_source_url) : "", true)}
          ${dd("Researched", o.date_accessed ? fmtDate(o.date_accessed) + (o.provenance ? " · " + esc(o.provenance) : "") : "", true)}
          ${dd("Checked by the office", o.our_checked_on ? fmtDate(o.our_checked_on) : "")}
        </dl>
        ${o.contacts.length ? `<div><b>Contacts</b><ul style="margin:4px 0 0;padding-left:1.1rem">${o.contacts.map((c) => { const e = firstEmail(c.email);
          return `<li>${esc(c.contact_type || "")}${c.name_if_public ? ": " + esc(c.name_if_public) : ""}${c.phone ? " · " + phoneHtml(c.phone) : ""}${c.email ? " · " + (e ? `<a href="mailto:${esc(e)}">${esc(c.email)}</a>` : esc(c.email)) : ""}</li>`; }).join("")}</ul></div>` : ""}
        <div class="row">
          ${canAct() ? `<a class="btn small primary" href="${h("refer/" + o.org_id)}">Refer someone</a><button class="btn small" data-check="org:${esc(o.org_id)}">Log a check</button>` : ""}
          <button class="linkbtn" data-hist="org:${esc(o.org_id)}">History</button>
          ${D.can_edit ? `<button class="linkbtn" data-editorg="1">Edit organization</button><button class="linkbtn" data-addprog="1">Add a program</button>` : ""}
        </div><div data-slot="org:${esc(o.org_id)}"></div>
      </div>
      <div class="panel"><h2 style="margin:0">Programs (${o.programs.length})</h2>${o.programs.map((p) => programHtml(o, p)).join("") || '<p class="sub">No programs recorded. This organization is a service, an access point or a funder.</p>'}</div>
      ${L ? `<div class="panel"><h2 style="margin:0">Landlord partnership</h2><dl class="cx-dl">
          ${dd("Works with private landlords", L.works_with_private_landlords)}${dd("Recruits landlords", L.recruits_landlords)}${dd("Landlord network", L.landlord_network)}
          ${dd("Pays landlords directly", L.pays_landlords_directly)}${dd("Incentives", L.landlord_incentives)}${dd("Places tenants", L.tenant_placement)}
          ${dd("Keeps tenants stable", L.stabilization_support)}${dd("Contact", L.partnership_contact)}${dd("How to join", L.onboarding)}${dd("Sources", sourceList(L.source_ids, S), true)}</dl></div>` : ""}
      ${o.links_out.length || o.links_in.length ? `<div class="panel"><h2 style="margin:0">Referral connections</h2>
          ${o.links_out.length ? `<div><b>Sends people to</b><ul style="margin:4px 0 0;padding-left:1.1rem">${o.links_out.map(linkOrg).join("")}</ul></div>` : ""}
          ${o.links_in.length ? `<div><b>Gets people from</b><ul style="margin:4px 0 0;padding-left:1.1rem">${o.links_in.map(linkOrg).join("")}</ul></div>` : ""}</div>` : ""}`;
    wireOrg(o);
    if (focusProg) { const el = body.querySelector("#p-" + CSS_ESC(focusProg)); if (el) el.scrollIntoView({ block: "start" }); } else window.scrollTo(0, 0);
  }
  const CSS_ESC = (s) => (window.CSS && window.CSS.escape ? window.CSS.escape(s) : String(s).replace(/[^A-Za-z0-9_-]/g, "\\$&"));

  function wireOrg(o) {
    body.querySelectorAll("[data-check]").forEach((b) => b.addEventListener("click", () => checkForm(b.dataset.check)));
    body.querySelectorAll("[data-hist]").forEach((b) => b.addEventListener("click", () => showHistory(b.dataset.hist)));
    body.querySelectorAll("[data-editprog]").forEach((b) => b.addEventListener("click", () => progEdit(o, o.programs.find((p) => p.program_id === b.dataset.editprog))));
    // TN.3: office staff tag a program with life areas; areas that come from its help types stay (they follow the help types).
    body.querySelectorAll("[data-areas]").forEach((b) => b.addEventListener("click", () => {
      const pid = b.dataset.areas, slot = body.querySelector(`[data-slot="program:${CSS.escape(pid)}"]`), fixed = (L.by_rule[pid] || []), on = areasOf(pid);
      slot.innerHTML = `<div class="panel"><b>Life areas</b><div class="cx-meta">Ticked areas show this program under Find help &gt; Life area and in the Human Mirror's "Help I could get".
          Greyed areas come from its kinds of help and change with them.</div>
        <div class="cx-checks">${L.areas.map((a) => `<label><input type="checkbox" name="area" value="${esc(a.key)}" ${on.includes(a.key) ? "checked" : ""} ${fixed.includes(a.key) ? "disabled" : ""}>${esc(a.title)}</label>`).join("")}</div>
        <div class="row"><button class="btn small primary" data-areasave>Save life areas</button><button class="linkbtn" data-areano>Cancel</button></div></div>`;
      slot.querySelector("[data-areano]").onclick = () => { slot.innerHTML = ""; };
      slot.querySelector("[data-areasave]").onclick = async () => {
        const keys = [...slot.querySelectorAll('input[name="area"]:checked:not(:disabled)')].map((x) => x.value);
        try { L = await rpc("chpms_program_areas_save", { p_program: pid, p_areas: keys }); say("Life areas saved."); orgView(o.org_id, pid); } catch (e) { fail(e); }
      };
    }));
    const eo = body.querySelector("[data-editorg]"); if (eo) eo.onclick = () => orgEdit(o);
    const ap = body.querySelector("[data-addprog]"); if (ap) ap.onclick = () => progEdit(o, null);
  }
  const slot = (key) => body.querySelector(`[data-slot="${CSS_ESC(key)}"]`);

  async function showHistory(key) {
    const [type, id] = key.split(":"); const el = slot(key);
    if (el.dataset.open === "h") { el.innerHTML = ""; el.dataset.open = ""; return; }
    try {
      const rows = await rpc("chpms_history", { p_type: type, p_id: id });
      el.dataset.open = "h";
      el.innerHTML = `<div class="cx-box"><b>Verification history</b>${rows.length ? rows.map((c) => `<div>${checkLine(c)}${c.from_import && c.method ? ` <span class="cx-meta cx-small">(${esc(c.method)})</span>` : ""}</div>`).join("") : '<p class="sub">Nothing yet.</p>'}</div>`;
    } catch (e) { fail(e); }
  }

  function checkForm(key) {
    const [type, id] = key.split(":"); const el = slot(key);
    if (el.dataset.open === "c") { el.innerHTML = ""; el.dataset.open = ""; return; }
    el.dataset.open = "c";
    el.innerHTML = `<div class="cx-box"><b>Log a check</b><p class="sub" style="margin:0">What did you find out when you called, visited or looked? Everyone using the directory sees it.</p>
      <div class="grid2">${select("result", "What you found", RESULT, "", "Choose ...")}${select("funds_today", "Money today", { unknown: "Don't know", available: "Available", low: "Running low", none: "None right now" }, "unknown")}
        ${select("method", "How", METHOD, "phone")}${field("checked_on", "Date", today(), "date", `max="${today()}"`)}</div>
      ${area("notes", "Note (who you talked to, hours, what they need, anything that changed)", "", 3)}
      <div class="row"><button class="btn primary small" data-go="1">Save the check</button><button class="linkbtn" data-x="1">Cancel</button></div></div>`;
    el.querySelector("[data-x]").onclick = () => { el.innerHTML = ""; el.dataset.open = ""; };
    el.querySelector("[data-go]").onclick = async (e) => {
      const p = read(el); e.target.disabled = true;
      try { await rpc("chpms_check_log", { p: { record_type: type, record_id: id, ...p } }); await load(); say("Check saved. Thank you."); route(currentPath()); }
      catch (err) { fail(err); e.target.disabled = false; }
    };
  }

  // ---------------------------------------------------------------- Office edits
  function orgEdit(o) {
    const isNew = !o; o = o || { verification_status: "Needs Confirmation", our_relationship: "none" };
    body.innerHTML = `<p><a href="${isNew ? h("find") : h("org/" + o.org_id)}">← Back</a></p><div class="panel" id="cxEd"><h2 style="margin:0">${isNew ? "Add an organization" : "Edit " + esc(o.legal_name)}</h2>
      ${!isNew && !o.is_local ? '<p class="sub">Changing a research field here keeps your version: a later research import will not overwrite this organization. The office fields (relationship, office note) never change on import.</p>' : ""}
      <div class="grid2">${field("legal_name", "Name", o.legal_name)}${field("dba", "Also known as", o.dba)}${field("org_type", "Type", o.org_type)}
        ${field("main_phone", "Phone", o.main_phone)}${field("general_email", "Email", o.general_email)}${field("website", "Website", o.website)}
        ${field("physical_address", "Address", o.physical_address)}${field("service_area", "Area served", o.service_area)}${field("languages", "Languages", o.languages)}
        ${field("accepts_outside_referrals", "Takes outside referrals (Yes / No / Not stated)", o.accepts_outside_referrals)}
        ${select("verification_status", "Verification", VERS, o.verification_status)}${select("our_relationship", "Our relationship", REL, o.our_relationship)}</div>
      ${area("verification_notes", "Research notes", o.verification_notes, 3)}${area("our_note", "Office note (shown to staff, field staff and Navigators)", o.our_note, 2)}
      <div class="row"><button class="btn primary" id="cxSave">Save</button>${o.is_local ? '<button class="linkbtn cx-bad" id="cxDel">Delete (office-added only)</button>' : ""}</div></div>`;
    body.querySelector("#cxSave").onclick = async (e) => {
      e.target.disabled = true;
      try { const id = await rpc("chpms_org_save", { p: { org_id: o.org_id || "", ...read(body.querySelector("#cxEd")) } }); await load(); say("Saved."); go("org/" + id); }
      catch (err) { fail(err); e.target.disabled = false; }
    };
    const del = body.querySelector("#cxDel");
    if (del) del.onclick = async () => { if (!confirm("Delete " + o.legal_name + " and its programs?")) return; try { await rpc("chpms_delete_local", { p_kind: "org", p_id: o.org_id }); await load(); go("find"); } catch (err) { fail(err); } };
  }

  function progEdit(o, p) {
    const isNew = !p; p = p || { verification_status: "Needs Confirmation", assist: [], pops: [], is_direct_financial: false };
    body.innerHTML = `<p><a href="${h("org/" + o.org_id)}">← ${esc(o.legal_name)}</a></p><div class="panel" id="cxEd"><h2 style="margin:0">${isNew ? "Add a program" : "Edit " + esc(p.program_name)}</h2>
      <p class="sub">Write amounts only as the organization published them. If it is not published, say so; never estimate.</p>
      <div class="grid2">${field("program_name", "Program name", p.program_name)}${field("assistance_form", "Form of help", p.assistance_form)}${field("payment_goes_to", "Paid to", p.payment_goes_to)}
        ${field("max_assistance", "Most it pays (as published)", p.max_assistance)}${field("months_covered", "Months covered", p.months_covered)}${field("frequency", "How often", p.frequency)}
        ${field("current_status", "Status", p.current_status)}${field("waiting_list", "Waiting list", p.waiting_list)}${field("application_window", "Application window", p.application_window)}
        ${field("income_limits", "Income limits", p.income_limits)}${field("intake_phone", "Intake phone", p.intake_phone)}${field("application_url", "Apply online (link)", p.application_url)}
        ${field("referral_requirement", "Referral rule", p.referral_requirement)}${select("verification_status", "Verification", VERS, p.verification_status)}
        <label class="f">Pays money directly<span class="cx-checks"><label><input type="checkbox" name="is_direct_financial" data-single ${p.is_direct_financial ? "checked" : ""}>Yes, direct financial help</label></span></label></div>
      ${area("eligibility_summary", "Who qualifies", p.eligibility_summary, 3)}${area("how_to_apply", "How to apply", p.how_to_apply, 2)}${area("notes", "Notes", p.notes, 2)}
      ${area("our_note", "Office note", p.our_note, 2)}
      <label class="f">Kinds of help${checks("assist", HELP, p.assist)}</label><label class="f">Who it serves${checks("pops", POPS, p.pops)}</label>
      <div class="row"><button class="btn primary" id="cxSave">Save</button>${p.is_local ? '<button class="linkbtn cx-bad" id="cxDel">Delete (office-added only)</button>' : ""}</div></div>`;
    window.scrollTo(0, 0);
    body.querySelector("#cxSave").onclick = async (e) => {
      const v = read(body.querySelector("#cxEd")); v.assist = v.assist || []; v.pops = v.pops || [];
      e.target.disabled = true;
      try { const id = await rpc("chpms_program_save", { p: { program_id: p.program_id || "", org_id: o.org_id, ...v } }); await load(); say("Saved."); go("org/" + o.org_id + "/" + id); }
      catch (err) { fail(err); e.target.disabled = false; }
    };
    const del = body.querySelector("#cxDel");
    if (del) del.onclick = async () => { if (!confirm("Delete the program " + p.program_name + "?")) return; try { await rpc("chpms_delete_local", { p_kind: "program", p_id: p.program_id }); await load(); go("org/" + o.org_id); } catch (err) { fail(err); } };
  }

  // ---------------------------------------------------------------- Referrals
  function referForm(orgId, progId) {
    const o = orgById(orgId); if (!o) return go("find");
    const p = progId ? o.programs.find((x) => x.program_id === progId) : null;
    if (!canAct()) { body.innerHTML = `<p><a href="${h("org/" + o.org_id)}">← Back</a></p><div class="banner warn">${D.view_as ? "Not while viewing as someone else." : "Referring people opens once your partner and confidentiality agreements are signed."}</div>`; return; }
    const people = D.my_people || [];
    body.innerHTML = `<p><a href="${h("org/" + o.org_id + (p ? "/" + p.program_id : ""))}">← ${esc(o.legal_name)}</a></p>
      <div class="panel" id="cxRef"><h2 style="margin:0">Refer someone to ${esc(o.legal_name)}</h2>
      ${o.our_relationship === "do_not_refer" ? '<div class="banner bad">The office marked this organization <b>Do not refer</b>.</div>' : ""}
      <div class="grid2">${select("program_id", "Program", Object.fromEntries(o.programs.map((x) => [x.program_id, x.program_name])), p ? p.program_id : "", "The organization in general")}
        ${people.length ? select("nav_referral_id", "One of the people you are helping (fills in their details)", Object.fromEntries(people.map((x) => [x.id, x.name])), "", "Someone else") : ""}</div>
      <p class="sub" style="margin:0">Collect only what the program needs to reach the person. The site does not send this to the organization: after you save, it gets the text ready for your own email or phone call.</p>
      <div class="grid2">${field("first_name", "First name")}${field("last_name", "Last name")}${field("phone", "Phone", "", "tel")}${field("email", "Email (optional)", "", "email")}
        ${field("household_size", "People in the household", "", "number", 'min="1" max="20"')}${select("population", "Best describes them", POPS, "", "Choose (optional)")}</div>
      <label class="f">Help they need${checks("help_needed", HELP, p ? p.assist : [])}</label>
      ${area("notes", "Notes for the program (keep it short; nothing medical unless they asked you to share it)", "", 3)}
      <div class="cx-checks"><label><input type="checkbox" name="confirmed_open" data-single> I called or checked today: the program is taking applications</label></div>
      <div class="cx-box" id="cxConsent"></div>
      <div class="row"><button class="btn primary" id="cxSave">Save the referral</button><a class="linkbtn" href="${h("org/" + o.org_id)}">Cancel</a></div></div>`;
    const f = body.querySelector("#cxRef");
    const consent = () => {
      const v = read(f), name = [v.first_name, v.last_name].filter(Boolean).join(" ") || "The person";
      const prog = f.querySelector('[name="program_id"]').selectedOptions[0];
      f.querySelector("#cxConsent").innerHTML = `<b>Their permission</b><p style="margin:0">${esc(name)} agrees that 2nd Chance Housing may share the information above with
        <b>${esc(o.legal_name)}</b>${prog && prog.value ? ` (${esc(prog.textContent)})` : ""} so they can be considered for help, and that the organization may contact them. They can take this back at any time by telling us.</p>
        <div class="cx-checks"><label><input type="checkbox" name="consent" data-single> They read this (or I read it to them) and they agree</label></div>
        ${field("consent_name", "They type their own full name")}`;
    };
    consent();
    ["first_name", "last_name"].forEach((n) => f.querySelector(`[name="${n}"]`).addEventListener("change", () => { const keep = read(f); consent(); f.querySelector('[name="consent_name"]').value = keep.consent_name || ""; f.querySelector('[name="consent"]').checked = !!keep.consent; }));
    f.querySelector('[name="program_id"]').addEventListener("change", (e) => {
      const x = o.programs.find((y) => y.program_id === e.target.value);
      f.querySelectorAll('[name="help_needed"]').forEach((c) => { c.checked = x ? x.assist.includes(c.value) : false; });
      const keep = read(f); consent(); f.querySelector('[name="consent_name"]').value = keep.consent_name || ""; f.querySelector('[name="consent"]').checked = !!keep.consent;
    });
    const pick = f.querySelector('[name="nav_referral_id"]');
    if (pick) pick.addEventListener("change", () => {
      const x = people.find((y) => y.id === pick.value); if (!x) return;
      const [first, ...rest] = String(x.name || "").split(" ");
      const set = (n, v) => { const el = f.querySelector(`[name="${n}"]`); if (el && v != null) el.value = v; };
      set("first_name", first); set("last_name", rest.join(" ")); set("phone", x.phone || ""); set("email", x.email || ""); set("household_size", x.household_size || "");
      if (x.veteran) set("population", "Veterans");
      consent();
    });
    f.querySelector("#cxSave").onclick = async (e) => {
      const v = read(f);
      const payload = { org_id: o.org_id, program_id: v.program_id, nav_referral_id: v.nav_referral_id || "", first_name: v.first_name, last_name: v.last_name,
        phone: v.phone, email: v.email, household_size: v.household_size, population: v.population, help_needed: v.help_needed || [], notes: v.notes,
        consent: !!v.consent, consent_name: v.consent_name, status_checked_on: v.confirmed_open ? today() : "" };
      e.target.disabled = true; say("Saving ...");
      try { const id = await rpc("chpms_referral_save", { p: payload }); flush(); REFS = null; say("Saved. Now send it to the organization (below)."); go("referrals/" + id); }
      catch (err) { fail(err); e.target.disabled = false; }
    };
  }

  async function refList() {
    REFS = await rpc("chpms_referrals_list");
    const open = REFS.filter((r) => !["closed", "withdrawn", "denied"].includes(r.status));
    const approved = REFS.filter((r) => r.status === "approved");
    const sum = approved.reduce((s, r) => s + (Number(r.approved_amount_cents) || 0), 0) / 100;
    body.innerHTML = `<div class="cx-stats"><span><b>${REFS.length}</b> referrals ${D.role === "staff" ? "(everyone's)" : "(yours)"}</span><span><b>${open.length}</b> open</span>
        <span><b>${REFS.filter((r) => r.status === "new").length}</b> not sent yet</span><span><b>${approved.length}</b> approved${sum ? " · " + money(sum) + " recorded" : ""}</span></div>
      <p class="sub">To refer someone, open an organization on <a href="${h("find")}">Find help</a> and tap <b>Refer someone</b>.</p>
      ${REFS.length ? `<div class="table-wrap"><table><thead><tr><th>#</th><th>Person</th><th>To</th><th>Status</th><th>Made</th>${D.role === "staff" ? "<th>By</th>" : ""}</tr></thead><tbody>${REFS.map((r) =>
        `<tr class="clickable" data-open="${esc(r.id)}"><td>${esc(r.ref_no)}</td><td><a href="${h("referrals/" + r.id)}">${esc(r.first_name + " " + r.last_name)}</a></td>
          <td>${esc(r.org_name)}${r.program_name ? `<div class="cx-meta cx-small">${esc(r.program_name)}</div>` : ""}</td><td>${pill(RSTATUS[r.status], RSTATUS_PILL[r.status])}</td>
          <td>${fmtDate(r.created_at)}</td>${D.role === "staff" ? `<td>${esc(r.made_by_name || "")}<div class="cx-meta cx-small">${esc(ROLE_TXT[r.made_by_role] || "")}</div></td>` : ""}</tr>`).join("")}</tbody></table></div>` : '<p class="sub">No referrals yet.</p>'}`;
    body.querySelectorAll("tr[data-open]").forEach((tr) => tr.addEventListener("click", (e) => { if (e.target.tagName !== "A") go("referrals/" + tr.dataset.open); }));
  }

  function referralText(r) {
    const lines = [`Referral from 2nd Chance Housing Inc (Milwaukee)`, ``,
      `Program: ${r.org_name}${r.program_name ? " / " + r.program_name : ""}`, ``,
      `Name: ${r.first_name} ${r.last_name}`, r.phone ? `Phone: ${r.phone}` : null, r.email ? `Email: ${r.email}` : null,
      r.household_size ? `People in the household: ${r.household_size}` : null, r.population ? `Situation: ${r.population}` : null,
      r.help_needed && r.help_needed.length ? `Help needed: ${r.help_needed.join(", ")}` : null, r.notes ? `Notes: ${r.notes}` : null, ``,
      `${r.first_name} ${r.last_name} agreed on ${fmtDate(r.consent_on)} that we share this with you so they can be considered for help.`, ``,
      `Referred by: ${r.made_by_name || ""}${r.made_by_role === "navigator" ? " (Housing Navigator)" : ""}, 2nd Chance Housing Inc, info@2ndchinc.org, (262) 236-5443`];
    return lines.filter((l) => l !== null).join("\n");
  }

  async function refView(id) {
    let r;
    try { r = await rpc("chpms_referral_get", { p_id: id }); } catch (e) { body.innerHTML = `<p><a href="${h("referrals")}">← All referrals</a></p>`; return fail(e); }
    const orgEmail = firstEmail(r.org && r.org.general_email) || (() => { const o = orgById(r.org_id); return o ? o.contacts.map((c) => firstEmail(c.email)).find(Boolean) || "" : ""; })();
    const text = referralText(r);
    const subject = `Referral: ${r.first_name} ${r.last_name.slice(0, 1)}. for ${r.program_name || r.org_name}`;
    const closed = ["closed", "withdrawn"].includes(r.status);
    const can = canAct() && (r.mine || D.role === "staff");
    body.innerHTML = `<p><a href="${h("referrals")}">← All referrals</a></p>
      <div class="panel"><div class="row" style="justify-content:space-between"><h2 style="margin:0">#${esc(r.ref_no)} · ${esc(r.first_name + " " + r.last_name)}</h2>${pill(RSTATUS[r.status], RSTATUS_PILL[r.status])}</div>
        <dl class="cx-dl">
          ${dd("To", `${r.org_id ? `<a href="${h("org/" + r.org_id + (r.program_id ? "/" + r.program_id : ""))}">${esc(r.org_name)}</a>` : esc(r.org_name)}${r.program_name ? " / " + esc(r.program_name) : ""}`, true)}
          ${dd("Phone", r.phone ? phoneHtml(r.phone) : "", true)}${dd("Email", r.email)}${dd("Household", r.household_size)}${dd("Situation", r.population)}
          ${dd("Help needed", (r.help_needed || []).join(", "))}${dd("Notes", r.notes)}
          ${dd("Permission", `${esc(r.consent_name)} agreed on ${fmtDate(r.consent_on)}`, true)}
          ${dd("Program confirmed open", r.status_checked_on ? fmtDate(r.status_checked_on) : "Not recorded")}
          ${dd("Sent", r.sent_on ? `${fmtDate(r.sent_on)} by ${esc(SENT_HOW[r.sent_how] || r.sent_how || "")}` : "", true)}
          ${dd("Approved amount", r.approved_amount_cents != null ? money(r.approved_amount_cents / 100) : "")}${dd("Outcome", r.outcome_note)}${dd("Closed because", r.closed_reason)}
          ${dd("Made by", `${esc(r.made_by_name || "")} (${esc(ROLE_TXT[r.made_by_role] || "")}), ${fmtDate(r.created_at)}`, true)}
        </dl></div>
      ${can && r.status === "new" ? `<div class="panel"><h2 style="margin:0">Send it to the organization</h2>
          <p class="sub" style="margin:0">Use your own email or phone; the site does not send it for you. Then tap <b>Mark as sent</b>.</p>
          ${r.program && r.program.intake_phone ? `<div>Intake phone: ${phoneHtml(r.program.intake_phone)}</div>` : r.org && r.org.main_phone ? `<div>Phone: ${phoneHtml(r.org.main_phone)}</div>` : ""}
          ${r.program && r.program.application_url ? `<div>Apply online: ${link(r.program.application_url)}</div>` : ""}
          ${r.program && r.program.how_to_apply ? `<div class="cx-small">How to apply: ${esc(r.program.how_to_apply)}</div>` : ""}
          <textarea class="field" rows="10" readonly id="cxText">${esc(text)}</textarea>
          <div class="row">${orgEmail ? `<a class="btn small" href="mailto:${esc(orgEmail)}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(text)}">Open in my email to ${esc(orgEmail)}</a>` : '<span class="cx-meta">No email on file for this organization: call, use their form or walk in.</span>'}
            <button class="btn small" id="cxCopy">Copy the text</button></div></div>` : ""}
      ${can ? `<div class="panel" id="cxStep"><h2 style="margin:0">Update</h2>
          ${closed ? (D.role === "staff" || r.mine ? '<div class="row"><button class="btn small" data-step="reopen">Reopen</button></div>' : "") : `
          <div class="grid2">${r.status === "new" ? `${select("sent_how", "Sent how", SENT_HOW, "email")}${field("sent_on", "Sent on", today(), "date", `max="${today()}"`)}` : ""}
            ${field("amount", "Amount approved, if they approved money ($)", "", "text", 'inputmode="decimal"')}</div>
          ${area("note", "Note (what they said, next step, reason)", "", 2)}
          <div class="row">${r.status === "new" ? '<button class="btn small primary" data-step="sent">Mark as sent</button>' : ""}
            ${["sent"].includes(r.status) ? '<button class="btn small" data-step="in_process">They are working on it</button>' : ""}
            ${["sent", "in_process"].includes(r.status) ? '<button class="btn small" data-step="approved">Approved</button><button class="btn small" data-step="denied">Denied</button>' : ""}
            <button class="btn small" data-step="note">Add note</button>
            ${r.status === "new" ? '<button class="linkbtn" data-step="withdrawn">Withdraw (not sending it)</button>' : '<button class="linkbtn" data-step="closed">Close</button>'}</div>`}</div>` : ""}
      <div class="panel"><h2 style="margin:0">History</h2><ul style="margin:0;padding-left:1.1rem">${(r.events || []).map((e) => `<li>${new Date(e.at).toLocaleString("en-US", { dateStyle: "short", timeStyle: "short" })} · <b>${esc(e.action.replaceAll("_", " "))}</b> · ${esc(e.by || "")}${e.detail ? ": " + esc(e.detail) : ""}</li>`).join("")}</ul></div>`;
    const copy = body.querySelector("#cxCopy");
    if (copy) copy.onclick = async () => { try { await navigator.clipboard.writeText(text); say("Copied."); } catch { body.querySelector("#cxText").select(); say("Select-all done: press Ctrl+C (or long-press, Copy)."); } };
    body.querySelectorAll("[data-step]").forEach((b) => b.addEventListener("click", async () => {
      const box = body.querySelector("#cxStep"); const v = read(box);
      if (b.dataset.step === "withdrawn" && !confirm("Withdraw this referral? It will not be sent.")) return;
      b.disabled = true;
      try { await rpc("chpms_referral_step", { p_id: r.id, p_action: b.dataset.step, p: v }); REFS = null; say("Updated."); refView(r.id); }
      catch (err) { fail(err); b.disabled = false; }
    }));
  }

  // ---------------------------------------------------------------- Pathways, landlords, funding, about
  async function extras() { if (!X) X = await rpc("chpms_extras"); return X; }
  const orgByName = (name) => D.orgs.find((o) => o.legal_name === name.trim());
  const namesHtml = (s) => String(s || "").split(/;\s*/).filter(Boolean).map((n) => { const o = orgByName(n); return o ? `<a href="${h("org/" + o.org_id)}">${esc(n)}</a>` : esc(n); }).join("; ");

  async function pathwaysView() {
    const x = await extras();
    const pops = [...new Set(x.pathways.map((p) => p.population))];
    body.innerHTML = `<p class="sub">The usual route for each situation, step by step, with who does each step. Use it to explain the process and to pick the right door first.</p>
      ${pops.map((pop) => `<div class="panel"><h2 style="margin:0">${esc(pop)}</h2><ol class="cx-steps">${x.pathways.filter((p) => p.population === pop).map((s) =>
        `<li><b>${esc(s.step_name || "")}</b>: ${esc(s.what_happens || "")}${s.responsible_organizations ? `<div class="cx-small cx-meta">Who: ${namesHtml(s.responsible_organizations)}</div>` : ""}</li>`).join("")}</ol></div>`).join("")}`;
  }

  function landlordView() {
    const list = D.orgs.filter((o) => o.landlord);
    body.innerHTML = `<p class="sub">Organizations that work with private landlords: incentives, guarantees, direct rent payments, tenant placement and support after move-in. Use these when you recruit a landlord or ask one to take a chance on someone.</p>
      ${list.map((o) => { const L = o.landlord; return `<div class="cx-card"><h3><a href="${h("org/" + o.org_id)}">${esc(o.legal_name)}</a></h3><dl class="cx-dl">
        ${dd("Works with private landlords", L.works_with_private_landlords)}${dd("Recruits landlords", L.recruits_landlords)}${dd("Network", L.landlord_network)}
        ${dd("Pays landlords directly", L.pays_landlords_directly)}${dd("Incentives", L.landlord_incentives)}${dd("Places tenants", L.tenant_placement)}
        ${dd("Keeps tenants stable", L.stabilization_support)}${dd("Contact", L.partnership_contact)}${dd("How to join", L.onboarding)}</dl></div>`; }).join("")}`;
  }

  async function fundingView() {
    const x = await extras();
    const levels = [...new Set(x.funding.map((f) => f.funding_level))];
    body.innerHTML = `<div class="panel"><h2 style="margin:0">Gaps and opportunities</h2><p class="sub" style="margin:0">What the research found missing or changing. Read before promising anyone help.</p>
        <ul style="margin:0;padding-left:1.1rem;display:grid;gap:6px">${x.gaps.map((g) => `<li><b>${esc(g.kind || "")}</b>: ${esc(g.finding || "")} <span class="cx-meta cx-small">${sourceList(g.source_ids, D.sources)}</span></li>`).join("")}</ul></div>
      <div class="panel"><h2 style="margin:0">Where the money comes from</h2><p class="sub" style="margin:0">Funders and the programs they pay for. "Organizations only" means a person cannot apply to the funder; they apply to the program that received it.</p>
        ${levels.map((lv) => `<h3 style="margin:8px 0 0">${esc(lv || "Other")}</h3><div class="table-wrap"><table><thead><tr><th>Funder</th><th>Program</th><th>Goes to</th><th>For</th><th>Period / amount</th><th>Open?</th></tr></thead><tbody>${
          x.funding.filter((f) => f.funding_level === lv).map((f) => `<tr><td>${esc(f.funding_agency || "")}</td><td>${esc(f.program || "")}</td><td>${namesHtml(f.receiving_org)}${f.service_delivery_org && f.service_delivery_org !== f.receiving_org && !/^not stated/i.test(f.service_delivery_org) ? `<div class="cx-small cx-meta">delivered by ${namesHtml(f.service_delivery_org)}</div>` : ""}</td>
            <td>${esc([f.population, f.assistance_type].filter(Boolean).join(" · "))}<div class="cx-small cx-meta">${esc(f.available_to || "")}</div></td><td>${esc(f.funding_period || "")}</td><td>${esc(f.accepting_apps_or_awarding || "")}</td></tr>`).join("")}</tbody></table></div>`).join("")}</div>`;
  }

  async function aboutView() {
    const x = await extras();
    const L = (k) => x.log.filter((l) => l.log === k);
    const conflicts = L("conflict"), openC = conflicts.filter((c) => c.entry_type === "Open");
    const questions = L("discovery").filter((l) => /unresolved|not accessed/i.test(l.entry_type || ""));
    const progs = D.orgs.flatMap((o) => o.programs);
    const vcount = (list) => VERS.map((v) => `<span>${esc(v)}: <b>${list.filter((r) => r.verification_status === v).length}</b></span>`).join("");
    const OBJ = (d) => Object.entries(d.data || {}).filter(([, v]) => v).map(([k, v]) => `<b>${esc(k)}:</b> ${esc(v)}`).join("<br>");
    body.innerHTML = `<div class="panel"><h2 style="margin:0">About this directory</h2>
        <p style="margin:0">Milwaukee housing assistance research prepared for 2nd Chance Housing Inc, version <b>${esc(D.version || "")}</b>. ${esc(D.readme.split("\n")[0] || "")}</p>
        <ul style="margin:0;padding-left:1.1rem">${D.readme.split("\n").slice(1).map((l) => `<li>${esc(l.replace(/^•\s*/, ""))}</li>`).join("")}</ul>
        <div class="cx-stats"><span>Organizations <b>${D.orgs.length}</b></span>${vcount(D.orgs)}</div>
        <div class="cx-stats"><span>Programs <b>${progs.length}</b></span>${vcount(progs)}<span>Pay money: <b>${progs.filter((p) => p.is_direct_financial).length}</b></span></div>
        <p class="sub" style="margin:0">Who can use it: office staff and field staff (this page) and Housing Navigators (Resources tab of their portal). Everyone can log a check and refer people; only the office edits entries. The office is emailed when field staff or a Navigator records a referral.</p></div>
      <div class="panel"><h2 style="margin:0">Recent checks</h2>${x.checks_recent.length ? x.checks_recent.map((c) => { const [o, p] = c.record_type === "program" ? progById(c.record_id) : [orgById(c.record_id), null];
          return `<div><a href="${h("org/" + (o ? o.org_id : c.record_id) + (p ? "/" + p.program_id : ""))}">${esc(p ? p.program_name : o ? o.legal_name : c.record_id)}</a>: ${checkLine(c)}</div>`; }).join("") : '<p class="sub">No checks logged yet. Tap Log a check on any organization or program after you call.</p>'}</div>
      <div class="panel"><h2 style="margin:0">Facts that disagree (${openC.length} open of ${conflicts.length})</h2><p class="sub" style="margin:0">Where sources disagree, both values are kept. Settle the open ones with a phone call, then log a check.</p>
        ${[...openC, ...conflicts.filter((c) => c.entry_type !== "Open")].map((c) => `<details><summary>${c.entry_type === "Open" ? pill("Open", "warn") : pill("Resolved", "ok")} ${esc(c.data.topic || "")}</summary><div class="cx-small" style="margin:6px 0 0 8px">${OBJ(c)}</div></details>`).join("")}</div>
      <div class="panel"><h2 style="margin:0">Open questions from the research (${questions.length})</h2><ul style="margin:0;padding-left:1.1rem">${questions.map((q) => `<li><span class="cx-meta">${esc(q.entry_type)}:</span> ${esc(q.data.detail || "")}</li>`).join("")}</ul></div>
      <details class="panel"><summary><b>Documents merged into this version</b></summary>${L("merge").map((m) => `<div class="cx-small">${OBJ(m)}</div>`).join("<hr>")}</details>
      <details class="panel"><summary><b>Search log (${L("discovery").length})</b></summary><ul class="cx-small" style="margin:0;padding-left:1.1rem">${L("discovery").map((d) => `<li><span class="cx-meta">${esc(d.entry_type || "")}:</span> ${esc(d.data.detail || "")}</li>`).join("")}</ul></details>
      <details class="panel"><summary><b>All ${Object.keys(D.sources).length} sources</b></summary><ul class="cx-small" style="margin:0;padding-left:1.1rem">${Object.entries(D.sources).map(([id, s]) => `<li>${esc(id)}: ${link(s.url, s.title || s.url)} <span class="cx-meta">${esc([s.publisher, s.type].filter(Boolean).join(" · "))}</span></li>`).join("")}</ul></details>`;
  }

  const currentPath = () => { const hsh = location.hash.slice(1); return prefix ? hsh.replace(new RegExp("^" + prefix + "/?"), "") : hsh; };
  return { route, reload: async () => { D = null; X = null; } };
}
