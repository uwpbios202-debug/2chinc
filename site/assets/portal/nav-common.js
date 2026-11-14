// Community Housing Partnership: the parts the Navigator portal (/navigator/) and the staff page (/staff/navigators/) share:
// the referral form and detail, check-ins, case notes, and the housing network (outside landlords and their units).
// Every call is a database function that checks who is signed in (see migration 20261118800000_housing_navigators.sql).
import { client, esc, money, fmtDate, errorText } from "/assets/portal/portal.js";

export const PATHWAYS = { veteran: "Veteran", senior: "Older adult on a fixed income", benefits: "Receives benefits (SSI, SSDI ...)", returning_citizen: "Returning citizen", family: "Family", other: "Other" };
export const SITUATIONS = { street: "Living outside / no shelter", shelter: "In a shelter", transitional: "Transitional housing", doubled_up: "Staying with others", at_risk: "Housed, at risk of losing it", seeking_independent: "Seeking independent housing", other: "Other" };
export const SOURCES = { ss: "Social Security", ssi: "SSI", ssdi: "SSDI", va: "VA benefits", pension: "Pension", employment: "Work", child_support: "Child support", other: "Other" };
export const STATUS = { draft: "Draft", submitted: "Submitted", reviewing: "Reviewing", searching: "Searching for housing", matched: "Matched, confirm the placement", approved: "Ready to move in", moved_in: "Housed", closed: "Closed" };
const STATUS_PILL = { draft: "off", submitted: "info", reviewing: "info", searching: "warn", matched: "warn", approved: "ok", moved_in: "ok", closed: "off" };
export const MARKS = { checkin: "Check-in", d30: "30-day check-in", d60: "60-day check-in", d90: "90-day stability review", m6: "6-month check-in", m12: "12-month stability review" };
export const EVERY = { daily: "Daily", every_3_days: "Every 3 days", weekly: "Weekly", every_2_weeks: "Every 2 weeks", monthly: "Monthly", every_2_months: "Every 2 months", quarterly: "Every 3 months", as_needed: "As needed (no schedule)" };
const everyOpts = (sel) => Object.entries(EVERY).map(([k, t]) => `<option value="${k}"${k === sel ? " selected" : ""}>${esc(t)}</option>`).join("");
export const OUTCOMES = { stable: "Stable, doing well", concern: "Housed, some concerns", at_risk: "At risk of losing housing", left: "Left the housing", unreachable: "Could not reach" };
export const CLOSE_REASONS = { housed_elsewhere: "Housed elsewhere", not_eligible: "Not a fit for the program", no_contact: "Lost contact", declined: "Person declined", left_housing: "Left the housing", consent_withdrawn: "Consent withdrawn", duplicate: "Duplicate", other: "Other" };
const UNIT_STATUS = { available: "Available", reserved: "Reserved", occupied: "Occupied", maintenance: "Maintenance", off_market: "Off market" };
const INSPECTION = { not_inspected: "Not inspected", scheduled: "Inspection scheduled", passed: "Inspection passed", failed: "Inspection failed" };
const AGREEMENT = { none: "No agreement yet", talking: "Talking", sent: "Agreement sent", signed: "Agreement signed" };
const LL_STATUS = { prospect: "Prospect", active: "Active", paused: "Paused", ended: "Ended" };
const YESNO = { "": "Not sure", true: "Yes", false: "No" };

export const rpc = async (fn, args) => { const { data, error } = await client.rpc(fn, args); if (error) throw new Error(await errorText(error)); return data; };
export const flush = () => client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
export const pill = (status) => `<span class="pill ${STATUS_PILL[status] || "off"}">${esc(STATUS[status] || status)}</span>`;
const nameOf = (r) => esc([r.first_name, r.last_name].filter(Boolean).join(" "));

// ---------------------------------------------------------------- tiny form builder
// [key, label, type, options]; types: text email tel num date select yesno check checks area
function fieldHtml([key, label, type, opt], v) {
  const val = v == null ? "" : v;
  const id = "nf_" + key;
  if (type === "select" || type === "yesno") {
    const o = type === "yesno" ? YESNO : opt;
    return `<label class="nf">${esc(label)}<select class="field" data-k="${key}" data-t="${type}" id="${id}">${Object.entries(o).map(([k, t]) => `<option value="${esc(k)}"${String(val) === k ? " selected" : ""}>${esc(t)}</option>`).join("")}</select></label>`;
  }
  if (type === "check") return `<label class="nf chk"><input type="checkbox" data-k="${key}" data-t="check" id="${id}"${val ? " checked" : ""}> ${esc(label)}</label>`;
  if (type === "checks") return `<fieldset class="nf checks" data-k="${key}" data-t="checks"><legend>${esc(label)}</legend>${Object.entries(opt).map(([k, t]) => `<label><input type="checkbox" value="${esc(k)}"${(val || []).includes(k) ? " checked" : ""}> ${esc(t)}</label>`).join("")}</fieldset>`;
  if (type === "area") return `<label class="nf wide">${esc(label)}<textarea class="field" rows="3" data-k="${key}" data-t="area" id="${id}">${esc(val)}</textarea></label>`;
  const it = { num: "text", tel: "tel", email: "email", date: "date" }[type] || "text";
  return `<label class="nf">${esc(label)}<input class="field" type="${it}"${type === "num" ? ' inputmode="decimal"' : ""} data-k="${key}" data-t="${type}" id="${id}" value="${esc(type === "date" && val ? String(val).slice(0, 10) : val)}"></label>`;
}
export const formHtml = (fields, values = {}) => `<div class="nform">${fields.map((f) => typeof f === "string" ? `<h3 class="nsec">${esc(f)}</h3>` : fieldHtml(f, values[f[0]])).join("")}</div>`;
export function readForm(root) {
  const o = {};
  root.querySelectorAll("[data-k]").forEach((el) => {
    const k = el.dataset.k, t = el.dataset.t;
    if (t === "check") o[k] = el.checked;
    else if (t === "checks") o[k] = [...el.querySelectorAll("input:checked")].map((i) => i.value);
    else if (t === "num") o[k] = el.value.replace(/[^0-9.]/g, "");
    else o[k] = el.value.trim();
  });
  return o;
}

