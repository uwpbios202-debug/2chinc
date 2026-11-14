// Court attachments for a served eviction notice, as SEPARATE PDFs (the eFiling site: "Documents must not be bundled"):
// the notice exactly as mailed (original bytes), the stamped USPS certified mail receipt, and the RENT ledger (Rent Income only; late fees are never part of a filing).
// Used by /documents/notices/ and /staff/efile/. New file (not added to portal.js) because browsers cache portal.js for hours.
const PDFLIB = "https://cdnjs.cloudflare.com/ajax/libs/pdf-lib/1.17.1/pdf-lib.min.js";
async function loadPdfLib() {
  if (!window.PDFLib) await new Promise((ok, bad) => { const s = document.createElement("script"); s.src = PDFLIB; s.onload = ok; s.onerror = () => bad(new Error("Couldn't load the PDF maker.")); document.head.appendChild(s); });
  return window.PDFLib;
}
const asc = (s) => String(s ?? "").replace(/[–—]/g, "-").replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/[^\x20-\x7e]/g, "");
const usd = (n) => "$" + Math.abs(Number(n || 0)).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const today = () => new Date().toLocaleDateString("en-US", { timeZone: "America/Chicago", month: "2-digit", day: "2-digit", year: "numeric" });
const mdy = (d) => d ? new Date(String(d).slice(0, 10) + "T12:00:00").toLocaleDateString("en-US", { month: "2-digit", day: "2-digit", year: "numeric" }) : "";

