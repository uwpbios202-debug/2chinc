// Official Wisconsin court forms, filled by the site (Stephen, 11/12/2026): the English/Spanish SC-500 Summons and Complaint
// (Milwaukee rejects the English-only form) and the SC-5100V Declaration of Service. The court's PDFs have no fill-in fields,
// so each value is written at its place on the page; the result is a plain (flattened) PDF, so nothing can reach the court blank.
// Every value comes from efile_preflight (the same data as the "Type exactly this" sheet): rent only, never late fees.
// Before filling, the site asks court-forms-check whether the court still publishes the exact form kept here; if the court
// changed it, the old one is not filled. Keep KNOWN in step with /assets/forms/ when a form is updated.
const PDFLIB = "https://cdnjs.cloudflare.com/ajax/libs/pdf-lib/1.17.1/pdf-lib.min.js";
async function loadPdfLib() {
  if (!window.PDFLib) await new Promise((ok, bad) => { const s = document.createElement("script"); s.src = PDFLIB; s.onload = ok; s.onerror = () => bad(new Error("Couldn't load the PDF maker.")); document.head.appendChild(s); });
  return window.PDFLib;
}

export const KNOWN = {
  "SC-500": { file: "/assets/forms/SC-500_es.pdf", version: "SC-500, 03/26 (English/Spanish)", revised: "03/05/2026",
    sha256: "f2a82e8dd259d153f1dbaf67d901f6fbdea9aa87ddf964d2d2cf921ea03a6132" },
  "SC-5100V": { file: "/assets/forms/SC-5100V.pdf", version: "SC-5100V, 09/24", revised: "09/12/2024",
    sha256: "772beb238dea83cf2e9c7689725db32e2c1d5628278c4441191096e68d68b155" },
};
const LIST_URL = "https://www.wicourts.gov/forms1/circuit/ccform.jsp?Category=38";
const COURT = ["APPEAR IN PERSON", "Milwaukee County Courthouse", "901 North 9th Street, Room 400", "Milwaukee, WI 53233"];
const CLERK_PHONE = "414-278-4140";
const OFFICE = { address: "6626 North Bourbon Street, Milwaukee, WI 53224", email: "info@2ndchinc.org" };

const asc = (s) => String(s ?? "").replace(/[–—]/g, "-").replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/[^\x20-\x7e]/g, "");
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// ---------- Is the copy kept here still the court's current form? ----------
let lastCheck = null;
export async function checkForms(client) {
  const { data, error } = await client.functions.invoke("court-forms-check", { body: {} });
  if (error) throw new Error("Couldn't reach the court's website to check the forms.");
  const res = (data.forms || []).map((f) => {
    const k = KNOWN[f.code] || {};
    const problems = [];
    if (f.error) problems.push(f.error);
    else if (f.sha256 !== k.sha256) problems.push("The court's PDF is different from the copy the site fills (a new version or a correction).");
    if (f.list_error) problems.push(f.list_error);
    else if (f.revised && f.revised !== k.revised) problems.push(`The court lists it as revised ${f.revised}; the site's copy is from ${k.revised}.`);
    const unreachable = !!f.error && !problems.slice(1).length;
    return { ...f, known: k, current: !problems.length, unreachable, problems };
  });
  lastCheck = { at: data.checked_at, forms: res };
  return lastCheck;
}

export function formsReport(r) {
  return `<ul style="margin:6px 0 0;padding-left:20px">${r.forms.map((f) => `<li style="margin:4px 0">${f.current
    ? `<b style="color:#145c2c">${esc(f.code)}: up to date.</b> <span class="meta">${esc(f.known.version)}, revised ${esc(f.revised || f.known.revised)} on the court's list${f.note && /correction/i.test(f.note) ? ` (${esc((f.note.match(/Correction published on [0-9/]+/i) || [""])[0])}, already in this copy)` : ""}.</span>`
    : `<b style="color:#8c1d18">${esc(f.code)}: ${f.unreachable ? "could not check" : "the court changed this form"}.</b> ${f.problems.map(esc).join(" ")}
       <a href="${esc(f.url)}" target="_blank" rel="noopener">Open the court's current form</a>. ${f.unreachable ? "" : "The site will not fill the old one: ask Claude to update the site's copy."}`}</li>`).join("")}</ul>
    <p class="meta" style="margin:6px 0 0">Checked ${esc(new Date(r.at).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }))} against <a href="${LIST_URL}" target="_blank" rel="noopener">the court's small claims forms list</a>.</p>`;
}