// ---------------------------------------------------------------- referral form
export function refFields(role, navigators = []) {
  const f = [
    "The person",
    ["first_name", "First name", "text"], ["last_name", "Last name", "text"], ["phone", "Phone", "tel"], ["email", "Email", "email"],
    ["reach_note", "Where or how to reach them (shelter, a relative's phone ...)", "area"],
    "Situation",
    ["pathway", "Program pathway", "select", PATHWAYS], ["housing_situation", "Where they stay now", "select", { "": "Choose ...", ...SITUATIONS }],
    ["veteran", "Veteran", "yesno"], ["household_size", "People in the household", "num"], ["bedrooms_needed", "Bedrooms needed", "num"],
    ["move_in_by", "Needs to move in by", "date"], ["areas", "Areas they want or need (near family, bus line ...)", "text"],
    "Income and rent",
    ["income_monthly", "Monthly income ($)", "num"], ["income_sources", "Income from", "checks", SOURCES],
    ["contribution_monthly", "What they can pay toward rent each month ($)", "num"],
    ["assistance_monthly", "Rental assistance each month ($)", "num"], ["assistance_source", "Assistance from (VASH, county, agency ...)", "text"],
    ["assistance_confirmed", "Assistance is confirmed in writing", "check"],
    "Needs",
    ["accessibility_needs", "Accessibility needs (stairs, grab bars, wheelchair ...)", "area"], ["accommodation_request", "Reasonable accommodation request, if any", "area"],
    "Support worker or social worker (optional)",
    ["support_name", "Name", "text"], ["support_agency", "Agency", "text"], ["support_phone", "Phone", "tel"], ["support_email", "Email", "email"],
  ];
  f.splice(f.indexOf("Needs"), 0, ["income_verified_on", "Income verified on (you saw proof)", "date"]);
  if (role === "staff") f.push("Office only", ["navigator_id", "Navigator", "select", { "": "None (office referral)", ...Object.fromEntries(navigators.map((n) => [n.id, n.name])) }],
    ["staff_notes", "Office notes (the Navigator never sees these)", "area"]);
  return f;
}

export function consentHtml(text, r = {}) {
  if (r.consent_on) return `<div class="banner ok">Consent signed by <b>${esc(r.consent_name)}</b> on ${fmtDate(r.consent_on)}.${r.consent_withdrawn_on ? ` <b>Withdrawn ${fmtDate(r.consent_withdrawn_on)}.</b>` : ""}</div>`;
  return `<div class="banner warn"><b>Consent (the person reads this and types their own full name):</b><p style="margin:6px 0">${esc(text || "")}</p>
    <label class="nf">Their full name, typed by them<input class="field" data-k="consent_name" data-t="text" autocomplete="off"></label></div>`;
}

