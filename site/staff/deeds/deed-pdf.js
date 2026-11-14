// Draws a quit claim deed PDF in the browser from one saved deed row (needs the pdf-lib script tag on the page).
// Two Illinois statutory layouts: "cook" and "peoria". Filled values are underlined; empty ones print as blank rules.
const { PDFDocument, StandardFonts, rgb, degrees } = PDFLib;
const W = 612, H = 792, M = 54;
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const clean = (s) => String(s ?? "").replace(/[^\n\x20-\x7E -ÿ‘’“”–—•]/g, "?");
const has = (s) => !!String(s ?? "").trim();
const ordinal = (n) => n + (n % 100 >= 11 && n % 100 <= 13 ? "th" : ["th", "st", "nd", "rd"][n % 10] || "th");
const names = (a) => (Array.isArray(a) ? a : []).map((s) => String(s || "").trim()).filter(Boolean);

// Greedy word wrap that preserves every character. A single word wider than the line is broken at the line width.
export const wrapText = (t, measure, w) => { const out = []; let cur = "";
  const push = () => { if (cur) { out.push(cur); cur = ""; } };
  for (const word of String(t).split(/\s+/).filter(Boolean)) { let wd = word;
    while (measure(wd) > w && wd.length > 1) { let k = wd.length; while (k > 1 && measure(wd.slice(0, k)) > w) k--; push(); out.push(wd.slice(0, k)); wd = wd.slice(k); }
    const tryLine = cur ? cur + " " + wd : wd; if (measure(tryLine) > w && cur) { push(); cur = wd; } else cur = tryLine; }
  push(); return out; };