// Before filling: stop if the court changed the form; go on (with a warning) only if the court's website could not be reached.
async function guard(client, code, msg) {
  let r;
  try { r = await checkForms(client); } catch { if (msg) msg("Couldn't reach the court's website to confirm the form is current. Filled anyway: compare the date at the bottom left with the court's form before filing."); return; }
  const f = r.forms.find((x) => x.code === code);
  if (f && !f.current && !f.unreachable) throw new Error(`The court changed ${code} (${f.problems.join(" ")}). Not filled: ask Claude to update the site's copy, or fill the court's current form by hand from the "Type exactly this" sheet.`);
  if (f && f.unreachable && msg) msg("Couldn't download the court's form to compare. Filled anyway: compare the date at the bottom left with the court's form before filing.");
}

// ---------- Layout helpers ----------
async function open(code) {
  const { PDFDocument, StandardFonts, rgb } = await loadPdfLib();
  const r = await fetch(KNOWN[code].file); if (!r.ok) throw new Error("The blank " + code + " is missing from the site.");
  const doc = await PDFDocument.load(await r.arrayBuffer());
  const font = await doc.embedFont(StandardFonts.Helvetica), bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const ink = rgb(0, 0, 0);
  const put = (pg, s, x, y, o = {}) => {
    const f = o.bold ? bold : font; let size = o.size || 10; const t = asc(s);
    if (o.max) while (size > 6 && f.widthOfTextAtSize(t, size) > o.max) size -= 0.25;
    doc.getPage(pg).drawText(t, { x, y, size, font: f, color: ink });
  };
  const X = (pg, x, y) => put(pg, "X", x, y, { bold: true, size: 10 });
  const wrap = (s, size, width, f = font) => {
    const out = []; let line = "";
    for (const w of asc(s).split(/\s+/).filter(Boolean)) { const tryLine = line ? line + " " + w : w; if (f.widthOfTextAtSize(tryLine, size) > width && line) { out.push(line); line = w; } else line = tryLine; }
    if (line) out.push(line); return out;
  };
  return { doc, font, bold, put, X, wrap, PDFDocument, StandardFonts, rgb };
}
function save(bytes, name) {
  const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([bytes], { type: "application/pdf" })); a.download = asc(name);
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 60000);
}
// "6626 North Bourbon Street, Unit #4, Milwaukee, WI 53224" -> ["6626 North Bourbon Street, Unit #4", "Milwaukee, WI 53224"]
function splitAddress(a) {
  const s = asc(a).trim(); const m = s.match(/^(.*),\s*([^,]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?)$/);
  return m ? [m[1], m[2]] : [s, ""];
}
const names = (t) => (t.defendants || []).map((d) => asc(d.name).trim()).filter(Boolean);
const lastNames = (t) => names(t).map((n) => n.split(/\s+/).pop()).join("-");