// ---------------------------------------------------------------- referral detail
export function refDetail(r, ctx) {
  const staff = ctx.role === "staff", s = r.status, u = r.unit;
  const gap = r.gap == null ? null : Number(r.gap);
  const act = [];
  const can = (cond, html) => { if (cond) act.push(html); };
  can(staff || s !== "closed", `<button class="btn small" data-act="ref-edit">Edit details</button>`);
  can(["draft", "submitted", "reviewing"].includes(s), `<button class="btn small primary" data-act="ref-step" data-to="searching">Start the housing search</button>`);
  can(s === "searching", `<button class="btn small primary" data-act="ref-match">Match a unit</button>`);
  can(["matched", "approved"].includes(s), `<button class="btn small" data-act="ref-step" data-to="searching">Release the unit</button>`);
  can(s === "matched", `<button class="btn small primary" data-act="ref-approve">Confirm the placement</button>`);
  can(s === "approved", `<button class="btn small primary" data-act="ref-movein">Record the move-in</button>`);
  can(s !== "closed", `<button class="btn small" data-act="ref-close">Close</button>`);
  can(s === "closed" && !r.moved_in_at, `<button class="btn small" data-act="ref-step" data-to="searching">Reopen</button>`);
  can(s !== "closed" && r.consent_on && !r.consent_withdrawn_on, `<button class="linkbtn" data-act="ref-withdraw">Consent withdrawn</button>`);

  const fus = (r.followups || []).slice().sort((a, b) => (a.done_on ? 1 : 0) - (b.done_on ? 1 : 0) || (a.done_on ? String(b.done_on).localeCompare(a.done_on) : String(a.due_on).localeCompare(b.due_on)));
  // TN.5 (migration 20261119650000): check-ins can start at the first meeting, once the housing consent is signed.
  const canPlan = s === "moved_in" || (s !== "closed" && r.consent_on && !r.consent_withdrawn_on);
  const plan = canPlan && s !== "moved_in" && !r.next_checkin_on ? `<div class="banner"><b>Check-ins:</b> none planned yet. You can start them now, before housing: meeting regularly from the first meeting helps the whole plan, not only the housing search.
      <div class="row" style="margin-top:6px"><button class="btn small" data-act="plan-edit">Start check-ins</button></div></div>`
    : canPlan ? `<div class="banner"><b>Check-in plan:</b> ${esc(EVERY[r.checkin_every] || r.checkin_every || "Weekly")}${r.next_checkin_on ? ` · next check-in <b>${fmtDate(r.next_checkin_on)}</b>` : ""}${r.checkin_note ? `<div class="sub">${esc(r.checkin_note)}</div>` : ""}
      <div class="row" style="margin-top:6px"><button class="btn small" data-act="plan-edit">Change the plan or next date</button></div>
      <div class="sub">Each person's plan is their own: daily at first, then weekly or every 2 weeks as they settle in, more often when things get hard. Recording a check-in puts the next one on the calendar. ${s === "moved_in" ? "The 90-day and 12-month stability reviews stay fixed." : "At move-in the plan continues and the 90-day and 12-month stability reviews are added."}</div></div>` : "";
  const fu = fus.map((f) => `<tr><td>${esc(MARKS[f.mark] || f.mark)}</td><td>${fmtDate(f.due_on)}</td><td>${f.done_on
      ? `${esc(OUTCOMES[f.outcome] || f.outcome)}${f.rent_current === false ? " · rent behind" : f.rent_current ? " · rent current" : ""}${f.note ? `<div class="sub">${esc(f.note)}</div>` : ""}<div class="sub">${fmtDate(f.done_on)}${f.mirror_need_id ? " · linked to a need in their Mirror" : ""}</div>`
      : s !== "closed" ? `<div class="furow" data-fu="${esc(f.id)}"><select class="field"><option value="">How are they doing?</option>${Object.entries(OUTCOMES).map(([k, t]) => `<option value="${k}">${esc(t)}</option>`).join("")}</select>
          ${s === "moved_in" ? '<label class="chk"><input type="checkbox" checked> Rent current</label>' : ""}<input class="field" placeholder="Short note"><button class="btn small" data-act="fu-save">Save check-in</button></div>` : '<span class="sub">Not done</span>'}</td></tr>`).join("");

  const ev = (r.events || []).map((e) => `<li><span class="sub">${new Date(e.at).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })} · ${esc(e.who || "")}${e.private ? " · office only" : ""}</span><br>${esc(e.action === "note" ? "" : e.action.replace(/_/g, " ").replace(/^status /, "→ "))}${e.detail ? (e.action === "note" ? "" : ": ") + esc(e.detail) : ""}</li>`).join("");

  const money0 = (n) => n == null || n === "" ? "—" : money(n);
  return `<div class="panel" data-ref="${esc(r.id)}">
    <div class="row" style="justify-content:space-between"><h2 style="margin:0">${esc(r.label)} · ${nameOf(r)}</h2>${pill(s)}</div>
    ${s === "closed" && r.close_reason ? `<div class="sub">Closed: ${esc(CLOSE_REASONS[r.close_reason] || r.close_reason)}</div>` : ""}
    ${staff && r.navigator ? `<div class="sub">Navigator: ${esc(r.navigator)}</div>` : ""}
    <div class="kv">
      <div><span>Pathway</span><b>${esc(PATHWAYS[r.pathway] || r.pathway)}</b></div>
      <div><span>Now staying</span><b>${esc(SITUATIONS[r.housing_situation] || "—")}</b></div>
      <div><span>Household / bedrooms</span><b>${esc(r.household_size || "—")} / ${esc(r.bedrooms_needed || "—")}</b></div>
      <div><span>Monthly income</span><b>${money0(r.income_monthly)}</b>${r.income_verified_on ? `<span>verified ${fmtDate(r.income_verified_on)}</span>` : "<span>not verified yet</span>"}</div>
      <div><span>Can pay toward rent</span><b>${money0(r.contribution_monthly)}</b></div>
      <div><span>Assistance</span><b>${money0(r.assistance_monthly)}</b><span>${esc(r.assistance_source || "")}${r.assistance_monthly ? (r.assistance_confirmed ? " · confirmed" : " · NOT confirmed (not counted)") : ""}</span></div>
    </div>
    ${u ? `<div class="banner ${gap != null && gap > 0 ? "warn" : "ok"}"><b>Unit:</b> ${esc(u.address)}${u.unit_label ? " " + esc(u.unit_label) : ""}${u.room ? " · " + esc(u.room) : ""} · ${esc(u.landlord || "")} · rent ${money0(r.unit_rent)}${u.deposit ? ` · deposit ${money(u.deposit)}` : ""}
      <br><b>Monthly gap:</b> ${gap == null ? "—" : gap > 0 ? `${money(gap)} short (rent ${money0(r.unit_rent)} − pays ${money0(r.contribution_monthly || 0)} − confirmed assistance ${money0(r.assistance_confirmed ? r.assistance_monthly || 0 : 0)})` : "none, rent is covered"}
      ${r.gap_override_note ? `<br><b>Gap covered by:</b> ${esc(r.gap_override_note)}` : ""}${r.move_in_on ? `<br><b>Moved in:</b> ${fmtDate(r.move_in_on)}` : ""}</div>` : ""}
    <div class="sub">${[r.phone, r.email].filter(Boolean).map(esc).join(" · ")}${r.reach_note ? ` · ${esc(r.reach_note)}` : ""}${r.move_in_by ? ` · needs housing by ${fmtDate(r.move_in_by)}` : ""}${r.areas ? ` · areas: ${esc(r.areas)}` : ""}</div>
    ${r.accessibility_needs || r.accommodation_request ? `<div class="sub"><b>Needs:</b> ${esc([r.accessibility_needs, r.accommodation_request].filter(Boolean).join(" · "))}</div>` : ""}
    ${r.support_name ? `<div class="sub"><b>Support worker:</b> ${esc([r.support_name, r.support_agency, r.support_phone, r.support_email].filter(Boolean).join(" · "))}</div>` : ""}
    ${r.consent_on ? consentHtml("", r) : '<div class="banner warn">No consent yet. Open <b>Edit details</b> and have the person type their name.</div>'}
    ${r.consent_on ? '<div class="nwhole"></div>' : ""}
    ${u && ["matched", "approved", "moved_in"].includes(s) ? '<div class="nown"></div>' : ""}
    ${staff && r.staff_notes ? `<div class="banner"><b>Office notes:</b> ${esc(r.staff_notes)}</div>` : ""}
    <div class="actions row">${act.join("")}</div>
    <div class="nslot"></div>
    ${plan || fu ? `<h3 class="nsec">Check-ins</h3>${plan}` : ""}${fu ? `<div class="table-wrap"><table class="t"><thead><tr><th>Check-in</th><th>Due</th><th>Result</th></tr></thead><tbody>${fu}</tbody></table></div>` : ""}
    <h3 class="nsec">Notes and history</h3>
    <div class="row"><input class="field" id="noteText" placeholder="Add a case note (${staff ? "the Navigator sees it unless marked office only" : "private to you and the 2nd Chance office"})" style="flex:1;min-width:200px">${staff ? '<label class="chk"><input type="checkbox" id="notePrivate"> Office only</label>' : ""}<button class="btn small" data-act="note">Add note</button></div>
    <ul class="hist">${ev || '<li class="sub">Nothing yet.</li>'}</ul>
  </div>`;
}