export async function buildDeedPdf(d) {
  // Names and capacities go on a legal instrument: refuse characters the PDF fonts cannot print instead of silently printing a question mark.
  const unprintable = [...names(d.grantors), ...names(d.grantees)].filter((x) => clean(x) !== String(x).replace(/\n/g, "\n"));
  if (unprintable.length) throw new Error("These names contain characters the PDF fonts cannot print, so they would print wrongly: " + unprintable.join("; ") + ". Use plain letters here and have counsel add the exact spelling to the final instrument.");
  const pdf = await PDFDocument.create();
  pdf.setTitle("Quit Claim Deed");
  const R = await pdf.embedFont(StandardFonts.TimesRoman), B = await pdf.embedFont(StandardFonts.TimesRomanBold);
  const BI = await pdf.embedFont(StandardFonts.TimesRomanBoldItalic), HB = await pdf.embedFont(StandardFonts.HelveticaBold);
  const HBO = await pdf.embedFont(StandardFonts.HelveticaBoldOblique);
  let page, y;
  const Y = (top) => H - top;
  const newPage = () => { page = pdf.addPage([W, H]); y = M; };
  const need = (h) => { if (y + h > H - M) newPage(); };
  const text = (s, x, top, o = {}) => page.drawText(clean(s), { x, y: Y(top), size: o.size || 11, font: o.font || R, color: rgb(0, 0, 0) });
  const line = (x1, x2, top, t = 0.7) => page.drawLine({ start: { x: x1, y: Y(top) }, end: { x: x2, y: Y(top) }, thickness: t, color: rgb(0, 0, 0) });
  const vline = (x, t1, t2, t = 0.7) => page.drawLine({ start: { x, y: Y(t1) }, end: { x, y: Y(t2) }, thickness: t, color: rgb(0, 0, 0) });
  // A line of text sitting on a rule (a blank form line, filled when there is a value).
  const field = (value, x, top, w, o = {}) => { line(x, x + w, top); if (has(value)) text(value, x + 2, top - 2, { size: o.size || 10 }); };
  const blank = (v, n) => (has(v) ? v : "_".repeat(n));

  // Flowing paragraph. tokens: {t, u: underline, b: bold, nl: keep newlines as line breaks}.
  const para = (tokens, o = {}) => {
    const size = o.size || 11, lead = o.lead || size * 1.75, x0 = o.x ?? M, right = o.right ?? W - M;
    let cx = x0, row = [];
    const flush = () => {
      for (const it of row) {
        page.drawText(it.w, { x: it.x, y: Y(y), size, font: it.f, color: rgb(0, 0, 0) });
        if (it.u) page.drawLine({ start: { x: it.x, y: Y(y) - 2 }, end: { x: it.x + it.width, y: Y(y) - 2 }, thickness: 0.6, color: rgb(0, 0, 0) });
      }
      row = []; cx = x0; y += lead; need(lead);
    };
    need(lead);
    for (const k of tokens) {
      const f = k.b ? B : R;
      for (const w of clean(k.t).split(/(\s+)/)) {
        if (w === "") continue;
        if (/^\s+$/.test(w)) {
          if (k.nl && w.includes("\n")) { flush(); continue; }
          if (!row.length) continue;
          const width = f.widthOfTextAtSize(" ", size);
          row.push({ w: " ", f, x: cx, width, u: k.u }); cx += width; continue;
        }
        const width = f.widthOfTextAtSize(w, size);
        if (cx + width > right && row.length) { while (row.length && row[row.length - 1].w === " ") row.pop(); flush(); }
        row.push({ w, f, x: cx, width, u: k.u }); cx += width;
      }
    }
    if (row.length) flush();
  };
  const val = (v, n = 20) => ({ t: blank(v, n), u: has(v) });

  const dateParts = () => {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d.deed_date || "");
    return m ? { day: ordinal(+m[3]), month: MONTHS[+m[2] - 1], year: m[1] } : null;
  };
  // Signature slots, two per row; the typed name goes under each rule.
  // Signature slots: two per row, or one full-width slot per row when a name or capacity is long. Names wrap; nothing runs into a neighbor.
  const signatures = (sigs, o) => {
    const long = sigs.some((t) => (t || "").length > 34), per = long ? 1 : 2, w = long ? 420 : 215, xs = long ? [M - 10] : [M - 10, 330];
    const items = sigs.length ? sigs : [""], total = per === 2 ? Math.ceil(items.length / 2) * 2 : items.length;
    const slot = Array.from({ length: total }, (_, i) => items[i] || "");
    for (let r = 0; r < slot.length; r += per) {
      const lines = slot.slice(r, r + per).map((t) => (t ? wrapText(clean(t), (x) => B.widthOfTextAtSize(x, 10), w) : [o.placeholder]));
      const rowH = 18 + Math.max(...lines.map((l) => l.length)) * 12 + 22;
      need(rowH);
      lines.forEach((ls, k) => { const x = xs[k]; line(x, x + w, y); text(o.seal, x + w + 2, y, { size: 11 }); ls.forEach((t, j) => text(t, x + 2, y + 13 + j * 12, { font: slot[r + k] ? B : HB, size: slot[r + k] ? 10 : 9 })); });
      y += rowH;
    }
    y += 8;
  };

  const grantors = names(d.grantors), grantees = names(d.grantees), dt = dateParts();
  const legalTokens = has(d.legal_description) ? [{ t: d.legal_description.trim(), nl: true }] : null;
  const consid = has(d.consideration) ? d.consideration.trim() : "Ten ($10.00) DOLLARS and other good and valuable consideration(s)";
  const dated = (prefix) => para(dt
    ? [{ t: `${prefix} this ` }, { t: dt.day, u: true }, { t: " day of " }, { t: dt.month, u: true }, { t: ", " }, { t: dt.year, u: true }]
    : [{ t: `${prefix} this ____ day of ______________, 20____` }], { lead: 20 });

  // Notary acknowledgment (the venue, the certificate, the signature and the seal box), kept together on one page.
  const ack = () => { const L = M - 14;
    text("STATE OF ILLINOIS     )", L + 4, 64, { size: 11 }); text(")  SS.", 120, 80, { size: 11 }); text("County of ______________ )", L + 4, 96, { size: 11 }); y = 130;
    para([{ t: "I, the undersigned, a Notary Public in and for said County, in the State aforesaid, CERTIFY THAT, " }, { t: " (Print or type name here) ", b: true },
      val(grantors.join(", "), 30), { t: " personally known to me to be the same persons whose names are subscribed to the foregoing instrument, appeared before me this day in person, and acknowledged that they signed, sealed and delivered the instrument as free and voluntary act, for the uses and purposes therein set forth, including the release and waiver of the right of homestead." }],
      { x: L, size: 10.5, lead: 16 });
    y += 12; para([{ t: "Given under my hand and notaries seal, this ____ day of ______________, 20____" }], { x: L + 4, size: 10.5, lead: 16 });
    y += 20; line(L + 130, L + 270, y); text("Notary Public", L + 6, y + 14, { font: HBO, size: 10.5 });
    text("My commission expires on ______________", L + 6, y + 34, { size: 10.5 });
    page.drawRectangle({ x: 330, y: Y(y + 70), width: 230, height: 60, borderColor: rgb(0, 0, 0), borderWidth: 1 });
    text("IMPRESS SEAL HERE", 400, y + 8, { font: HB, size: 8 });
    y += 100;
  };
  newPage();
  if (d.template === "peoria") {
    const X = 36;
    text("THIS DOCUMENT PREPARED BY:", X, 52, { size: 7 });
    (d.prepared_by || "").split("\n").slice(0, 4).forEach((s, i) => text(s, X, 64 + i * 10, { size: 9 }));
    text("RETURN DOCUMENT TO:", X, 105, { size: 7 });
    (d.return_to || "").split("\n").slice(0, 4).forEach((s, i) => text(s, X, 117 + i * 10, { size: 9 }));
    vline(209, 49, 199, 1.2); vline(214, 49, 199, 1.2);
    text("QUIT CLAIM DEED", X, 191, { font: B, size: 17 });
    text("For Recorder's Use Only", 340, 189, { size: 10 });
    line(X, W - X, 199, 2);
    y = 232;
    para([{ t: "The Grantor,  ", b: true }, val(grantors.join(", "), 40), { t: `, of the City/Village of ` }, val(d.grantor_city, 14),
      { t: " in the County of " }, val(d.grantor_county, 12), { t: " and State of Illinois for and in consideration of the sum of " }, { t: consid, u: true },
      { t: " in hand paid, CONVEY AND QUIT CLAIM to " }, val(grantees.join(", "), 40)], { x: X, right: W - X, size: 10.5, lead: 22 });
    para([{ t: "in the form of ownership: " }, val(d.ownership_form, 18), { t: " of the City/Village of " }, val(d.grantee_city, 14),
      { t: " in the County of " }, val(d.grantee_county || "Peoria", 12), { t: ", and State of Illinois" }], { x: X, right: W - X, size: 10.5, lead: 22 });
    para([{ t: "all interest in the following described real estate:" }], { x: X, right: W - X, size: 10.5, lead: 22 });
    y += 4;
    para(legalTokens || [{ t: "See Attached" }], { x: X, right: W - X, size: 10.5, lead: 14 });
    y += 14;
    need(110);
    const top = y;
    page.drawRectangle({ x: 376, y: Y(top + 78), width: 200, height: 78, borderColor: rgb(0, 0, 0), borderWidth: 1.2 });
    text("Exempt 35 ILCS 200/31-45 (", 388, top + 18, { size: 9.5 });
    text(d.exempt_letter || "", 509, top + 18, { size: 10, font: B }); text(")", 530, top + 18, { size: 9.5 });
    line(388, 565, top + 42); text("Date", 462, top + 53, { size: 9.5 });
    line(388, 565, top + 66); text("Buyer, Seller, or Representative", 410, top + 76, { size: 8.5 });
    text("PIN:", X, top + 30, { size: 10.5 }); if (has(d.pin)) text(d.pin, X + 30, top + 30, { size: 10.5 });
    text("COMMONLY KNOWN AS:", X, top + 62, { size: 10.5 });
    if (has(d.property_address)) text(d.property_address, X + R.widthOfTextAtSize("COMMONLY KNOWN AS:", 10.5) + 6, top + 62, { size: 10.5 });
    y = top + 100;
    para([{ t: "situated in the County of " }, val(d.property_county || "Peoria", 12),
      { t: ", in the State of Illinois, hereby releasing and waiving all rights under and by virtue of the Homestead Exemption Laws of the State of Illinois." }],
      { x: X, right: W - X, size: 10.5, lead: 16 });
    y += 10; need(40 + Math.ceil(Math.max(grantors.length, 1) / 2) * 52); dated("Dated"); y += 14;
    signatures(grantors, { seal: "(SEAL)", placeholder: "" });
    newPage(); ack();
  } else {
    // Cook County layout
    vline(252, 0, 290, 3); line(252, W, 280, 3);
    text("Quit Claim Deed", M - 14, 100, { font: B, size: 25 });
    text("ILLINOIS STATUTORY", M - 14, 130, { font: HBO, size: 13 });
    text("MAIL TO:", M - 14, 158, { font: B, size: 11 });
    const mail = (d.mail_to || "").split("\n"), tax = (d.taxpayer || "").split("\n");
    for (let i = 0; i < 4; i++) field(mail[i], M - 14, 178 + i * 12, 150, { size: 9 });
    text("NAME & ADDRESS OF TAX PAYER:", M - 14, 240, { font: B, size: 11 });
    for (let i = 0; i < 3; i++) field(tax[i], M - 14, 262 + i * 12, 150, { size: 9 });
    text("THE GRANTOR(S)", M - 14, 322, { font: BI, size: 14 });
    y = 343;
    const gc = d.grantor_county || "Cook", pc = d.property_county || "Cook";
    para([val(grantors.join(", "), 60), { t: ", of the " }, { t: gc, u: has(d.grantor_county) }, { t: " County of the State of Illinois for and in consideration of " },
      { t: consid, u: has(d.consideration) }, { t: " in hand paid, CONVEY AND QUIT CLAIM " }, { t: "to", b: true }, { t: " " }, val(grantees.join(", "), 60), { t: ", of the County " },
      { t: d.grantee_county || "Cook", u: has(d.grantee_county) }, { t: " and the State of Illinois, all interest in the following described real estate situated in the County of " },
      { t: pc, u: has(d.property_county) }, { t: ", in the State of Illinois, to wit:" }], { lead: 18 });
    y += 6;
    para([{ t: "(LEGAL DESCRIPTION)" }], { lead: 16 });
    if (legalTokens) para(legalTokens, { lead: 13 });
    else { need(40); line(M - 14, 470, y); line(M - 14, 190, y + 20); y += 34; }
    y += 8;
    para([{ t: "hereby releasing and waiving all rights under and by virtue of the Homestead Exemption Laws of the State of Illinois." }], { lead: 17 });
    para([{ t: "TO HAVE AND TO HOLD the above granted premises unto the parties of the second part forever, not as joint tenants or tenants by the entirety, but as tenants in common." }], { lead: 18 });
    need(60);
    text("Permanent Index Number(s):", M - 14, y, { size: 11 }); field(d.pin, M - 14 + 150, y, 360); y += 20;
    text("Property Address:", M - 14, y, { size: 11 }); field(d.property_address, M - 14 + 100, y, 270); y += 22;
    need(30 + Math.ceil(Math.max(grantors.length, 1) / 2) * 52); dated("Dated"); y += 6;
    signatures(grantors, { seal: "(Seal)", placeholder: "(Print or type name here)" });
    y += 2;
    y += 12;
    text("NOTE:  PLEASE TYPE OR PRINT NAME BELOW ALL SIGNATURES", 160, y, { size: 11 });
    // Page 2: acknowledgment, preparer and transfer tax exemption, as on the recorded Cook form.
    newPage(); ack(); const L = M - 14;
    text("•  If Grantor is also Grantee you may want to strike Release & Waiver of Homestead Rights.", L, y, { size: 9.5 }); y += 34;
    text("NAME AND ADDRESS OF PREPARER:", L + 10, y, { size: 10 });
    (d.prepared_by || "").split("\n").slice(0, 4).forEach((s, i) => text(s, L + 10, y + 14 + i * 12, { size: 10 }));
    text("EXEMPT UNDER PROVISIONS OF PARAGRAPH", 330, y, { size: 10 });
    text("35 ILCS 200/31-45 (", 330, y + 14, { size: 10 }); text(d.exempt_letter || "", 424, y + 14, { size: 10, font: B }); text(")  SECTION 4,", 436, y + 14, { size: 10 });
    text("REAL ESTATE TRANSFER ACT.", 330, y + 28, { size: 10 });
    text("DATE:", 330, y + 52, { size: 10 }); line(362, 560, y + 52);
    line(330, 560, y + 72); text("Signature of Buyer, Seller or Representative.", 345, y + 84, { size: 9.5 });
    y += 120;
    text("•  This conveyance must contain the name and address of the Grantee for tax billing purposes: (55 ILCS 5/3-5020)", L, y, { size: 9.5 });
    text("and name and address of the person preparing the instrument: (55 ILCS 5/3-5022).", L + 8, y + 12, { size: 9.5 });
  }
  const pages = pdf.getPages(), idText = "Quit claim deed" + (has(d.property_address) ? " · " + String(d.property_address).slice(0, 60) : "");
  pages.forEach((pg, i) => { pg.drawText(clean(idText) + " · page " + (i + 1) + " of " + pages.length, { x: M - 14, y: 22, size: 8, font: R, color: rgb(0.35, 0.35, 0.35) });
    if (!d.blank && !has(d.approved_by)) pg.drawText("DRAFT - NOT APPROVED FOR SIGNING", { x: 70, y: 250, size: 38, font: HB, color: rgb(0.88, 0.88, 0.88), rotate: degrees(35), opacity: 0.6 }); });
  return await pdf.save();
}