// ---------- SC-500 Summons and Complaint (English/Spanish, 03/26) ----------
export async function fillSC500(client, v, btn, msg) {
  const label = btn.textContent; btn.disabled = true; btn.textContent = "Checking the court's form…";
  try {
    const t = v.type || {};
    if (Number(v.stops) > 0) throw new Error("Fix the STOP items first.");
    if (!names(t).length) throw new Error("There is no defendant on the lease.");
    if (!t.defendant_address) throw new Error("The rental address is missing.");
    await guard(client, "SC-500", msg);
    btn.textContent = "Filling the SC-500…";
    const P = await open("SC-500"), { put, X, wrap, font } = P;
    const plaintiff = asc(t.plaintiff || "2nd Chance Housing Inc.");
    const [pStreet, pCity] = splitAddress(t.plaintiff_address || OFFICE.address);
    const [dStreet, dCity] = splitAddress(t.defendant_address);
    const defs = names(t);

    // Page 1: caption.
    put(0, "MILWAUKEE", 250, 745, { size: 11, bold: true });
    put(0, plaintiff, 48, 698, { max: 255 }); put(0, pStreet, 48, 686, { max: 255 }); put(0, pCity, 48, 674, { max: 255 });
    // Defendants: up to 2 names on their own lines, then the address; more than 4 lines go on an attached page.
    const dLines = defs.length <= 2 ? [...defs, dStreet, dCity] : [defs.join(", "), dStreet, dCity];
    const fits = dLines.length <= 4 && font.widthOfTextAtSize(asc(dLines[0]), 7) <= 255;
    if (fits) dLines.forEach((l, i) => put(0, l, 48, 576 - i * 12, { max: 255 }));
    else { put(0, defs[0] + " (and others, see attached)", 48, 576, { max: 255 }); put(0, dStreet, 48, 564, { max: 255 }); put(0, dCity, 48, 552, { max: 255 }); X(0, 219, 525); }    // "See attached for additional defendants"
    X(0, 413, 470);                                    // Eviction and related claims 31004: the only box
    put(0, CLERK_PHONE, 468, 265, { size: 9 });        // accommodations: the clerk's small claims number
    X(0, 57, 145);                                     // You must appear at the time and place stated
    COURT.forEach((l, i) => put(0, l, 366, 84 - i * 10, { size: 9 }));

    // Page 2: complaint. Eviction only (the rent claim is stated in the facts, not as a second box).
    X(1, 78, 445);
    const facts = asc(t.statement || "");
    let extra = null;
    if (facts) {
      // The facts box runs from y 275 down to 231: shrink the type (not below 7 pt) until every line fits inside it.
      const cap = (sz) => Math.floor((267 - 233) / (sz + 0.5)) + 1;
      let size = 9, lines = wrap(facts, size, 505);
      while (lines.length > cap(size) && size > 7) { size -= 0.25; lines = wrap(facts, size, 505); }
      if (lines.length <= cap(size)) lines.forEach((l, i) => put(1, l, 74, 267 - i * (size + 0.5), { size }));
      else { put(1, "See the attached statement of dates and facts.", 76, 265, { size: 9 }); extra = facts; }
    }
    X(1, 78, 216);                                     // See attached (notice, receipt, ledger)
    X(1, 126, 188);                                    // I am the plaintiff
    // Page 3: plaintiff's block. Albert signs and dates in ink.
    const signer = asc(t.signer || "Albert Harris");
    put(2, /^2nd chance housing/i.test(plaintiff) ? `${signer}, President, ${plaintiff}` : `${signer}, for ${plaintiff}`, 44, 716, { max: 250 });
    put(2, t.plaintiff_address || OFFICE.address, 44, 692, { max: 250 });
    put(2, OFFICE.email, 44, 668);
    put(2, t.phone || "(262) 236-5443", 44, 644);

    // Attached page (allowed: "It may be supplemented with additional material") for long facts or more than 2 defendants.
    if (extra || !fits) {
      const pg = P.doc.addPage([612, 792]); let y = 740;
      const line = (s, o = {}) => { pg.drawText(asc(s), { x: 54, y, size: o.size || 10, font: o.bold ? P.bold : font, color: P.rgb(0, 0, 0) }); y -= (o.size || 10) + 5; };
      line(`Attachment to SC-500 Summons and Complaint: ${plaintiff} v. ${defs.join(", ")}`, { bold: true, size: 11 }); y -= 6;
      if (!fits) { line("Defendants:", { bold: true }); defs.forEach((d) => line(`${d}, ${dStreet}, ${dCity}`)); y -= 8; }
      if (extra) { line("2. Brief statement of dates and facts:", { bold: true }); wrap(extra, 10, 504).forEach((l) => line(l)); }
    }
    P.doc.setTitle("Summons and Complaint");
    save(await P.doc.save(), `1 - Summons and Complaint - ${lastNames(t) || "tenant"}.pdf`);
    if (msg && !facts) msg("Filled. This is not a nonpayment notice, so write the facts (item 2 on page 2) before filing.");
    else if (msg) msg("Filled and downloaded. Print it; Albert signs page 3 and writes the date; scan it back to PDF and open it to check every word and X shows.", true);
  } catch (e) { if (msg) msg(e.message || String(e)); else alert(e.message || e); }
  finally { btn.disabled = false; btn.textContent = label; }
}