// Wires every button inside a referral detail. ctx: { role, root, refresh(id), say(text, bad), network(), ourUnits, consentText, navigators }
export function wireRef(r, ctx) {
  const box = ctx.root.querySelector(`[data-ref="${r.id}"]`);
  const slot = box.querySelector(".nslot");
  const run = async (btn, fn, okText) => {
    btn.disabled = true; ctx.say("Saving ...");
    try { await fn(); flush(); ctx.say(okText || "Saved."); await ctx.refresh(r.id); }
    catch (e) { ctx.say(e.message, true); btn.disabled = false; }
  };
  box.addEventListener("click", async (e) => {
    const b = e.target.closest("[data-act]"); if (!b) return;
    const a = b.dataset.act;
    if (a === "ref-edit") {
      slot.innerHTML = `<div class="panel">${formHtml(refFields(ctx.role, ctx.navigators), r)}${r.consent_on ? "" : consentHtml(ctx.consentText)}<div class="row"><button class="btn primary" data-act="ref-save">Save</button><button class="linkbtn" data-act="slot-close">Cancel</button></div></div>`;
      slot.scrollIntoView({ behavior: "smooth", block: "start" });
    }
    if (a === "slot-close") slot.innerHTML = "";
    if (a === "ref-save") run(b, () => rpc("nav_referral_save", { p: { ...readForm(slot), id: r.id } }));
    if (a === "ref-step") {
      if (b.dataset.to === "searching" && ["matched", "approved"].includes(r.status) && !confirm("Release the unit and go back to searching?")) return;
      run(b, () => rpc("nav_referral_step", { p_id: r.id, p_to: b.dataset.to, p: {} }));
    }
    if (a === "ref-match") {
      const net = await ctx.network();
      const opts = net.flatMap((l) => l.units.flatMap((u) => (u.rooms || []).length
        ? u.rooms.filter((rm) => rm.status === "available").map((rm) => `<option value="r:${esc(rm.id)}">${esc(u.address)}${u.unit_label ? " " + esc(u.unit_label) : ""} · ${esc(rm.label)} · ${rm.monthly_rate ? money(rm.monthly_rate) : "rate not set"}${rm.furnished ? " · furnished" : ""}</option>`)
        : u.status === "available" ? [`<option value="n:${esc(u.id)}">${esc(u.address)}${u.unit_label ? " " + esc(u.unit_label) : ""} · ${esc(l.business_name || l.name)} · ${u.bedrooms || "?"} bd · ${u.rent ? money(u.rent) : "rent ?"}</option>`] : []));
      const ours = ctx.role === "staff" ? (ctx.ourUnits || []).map((u) => `<option value="o:${esc(u.id)}">2nd Chance: ${esc(u.label)}</option>`) : [];
      slot.innerHTML = `<div class="panel"><label class="nf">Unit<select class="field" id="mUnit"><option value="">Choose an available unit ...</option>${opts.join("")}${ours.join("")}</select></label>
        ${ctx.role === "staff" ? '<label class="nf">Monthly rent (only for a 2nd Chance unit)<input class="field" id="mRent" inputmode="decimal"></label>' : ""}
        <label class="nf">Note (optional)<input class="field" id="mNote"></label>
        <div class="row"><button class="btn primary" data-act="match-go">Match</button><button class="linkbtn" data-act="slot-close">Cancel</button></div>
        ${opts.length ? "" : '<p class="sub">No available units or rooms yet. Add your landlords and units on the Housing tab.</p>'}</div>`;
    }
    if (a === "match-go") {
      const v = slot.querySelector("#mUnit").value; if (!v) return ctx.say("Choose a unit.", true);
      const p = { note: slot.querySelector("#mNote").value };
      if (v.startsWith("r:")) p.nav_room_id = v.slice(2); else if (v.startsWith("n:")) p.nav_unit_id = v.slice(2); else { p.rental_unit_id = v.slice(2); p.rent = (slot.querySelector("#mRent")?.value || "").replace(/[^0-9.]/g, ""); }
      run(b, () => rpc("nav_referral_step", { p_id: r.id, p_to: "matched", p }), "Matched. Next: confirm the placement.");
    }
    if (a === "ref-approve") {
      const short = r.gap != null && Number(r.gap) > 0;
      slot.innerHTML = `<div class="panel">${short ? `<div class="banner warn">The person is <b>${money(r.gap)}</b> a month short. Confirming needs a note saying how the gap is covered.</div>` : ""}
        ${r.income_verified_on ? "" : '<div class="banner warn">Income is not marked verified. Verify it under Edit details, or write why you confirm anyway.</div>'}
        <label class="nf">Note${short || !r.income_verified_on ? " (required)" : " (optional)"}<input class="field" id="aNote"></label>
        <div class="row"><button class="btn primary" data-act="approve-go">Confirm the placement</button><button class="linkbtn" data-act="slot-close">Cancel</button></div></div>`;
    }
    if (a === "approve-go") run(b, () => rpc("nav_referral_step", { p_id: r.id, p_to: "approved", p: { note: slot.querySelector("#aNote").value } }), ctx.role === "staff" ? "Confirmed. The Navigator has been emailed." : "Placement confirmed.");
    if (a === "ref-movein") {
      slot.innerHTML = `<div class="panel"><label class="nf">Move-in date<input class="field" type="date" id="miDate" value="${new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" })}"></label>
        <label class="nf">How often to check in at first<select class="field" id="miEvery">${everyOpts(r.checkin_every || "daily")}</select></label>
        <label class="nf">First check-in (leave empty to follow the plan)<input class="field" type="date" id="miFirst"></label>
        <label class="nf">Why this plan (optional)<input class="field" id="miNote" placeholder="e.g. daily the first week, nervous about living alone"></label>
        <div class="row"><button class="btn primary" data-act="movein-go">Record the move-in</button><button class="linkbtn" data-act="slot-close">Cancel</button></div>
        <p class="sub">Check-ins follow this plan and can change any time. The 90-day and 12-month stability reviews are scheduled too.</p></div>`;
    }
    if (a === "movein-go") run(b, () => rpc("nav_referral_step", { p_id: r.id, p_to: "moved_in", p: { move_in_on: slot.querySelector("#miDate").value,
      checkin_every: slot.querySelector("#miEvery").value, first_checkin_on: slot.querySelector("#miFirst").value, checkin_note: slot.querySelector("#miNote").value } }), "Move-in recorded. Welcome home!");
    if (a === "plan-edit") {
      slot.innerHTML = `<div class="panel"><label class="nf">How often<select class="field" id="plEvery">${everyOpts(r.checkin_every || "weekly")}</select></label>
        <label class="nf">Next check-in (leave empty to count from today)<input class="field" type="date" id="plNext" value="${esc(r.next_checkin_on || "")}"></label>
        <label class="nf">Why (optional)<input class="field" id="plNote" value="${esc(r.checkin_note || "")}"></label>
        <div class="row"><button class="btn primary" data-act="plan-go">Save the plan</button><button class="linkbtn" data-act="slot-close">Cancel</button></div></div>`;
      slot.scrollIntoView({ behavior: "smooth", block: "start" });
    }
    if (a === "plan-go") run(b, () => rpc("nav_checkin_plan_save", { p_id: r.id, p_every: slot.querySelector("#plEvery").value, p_next: slot.querySelector("#plNext").value || null, p_note: slot.querySelector("#plNote").value }), "Check-in plan saved.");
    if (a === "ref-close") {
      slot.innerHTML = `<div class="panel"><label class="nf">Why is it closing?<select class="field" id="cReason"><option value="">Choose ...</option>${Object.entries(CLOSE_REASONS).filter(([k]) => k !== "consent_withdrawn").map(([k, t]) => `<option value="${k}">${esc(t)}</option>`).join("")}</select></label>
        <label class="nf">Note<input class="field" id="cNote"></label><div class="row"><button class="btn primary" data-act="close-go">Close the referral</button><button class="linkbtn" data-act="slot-close">Cancel</button></div></div>`;
    }
    if (a === "close-go") run(b, () => rpc("nav_referral_step", { p_id: r.id, p_to: "closed", p: { close_reason: slot.querySelector("#cReason").value, note: slot.querySelector("#cNote").value } }));
    if (a === "ref-withdraw") {
      if (!confirm("The person withdrew their consent? The referral closes and their information is no longer shared.")) return;
      run(b, () => rpc("nav_referral_withdraw_consent", { p_id: r.id }), "Consent withdrawn. The referral is closed.");
    }
    if (a === "fu-save") {
      const row = b.closest(".furow"), [sel, chk, note] = [row.querySelector("select"), row.querySelector("input[type=checkbox]"), row.querySelector("input.field")];
      if (!sel.value) return ctx.say("Pick how the person is doing.", true);
      run(b, () => rpc("nav_followup_save", { p_id: row.dataset.fu, p_outcome: sel.value, p_rent_current: chk ? chk.checked : null, p_note: note.value }), "Check-in saved.");
    }
    if (a === "note") run(b, () => rpc("nav_note", { p_id: r.id, p_text: box.querySelector("#noteText").value, p_private: !!box.querySelector("#notePrivate")?.checked }), "Note added.");
  });
  const whole = box.querySelector(".nwhole");
  if (whole) wholeConsent(whole, r.id, ctx);
  const own = box.querySelector(".nown");
  if (own) ownRoom(own, r.id, ctx);
}