export async function courtPacket(client, id, btn, errorText) {
  const label = btn.textContent; btn.disabled = true; btn.textContent = "Making the packet…";
  const signedBytes = async (path) => {
    const { data, error } = await client.storage.from("notices").createSignedUrl(path, 300);
    if (error) throw new Error("Couldn't open " + path);
    const r = await fetch(data.signedUrl); if (!r.ok) throw new Error("Couldn't download " + path);
    return r.blob();
  };
  try {
    const { data: p, error } = await client.rpc("notice_court_packet", { p_id: id });
    if (error) throw new Error(errorText ? await errorText(error) : error.message);
    if (!p.pdf_path) throw new Error("There is no PDF of the notice on file. The court needs the notice exactly as served.");
    if (!p.proof_path) throw new Error("There is no stamped certified mail receipt on file. Add it on the Notices page first.");
    // The ledger's own total must equal the unpaid rent the site reports, or the court would see two different numbers.
    let run = 0; for (const r of p.rows) run += Number(r.amount);
    if (Math.abs(Math.max(run, 0) - Math.max(Number(p.rent_due), 0)) > 0.005)
      throw new Error(`The rent ledger adds up to ${usd(run)} but the unpaid rent is ${usd(p.rent_due)}. Fix the ledger before filing.`);
    const { PDFDocument, StandardFonts, rgb } = await loadPdfLib();
    const W = 612, H = 792, M = 54;
    const fresh = async () => { const doc = await PDFDocument.create(); return { doc, font: await doc.embedFont(StandardFonts.Helvetica), bold: await doc.embedFont(StandardFonts.HelveticaBold) }; };
    const writer = (d) => ({
      text: (pg, s, x, y, o = {}) => pg.drawText(asc(s), { x, y, size: o.size || 10, font: o.bold ? d.bold : d.font, color: rgb(0, 0, 0) }),
      right(pg, s, xr, y, o = {}) { const t = asc(s); this.text(pg, t, xr - (o.bold ? d.bold : d.font).widthOfTextAtSize(t, o.size || 10), y, o); },
    });
    const download = (bytes, name) => { const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([bytes], { type: "application/pdf" })); a.download = asc(name);
      document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 60000); };
    // The eFiling site says "Documents must not be bundled": each attachment is its own PDF, named as the court lists it.
    // 1. The notice exactly as mailed: the original file, byte for byte.
    download(await (await signedBytes(p.pdf_path)).arrayBuffer(), "2 - 5-Day Notice to Pay Rent or Vacate.pdf");
    // 2. The stamped certified mail receipt, upright (the browser applies the photo's orientation).
    {
      const d = await fresh(), w = writer(d), pg = d.doc.addPage([W, H]);
      w.text(pg, "Proof of Mailing: USPS Certified Mail Receipt (PS Form 3800)", M, H - M, { size: 13, bold: true });
      w.text(pg, `${p.tenants || ""}, ${p.address || ""}`, M, H - M - 18);
      const bmp = await createImageBitmap(await signedBytes(p.proof_path), { imageOrientation: "from-image" });
      const c = document.createElement("canvas"); c.width = bmp.width; c.height = bmp.height; c.getContext("2d").drawImage(bmp, 0, 0);
      const jpg = await d.doc.embedJpg(await (await new Promise((ok) => c.toBlob(ok, "image/jpeg", 0.9))).arrayBuffer());
      const k = Math.min((W - 2 * M) / jpg.width, (H - 2 * M - 40) / jpg.height);
      pg.drawImage(jpg, { x: (W - jpg.width * k) / 2, y: H - M - 34 - jpg.height * k, width: jpg.width * k, height: jpg.height * k });
      download(await d.doc.save(), "3 - Proof of Mailing - Certified Receipt with Stamp.pdf");
    }
    // 3. Rent ledger (Rent Income only).
    {
      const d = await fresh(), w = writer(d);
      const cols = [M, M + 72, W - M - 190, W - M - 100, W - M];
      let pg, y;
      const head = () => {
        pg = d.doc.addPage([W, H]); y = H - M;
        w.text(pg, "Rent Ledger", M, y, { size: 14, bold: true }); w.right(pg, "2nd Chance Housing Inc.", W - M, y, { bold: true }); y -= 16;
        w.text(pg, `${p.tenants || ""}`, M, y); w.right(pg, `Printed ${today()}`, W - M, y); y -= 13;
        w.text(pg, `${p.address || ""}${p.account_number ? "  -  Account " + p.account_number : ""}`, M, y); y -= 13;
        w.text(pg, "Rent charges and rent payments only. Late fees are not included.", M, y, { size: 9 }); y -= 20;
        w.text(pg, "Date", cols[0], y, { bold: true }); w.text(pg, "Description", cols[1], y, { bold: true });
        w.right(pg, "Charges", cols[2] + 80, y, { bold: true }); w.right(pg, "Payments", cols[3] + 80, y, { bold: true }); w.right(pg, "Balance", cols[4], y, { bold: true });
        y -= 5; pg.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.7 }); y -= 13;
      };
      head();
      let bal = 0;
      for (const r of p.rows) {
        if (y < M + 40) head();
        const a = Number(r.amount); bal = Math.round((bal + a) * 100) / 100;
        w.text(pg, mdy(r.date), cols[0], y, { size: 9 });
        w.text(pg, (r.description || "") + (r.check_number ? " #" + r.check_number : ""), cols[1], y, { size: 9 });
        if (a > 0) w.right(pg, usd(a), cols[2] + 80, y, { size: 9 });
        if (a < 0) w.right(pg, usd(a), cols[3] + 80, y, { size: 9 });
        w.right(pg, (bal < 0 ? "-" : "") + usd(bal), cols[4], y, { size: 9 }); y -= 13;
      }
      y -= 4; pg.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.7 }); y -= 16;
      w.text(pg, `Unpaid rent as of ${today()}:`, M, y, { size: 11, bold: true }); w.right(pg, usd(Math.max(Number(p.rent_due), 0)), W - M, y, { size: 11, bold: true });
      download(await d.doc.save(), "5 - Rent Ledger.pdf");
    }
    btn.textContent = label;
  } catch (e) { btn.textContent = label; alert(e.message || "Couldn't make the packet."); }
  finally { btn.disabled = false; }
}