// ---------- SC-5100V Declaration of Service (09/24): the caption only; the person who served fills in and signs the rest. ----------
export async function fillSC5100V(client, v, btn, msg) {
  const label = btn.textContent; btn.disabled = true; btn.textContent = "Checking the court's form…";
  try {
    const t = v.type || {};
    if (!v.case_number) throw new Error("Record the case number first (step 10).");
    await guard(client, "SC-5100V", msg);
    btn.textContent = "Filling the SC-5100V…";
    const P = await open("SC-5100V"), { put } = P;
    const defs = names(t);
    put(0, "MILWAUKEE", 150, 732, { size: 11, bold: true });
    put(0, t.plaintiff || "2nd Chance Housing Inc.", 196, 711, { max: 150 });
    if (defs.length <= 2) defs.forEach((d, i) => put(0, d, 216, 649 - i * 13, { max: 135 }));
    else { put(0, defs.slice(0, 2).join(", "), 216, 649, { max: 135 }); put(0, defs.slice(2).join(", "), 216, 636, { max: 135 }); }
    put(0, v.case_number, 427, 574, { max: 120 });
    P.doc.setTitle("Declaration of Service");
    save(await P.doc.save(), `Declaration of Service SC-5100V - ${lastNames(t) || "tenant"} - ${asc(v.case_number)}.pdf`);
    if (msg) msg("Filled: county, parties and case number. Give it to the person who served the papers (the sheriff or process server, not Albert): they tick the boxes, fill in the service and sign page 2. File it before the court date.", true);
  } catch (e) { if (msg) msg(e.message || String(e)); else alert(e.message || e); }
  finally { btn.disabled = false; btn.textContent = label; }
}