// ---------------------------------------------------------------- sharing beyond housing (Human Mirror TN.1, migration 20261119610000)
// After the housing consent, the person may choose which private parts of their life their Navigator may see in their Human Mirror.
// They read the exact words and type their own full name. The database keeps the words; withdrawing the housing consent ends this too.
const WHOLE_ACCESS = { none: "Not shared", view: "Can see", edit: "Can see and change" };
/** The same sentence the database keeps (nav_whole_words). */
function wholeWords(W, t) {
  const on = W.topics.filter((x) => t[x.key] === "view" || t[x.key] === "edit"), off = W.topics.filter((x) => !(t[x.key] === "view" || t[x.key] === "edit"));
  return "Beyond housing, I agree that " + W.receiver + " may work with me on my Human Mirror and see "
    + (on.length ? on.map((x) => x.mine + (t[x.key] === "edit" ? " (see and change)" : " (see)")).join(", ") : "none of my private topics")
    + ". Everything else private stays private: " + (off.length ? off.map((x) => x.mine).join(", ") : "nothing")
    + ". My name, my goals and my strengths are seen by an organization I work with. I can change or stop this at any time by telling my Navigator"
    + " or the office (info@2ndchinc.org), and stopping my housing consent stops this too.";
}
// ---------------------------------------------------------------- a room the Navigator runs (TN.4, migration 20261119640000)
// A match to a home the person's own Navigator runs is marked, and the placement waits until the person confirms on screen,
// typing their full name, that they know it and chose it. The database enforces it; the office lists these matches.
async function ownRoom(el, id, ctx) {
  let O;
  try { O = await rpc("nav_own_room_state", { p_id: id }); } catch (e) { el.innerHTML = ""; return; }
  if (!O.own_room) { el.innerHTML = ""; return; }
  const c = O.confirmed;
  el.innerHTML = c
    ? `<div class="banner ok"><b>A room you run:</b> ${esc(O.place)}. The person confirmed they know and chose it: <b>${esc(c.name)}</b>, ${fmtDate(String(c.at).slice(0, 10))}.
        <details><summary class="sub">The words they agreed to</summary><div class="sub">${esc(c.words)}</div></details></div>`
    : `<div class="banner warn"><b>A room you run:</b> ${esc(O.place)}. Before the placement is confirmed, hand the screen to the person.
        ${O.status === "matched" || O.status === "approved" ? `<p style="margin:6px 0">${esc(O.words)}</p>
        <label class="nf">Their full name, typed by them (${esc(O.full_name)})<input class="field" data-o="name" autocomplete="off"></label>
        <div class="row"><button class="btn primary small" data-o="save">They confirm</button></div>` : ""}</div>`;
  el.querySelector('[data-o="save"]')?.addEventListener("click", async (e) => {
    const b = e.currentTarget; b.disabled = true; ctx.say("Saving ...");
    try { await rpc("nav_own_room_confirm", { p_id: id, p_consent_name: el.querySelector('[data-o="name"]').value }); ctx.say("Confirmed. You can now confirm the placement."); ownRoom(el, id, ctx); }
    catch (err) { ctx.say(err.message, true); b.disabled = false; }
  });
}

// ---------------------------------------------------------------- their Human Mirror (TN.2, migration 20261119620000)
const MIRROR_STATUS = { invited: "invited: it opens to you once they sign in and accept", active: "active", ended: "ended (their housing consent was withdrawn)" };
function mirrorBlock(W) {
  const m = W.mirror;
  if (m) return `<div class="banner ok"><b>Their Human Mirror:</b> ${esc(MIRROR_STATUS[m.status] || m.status || "")}.
      ${m.status === "active" ? ` <a class="btn small" href="https://2ndchinc.org/mirror/workspace/person/?id=${encodeURIComponent(m.individual_id)}&org=${encodeURIComponent(m.organization_id)}" target="_blank" rel="noopener">Open their Mirror</a>
      <a class="btn small" href="https://2ndchinc.org/mirror/workspace/checkins/?id=${encodeURIComponent(m.individual_id)}&org=${encodeURIComponent(m.organization_id)}" target="_blank" rel="noopener">Check-ins and their Mirror needs</a>
      <div class="sub">The Mirror has its own sign-in at https://2ndchinc.org/mirror/sign-in/ with an authenticator app.</div>` : ""}</div>`;
  if (!W.can_start_mirror) return "";
  return `<div class="banner"><b>Human Mirror</b> (optional): a private place for their whole life, not only housing: their needs, strengths, goals and plan.
      <button class="btn small" data-m="open">Start their Mirror</button><div class="mslot"></div></div>`;
}
function wireMirror(el, W, id, ctx) {
  el.querySelector('[data-m="open"]')?.addEventListener("click", () => {
    const slot = el.querySelector(".mslot");
    slot.innerHTML = `<div class="panel">
      ${W.has_email ? '<label class="chk"><input type="radio" name="mWay" value="email" checked> Invite them with their email: they sign in and fill it in themselves, and it opens to you once they accept</label>' : ""}
      <label class="chk"><input type="radio" name="mWay" value="none"${W.has_email ? "" : " checked"}> Without email: you fill it in together with them</label>
      <label class="chk"><input type="checkbox" data-m="yes"> I asked them, and they said yes to starting a Human Mirror with me</label>
      <div class="sub">What they shared beyond housing goes with it. No email is sent.</div>
      <div class="row"><button class="btn primary" data-m="go">Start their Mirror</button><button class="linkbtn" data-m="no">Cancel</button></div></div>`;
    slot.querySelector('[data-m="no"]').addEventListener("click", () => { slot.innerHTML = ""; });
    slot.querySelector('[data-m="go"]').addEventListener("click", async (e) => {
      const b = e.currentTarget; b.disabled = true; ctx.say("Saving ...");
      try {
        await rpc("nav_mirror_start", { p_id: id, p_with_email: (slot.querySelector('input[name="mWay"]:checked') || {}).value === "email", p_person_agreed: slot.querySelector('[data-m="yes"]').checked });
        ctx.say("Their Human Mirror is started."); wholeConsent(el, id, ctx);
      } catch (err) { ctx.say(err.message, true); b.disabled = false; }
    });
  });
}
async function wholeConsent(el, id, ctx) {
  let W;
  try { W = await rpc("nav_whole_consent", { p_id: id }); } catch (e) { el.innerHTML = `<div class="sub">${esc(e.message)}</div>`; return; }
  const c = W.current;
  const shared = c ? W.topics.filter((x) => ["view", "edit"].includes(c.topics[x.key])).map((x) => esc(x.label) + (c.topics[x.key] === "edit" ? " (see and change)" : " (see)")) : [];
  el.innerHTML = mirrorBlock(W) + (W.own_signin
    ? `<div class="banner"><b>Sharing beyond housing:</b> they have their own Human Mirror sign-in, so they choose what they share themselves, in their Mirror Settings.${c ? ` Last signed here by ${esc(c.signed_by)} on ${fmtDate(String(c.signed_at).slice(0, 10))}.` : ""}</div>`
    : c
    ? `<div class="banner ${c.withdrawn_on ? "" : "ok"}"><b>Sharing beyond housing</b> signed by <b>${esc(c.signed_by)}</b> on ${fmtDate(String(c.signed_at).slice(0, 10))}${c.withdrawn_on ? ` · <b>ended ${fmtDate(c.withdrawn_on)}</b>` : ""}:
        ${shared.length ? shared.join(", ") : "no private topics"}.${W.can_record ? ' <button class="linkbtn" data-w="open">Change</button>' : ""}
        <details><summary class="sub">The words they agreed to</summary><div class="sub">${esc(c.words)}</div></details></div>`
    : W.can_record ? `<div class="banner"><b>Sharing beyond housing</b> (optional): the person can choose which private parts of their life you may see in their Human Mirror,
        such as health, money or documents. <button class="btn small" data-w="open">Record their choice</button></div>` : "");
  wireMirror(el, W, id, ctx);
  el.querySelector('[data-w="open"]')?.addEventListener("click", () => {
    const cur = (c && !c.withdrawn_on && c.topics) || {};
    el.innerHTML = `<div class="panel"><h3 class="nsec" style="margin-top:0">Sharing beyond housing</h3>
      <div class="sub">Hand the screen to the person. For each topic they choose; "Not shared" keeps it private. Housing information stays under their housing consent.</div>
      ${W.topics.map((x) => `<label class="nf">${esc(x.label)}<select class="field" data-topic="${esc(x.key)}">${Object.entries(WHOLE_ACCESS).map(([k, v]) => `<option value="${k}"${(cur[x.key] || "none") === k ? " selected" : ""}>${esc(v)}</option>`).join("")}</select></label>`).join("")}
      <div class="banner warn"><b>They agree to:</b><p style="margin:6px 0" data-w="words"></p>
        <label class="nf">Their full name, typed by them (${esc(W.full_name)})<input class="field" data-w="name" autocomplete="off"></label></div>
      <div class="row"><button class="btn primary" data-w="save">Save their choice</button><button class="linkbtn" data-w="cancel">Cancel</button></div></div>`;
    const pick = () => Object.fromEntries([...el.querySelectorAll("[data-topic]")].map((x) => [x.dataset.topic, x.value]));
    const show = () => { el.querySelector('[data-w="words"]').textContent = wholeWords(W, pick()); };
    el.querySelectorAll("[data-topic]").forEach((x) => x.addEventListener("change", show)); show();
    el.querySelector('[data-w="cancel"]').addEventListener("click", () => wholeConsent(el, id, ctx));
    el.querySelector('[data-w="save"]').addEventListener("click", async (e) => {
      const b = e.currentTarget; b.disabled = true; ctx.say("Saving ...");
      try { await rpc("nav_whole_consent_save", { p_id: id, p_topics: pick(), p_consent_name: el.querySelector('[data-w="name"]').value }); ctx.say("Saved: sharing beyond housing."); wholeConsent(el, id, ctx); }
      catch (err) { ctx.say(err.message, true); b.disabled = false; }
    });
  });
}