// ---------- Service request for the process server (one page) ----------
// After May 2026 (affidavit for "6622 N Bourbon Street #112" instead of Unit 12): the server gets the exact names and the address
// with the unit number from the case data, never retyped in an email. v = efile_preflight data with case_number, court_at, court_place.
export async function serviceRequest(v, unit, btn, msg) {
  const label = btn.textContent; btn.disabled = true; btn.textContent = "Making the service request…";
  try {
    const t = v.type || {}, defs = names(t);
    if (!v.case_number || !v.court_at) throw new Error("Record the case number and court date first.");
    if (!defs.length || !t.defendant_address) throw new Error("The defendant or the address is missing.");
    const { PDFDocument, StandardFonts, rgb } = await loadPdfLib();
    const doc = await PDFDocument.create(), pg = doc.addPage([612, 792]);
    const font = await doc.embedFont(StandardFonts.Helvetica), bold = await doc.embedFont(StandardFonts.HelveticaBold);
    let y = 744; const L = 54, W = 504;
    const line = (s, o = {}) => { const f = o.bold ? bold : font, size = o.size || 10.5;
      for (const l of wrapText(asc(s), f, size, W - (o.indent || 0))) { pg.drawText(l, { x: L + (o.indent || 0), y, size, font: f, color: rgb(0, 0, 0) }); y -= size + 4; } };
    const gap = (n = 6) => { y -= n; };
    const court = new Date(v.court_at);
    const tz = { timeZone: "America/Chicago" };
    const courtTxt = court.toLocaleString("en-US", { ...tz, weekday: "long", month: "long", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
    const cd = new Date(court.toLocaleDateString("en-CA", tz) + "T12:00:00"); cd.setDate(cd.getDate() - 5);
    const serveBy = cd.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: "numeric" });
    const [street, city] = splitAddress(t.defendant_address);
    line("SERVICE REQUEST: SMALL CLAIMS EVICTION", { bold: true, size: 15 }); gap(2);
    line("From: 2nd Chance Housing Inc., 6626 North Bourbon Street, Milwaukee, WI 53224 - (262) 236-5443 - info@2ndchinc.org", { size: 9.5 }); gap(8);
    line(`Milwaukee County Circuit Court - Case No. ${v.case_number}`, { bold: true, size: 12 });
    line(`${asc(t.plaintiff || "2nd Chance Housing Inc.")} v. ${defs.join(", ")}`);
    line(`Court date: ${courtTxt}${v.court_place ? ", " + asc(v.court_place) : ""}`); gap(8);
    line(`SERVE BY: ${serveBy}`, { bold: true, size: 13 });
    line("The papers must be served at least 5 days before the court date. Sooner is better.", { size: 9.5 }); gap(8);
    line(defs.length > 1 ? "SERVE EACH OF THESE PEOPLE (each one gets a full set):" : "SERVE THIS PERSON:", { bold: true });
    defs.forEach((d) => line(d, { bold: true, size: 13, indent: 14 })); gap(4);
    line("AT THIS ADDRESS:", { bold: true });
    line(street, { bold: true, size: 13, indent: 14 }); line(city, { bold: true, size: 13, indent: 14 });
    if (unit) line(`Unit number: ${unit}  (the unit is ${unit}; no other number)`, { indent: 14 });
    line("To be let into the building, call (262) 236-5443. Door codes are not given out.", { indent: 14, size: 9.5 }); gap(8);
    line("PAPERS TO SERVE", { bold: true });
    ["The Electronic Filing Notice", "The authenticated Summons and Complaint (SC-500) with the court's seal and case number", "The attached exhibits (the notice, the certified mail receipt, the rent ledger)"]
      .forEach((s) => line("- " + s, { indent: 14 })); gap(8);
    line("HOW", { bold: true });
    line("1. Personal service on each person named above.", { indent: 14 });
    line("2. If a person cannot be found after reasonable efforts: leave a copy at the unit with a competent adult (14 or older) who lives there, tell them what the papers are, and record that adult's name or description.", { indent: 14 });
    line("3. If neither works, call us at (262) 236-5443 before posting or mailing: those methods have their own rules and deadlines.", { indent: 14 }); gap(8);
    line("RETURN", { bold: true });
    line("Within 1 business day after service, email the signed and notarized affidavit of service to info@2ndchinc.org. It must show:", { indent: 14 });
    [`Case No. ${v.case_number}`, "Each person's full name exactly as above", `The address exactly as above, with the unit number${unit ? " (" + unit + ")" : ""}`,
     "The date and time of service and how it was served (who received it, if not the person named)", "The papers served (as listed above)"]
      .forEach((s) => line("- " + s, { indent: 28 }));
    gap(6); line("If anything on this page looks wrong (name, unit, date), call us before serving.", { bold: true, size: 9.5 });
    doc.setTitle("Service request");
    save(await doc.save(), `Service request - ${lastNames(t) || "tenant"} - ${asc(v.case_number)}.pdf`);
    if (msg) msg("Downloaded. Send it to the process server with the court's papers from step 11.", true);
  } catch (e) { if (msg) msg(e.message || String(e)); else alert(e.message || e); }
  finally { btn.disabled = false; btn.textContent = label; }
}
function wrapText(s, f, size, width) {
  const out = []; let line = "";
  for (const w of s.split(/\s+/).filter(Boolean)) { const t = line ? line + " " + w : w; if (f.widthOfTextAtSize(t, size) > width && line) { out.push(line); line = w; } else line = t; }
  if (line) out.push(line); return out.length ? out : [""];
}