export function refList(list, staff) {
  if (!list.length) return '<p class="sub">No referrals yet.</p>';
  return `<div class="table-wrap"><table class="t"><thead><tr><th>Referral</th><th>Person</th><th>Pathway</th>${staff ? "<th>Navigator</th>" : ""}<th>Status</th><th>Updated</th></tr></thead><tbody>${
    list.map((r) => `<tr class="click" data-open="${esc(r.id)}"><td><a href="#" data-open="${esc(r.id)}">${esc(r.label)}</a></td><td>${nameOf(r)}</td><td>${esc(PATHWAYS[r.pathway] || r.pathway)}</td>${staff ? `<td>${esc(r.navigator || "Office")}</td>` : ""}<td>${pill(r.status)}</td><td>${fmtDate(r.updated_at)}</td></tr>`).join("")}</tbody></table></div>`;
}

// ---------------------------------------------------------------- housing network
const LL_FIELDS = (staff) => [
  "Landlord", ["name", "Contact name", "text"], ["business_name", "Business name", "text"], ["phone", "Phone", "tel"], ["email", "Email", "email"], ["mailing_address", "Mailing address", "text"],
  ["accepts_vouchers", "Accepts housing vouchers", "yesno"], ["accepts_assistance", "Accepts agency rent payments", "yesno"],
  ["requirements", "The landlord's own requirements for tenants", "area"], ["notes", "Notes", "area"],
  ...(staff ? ["Office only", ["shared", "Office landlord: show to every Navigator (a Navigator's own landlord is always private)", "check"], ["status", "Status", "select", LL_STATUS], ["agreement_status", "Participation agreement", "select", AGREEMENT], ["agreement_on", "Agreement date", "date"]] : []),
];
const UNIT_FIELDS = (staff) => [
  "Unit", ["address", "Street address", "text"], ["unit_label", "Unit (e.g. Upper, #3)", "text"], ["city", "City", "text"], ["zip", "ZIP", "text"],
  ["bedrooms", "Bedrooms", "num"], ["bathrooms", "Bathrooms", "num"], ["rent", "Monthly rent ($)", "num"], ["deposit", "Security deposit ($)", "num"], ["application_fee", "Application fee ($)", "num"],
  ["utilities_included", "Utilities included", "text"], ["accessibility", "Accessibility (ground floor entry, grab bars, ramp ...)", "text"], ["ground_floor", "No stairs to enter", "yesno"],
  ["accepts_vouchers", "Accepts vouchers", "yesno"], ["pets", "Pets", "text"], ["available_on", "Available on", "date"],
  ["status", "Status", "select", staff ? UNIT_STATUS : { available: "Available", maintenance: "Maintenance", off_market: "Off market" }], ["notes", "Notes", "area"],
  ...(staff ? [] : [["operated", "I lease and run this unit (I rent rooms to residents)", "check"]]),
  ...(staff ? ["Office only", ["inspection_status", "Inspection", "select", INSPECTION], ["inspected_on", "Inspected on", "date"]] : []),
];

export function networkHtml(list, role) {
  const staff = role === "staff";
  const cards = list.map((l) => {
    const edit = staff || l.mine;
    const units = (l.units || []).map((u) => `<tr data-unit-row="${esc(u.status)}"><td>${esc(u.address)}${u.unit_label ? " " + esc(u.unit_label) : ""}<div class="sub">${esc(u.city || "")} ${esc(u.zip || "")}</div></td>
        <td>${esc(u.bedrooms ?? "—")} bd / ${esc(u.bathrooms ?? "—")} ba</td><td>${u.rent ? money(u.rent) : "—"}${u.deposit ? `<div class="sub">dep. ${money(u.deposit)}</div>` : ""}</td>
        <td>${esc(u.utilities_included || "")}${u.accessibility ? `<div class="sub">${esc(u.accessibility)}</div>` : ""}${u.ground_floor ? '<div class="sub">No stairs to enter</div>' : ""}</td>
        <td><span class="pill ${u.status === "available" ? "ok" : u.status === "reserved" ? "warn" : "off"}">${esc(UNIT_STATUS[u.status] || u.status)}</span>${u.available_on ? `<div class="sub">from ${fmtDate(u.available_on)}</div>` : ""}<div class="sub">${esc(INSPECTION[u.inspection_status] || "")}</div></td>
        <td>${u.manage ? `<a class="btn small" href="/navigator/unit/?id=${esc(u.id)}">Unit file</a> ` : ""}${edit ? `<button class="linkbtn" data-act="unit-edit" data-ll="${esc(l.id)}" data-id="${esc(u.id)}">Edit</button>` : ""}${(u.rooms || []).length ? `<div class="sub">${u.rooms.length} rooms, ${u.rooms.filter((r) => r.status === "available").length} open${u.operator ? " · run by " + esc(u.operator) : ""}</div>` : u.operator ? `<div class="sub">run by ${esc(u.operator)}</div>` : ""}</td></tr>`).join("");
    return `<div class="panel ll" data-ll-card="${esc(l.id)}">
      <div class="row" style="justify-content:space-between"><h3 style="margin:0">${esc(l.business_name || l.name)}${l.business_name ? ` <span class="sub">${esc(l.name)}</span>` : ""}</h3>
        <span><span class="pill ${l.agreement_status === "signed" ? "ok" : "warn"}">${esc(AGREEMENT[l.agreement_status] || "")}</span> <span class="pill off">${esc(LL_STATUS[l.status] || l.status)}</span></span></div>
      <div class="sub">${[l.phone, l.email].filter(Boolean).map(esc).join(" · ") || "No contact on file"}${l.accepts_vouchers === true ? " · accepts vouchers" : l.accepts_vouchers === false ? " · no vouchers" : ""}${l.accepts_assistance ? " · accepts agency payments" : ""}${l.placements ? ` · ${l.placements} housed` : ""}${staff && l.added_by ? ` · added by ${esc(l.added_by)}` : ""}${l.mine ? " · yours, private" : ""}${!staff && l.office ? " · 2nd Chance office listing" : ""}${staff && l.office && !l.shared ? " · office only" : ""}</div>
      ${l.requirements ? `<div class="sub"><b>Requirements:</b> ${esc(l.requirements)}</div>` : ""}${l.notes ? `<div class="sub"><b>Notes:</b> ${esc(l.notes)}</div>` : ""}
      ${units ? `<div class="table-wrap"><table class="t"><thead><tr><th>Unit</th><th>Size</th><th>Rent</th><th>Utilities / access</th><th>Status</th><th></th></tr></thead><tbody>${units}</tbody></table></div>` : '<p class="sub">No units yet.</p>'}
      ${edit ? `<div class="row"><button class="btn small" data-act="unit-edit" data-ll="${esc(l.id)}">Add a unit</button><button class="linkbtn" data-act="ll-edit" data-id="${esc(l.id)}">Edit landlord</button></div>` : ""}
    </div>`;
  }).join("");
  return `<div class="row">${role === "preview" ? "" : '<button class="btn primary" data-act="ll-edit">Add a landlord</button>'}
    <label class="chk"><input type="checkbox" id="onlyAvail"> Show available units only</label></div>
    <div id="netEditor"></div>${cards || `<p class="sub">${staff ? "No landlords yet." : "No landlords yet. Add the landlords you work with: only you and the 2nd Chance office see them."}</p>`}`;
}

export function wireNetwork(root, ctx) {
  const ed = () => root.querySelector("#netEditor");
  root.addEventListener("change", (e) => {
    if (e.target.id !== "onlyAvail") return;
    root.querySelectorAll("[data-unit-row]").forEach((tr) => { tr.hidden = e.target.checked && tr.dataset.unitRow !== "available"; });
  });
  root.addEventListener("click", async (e) => {
    const b = e.target.closest("[data-act]"); if (!b) return;
    const a = b.dataset.act, list = ctx.list();
    const staff = ctx.role === "staff";
    if (a === "ll-edit") {
      const l = list.find((x) => x.id === b.dataset.id) || { shared: false, status: "prospect", agreement_status: "none" };
      ed().innerHTML = `<div class="panel" data-ll="${esc(l.id || "")}">${formHtml(LL_FIELDS(staff), l)}<div class="row"><button class="btn primary" data-act="ll-save">Save landlord</button><button class="linkbtn" data-act="ed-close">Cancel</button></div></div>`;
      ed().scrollIntoView({ behavior: "smooth", block: "start" });
    }
    if (a === "unit-edit") {
      const l = list.find((x) => x.id === b.dataset.ll); const u0 = (l?.units || []).find((x) => x.id === b.dataset.id); const u = u0 ? { ...u0, operated: u0.operated_by_me } : { city: "Milwaukee", status: "available", operated: true };
      ed().innerHTML = `<div class="panel" data-unit="${esc(u.id || "")}" data-llid="${esc(l.id)}"><div class="sub">Landlord: ${esc(l.business_name || l.name)}</div>${formHtml(UNIT_FIELDS(staff), u)}<div class="row"><button class="btn primary" data-act="unit-save">Save unit</button><button class="linkbtn" data-act="ed-close">Cancel</button></div></div>`;
      ed().scrollIntoView({ behavior: "smooth", block: "start" });
    }
    if (a === "ed-close") ed().innerHTML = "";
    if (a === "ll-save" || a === "unit-save") {
      const panel = b.closest(".panel"); b.disabled = true; ctx.say("Saving ...");
      try {
        if (a === "ll-save") await rpc("nav_landlord_save", { p: { ...readForm(panel), id: panel.dataset.ll } });
        else await rpc("nav_unit_save", { p: { ...readForm(panel), id: panel.dataset.unit, landlord_id: panel.dataset.llid } });
        flush(); ctx.say("Saved."); await ctx.refresh();
      } catch (err) { ctx.say(err.message, true); b.disabled = false; }
    }
  });
}

export const NAV_CSS = `
  .nform{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px 14px}
  .nform .nsec,.nform .wide,.nform .checks{grid-column:1/-1}
  .nsec{margin:10px 0 0;font-size:1rem}
  .nf{display:grid;gap:4px;font-size:.88rem;color:var(--muted)}
  .nf .field{color:var(--fg)}
  .chk{display:inline-flex;gap:6px;align-items:center;font-size:.9rem}
  .checks{border:1px solid var(--line);border-radius:4px;display:flex;flex-wrap:wrap;gap:6px 16px;padding:8px 12px}
  .checks label{display:inline-flex;gap:6px;align-items:center;color:var(--fg)}
  .kv{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px}
  .kv div{border:1px solid var(--line);border-radius:6px;padding:8px 10px}
  .kv span{display:block;font-size:.8rem;color:var(--muted)} .kv b{display:block;font-size:1.05rem}
  table.t{width:100%;border-collapse:collapse;font-size:.93rem} table.t th,table.t td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
  tr.click{cursor:pointer} tr.click:hover{background:var(--accent-soft)}
  .furow{display:flex;flex-wrap:wrap;gap:6px;align-items:center} .furow .field{width:auto;flex:1;min-width:140px}
  .hist{list-style:none;padding:0;margin:0;display:grid;gap:8px}
  .tabs{display:flex;flex-wrap:wrap;gap:4px;border-bottom:1px solid var(--line)}
  .tabs a{padding:8px 14px;text-decoration:none;color:var(--fg);font-weight:600;border-bottom:3px solid transparent}
  .tabs a.on{border-color:var(--accent);color:var(--accent)}
  .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
  .stats div{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:10px 12px} .stats b{display:block;font-size:1.5rem} .stats span{font-size:.82rem;color:var(--muted)}
`;
