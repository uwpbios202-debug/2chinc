// The caseworker's document packet, sent by email with no sign-in (county mail systems often block our sign-in page):
// the signed lease and ROCA1's W-9 as PDF attachments, plus the ways to pay. Used by lease-signing (when a lease is
// executed) and caseworker-packet (staff button). The caseworker portal stays available for paying online.
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";
import { escapeHtml as esc, PORTAL_BASE_URL } from "./config.ts";
import { sendEmail } from "./mail.ts";

const BUCKET = "lease-signing";
const P = "topmostSubform[0].Page1[0].";
const setting = async (admin: any, key: string) => (await admin.from("portal_settings").select("value").eq("key", key).maybeSingle()).data?.value || "";
const b64 = (bytes: Uint8Array) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(s); };

// ROCA1's W-9 on the current IRS form. The name matches the Wisconsin DFI record exactly (entity 6R10148), which is what agencies check.
// Classification: C corporation (a section 528 association files as a corporation); no exempt payee code (Stephen, 10/22/2026).
export async function buildRoca1W9(admin: any): Promise<Uint8Array | null> {
  const ein = (await setting(admin, "roca1_w9_ein")).replace(/\D/g, "");
  if (ein.length !== 9) return null;
  const { data: ag } = await admin.from("lease_agents").select("signature_path").eq("active", true).ilike("name", "Albert Harris").limit(1).maybeSingle();
  if (!ag?.signature_path) return null;
  const { data: sig, error } = await admin.storage.from(BUCKET).download(ag.signature_path);
  if (error || !sig) throw error || new Error("signature missing");
  const r = await fetch(new URL("/assets/forms/fw9.pdf", PORTAL_BASE_URL));
  if (!r.ok) throw new Error("blank W-9 not found");
  const pdf = await PDFDocument.load(new Uint8Array(await r.arrayBuffer()));
  const f = pdf.getForm();
  f.getTextField(P + "f1_01[0]").setText("Royal Orleans Condominium - Addition One, Inc.");
  f.getCheckBox(P + "Boxes3a-b_ReadOrder[0].c1_1[1]").check();               // C corporation
  f.getTextField(P + "Address_ReadOrder[0].f1_07[0]").setText("6626 N Bourbon St");
  f.getTextField(P + "Address_ReadOrder[0].f1_08[0]").setText("Milwaukee, WI 53224");
  f.getTextField(P + "f1_14[0]").setText(ein.slice(0, 2));
  f.getTextField(P + "f1_15[0]").setText(ein.slice(2));
  f.flatten();
  for (let i = pdf.getPageCount() - 1; i >= 1; i--) pdf.removePage(i);       // the form itself, without the instructions
  const pg = pdf.getPage(0);
  const img = await pdf.embedPng(new Uint8Array(await sig.arrayBuffer()));
  const h = 26, w = Math.min(img.width * (h / img.height), 220);
  pg.drawImage(img, { x: 142, y: 196, width: w, height: h });
  const today = new Date().toLocaleDateString("en-US", { timeZone: "America/Chicago", month: "2-digit", day: "2-digit", year: "numeric" });
  pg.drawText(today, { x: 418, y: 200, size: 10, font: await pdf.embedFont(StandardFonts.Helvetica), color: rgb(0, 0, 0) });
  return await pdf.save();
}

// Emails one caseworker the packet for one lease. Returns what was attached, or throws if the signed lease is not on file.
export async function sendCaseworkerPacket(admin: any, cw: { name: string; email: string }, leaseId: string, ccStaff = true) {
  const { data: lease } = await admin.from("leases").select("signing_doc_id, start_date, rental_units(address, unit_number)").eq("id", leaseId).single();
  const { data: d } = lease?.signing_doc_id ? await admin.from("lease_signing_docs").select("executed_pdf_path, unit_label").eq("id", lease.signing_doc_id).single() : { data: null };
  if (!d?.executed_pdf_path) throw new Error("The signed lease is not on file yet.");
  const { data: pdf, error } = await admin.storage.from(BUCKET).download(d.executed_pdf_path);
  if (error || !pdf) throw error || new Error("signed lease missing");
  const w9 = await buildRoca1W9(admin);
  const where = esc(d.unit_label || [lease.rental_units?.address, lease.rental_units?.unit_number].filter(Boolean).join(", "));
  const starts = lease.start_date ? new Date(lease.start_date + "T12:00:00Z").toLocaleDateString("en-US", { timeZone: "UTC" }) : "";
  const attachments = [{ filename: `Lease - ${String(d.unit_label || "signed").replace(/[^\w #.,-]/g, "")} - signed.pdf`, content: b64(new Uint8Array(await pdf.arrayBuffer())) }];
  if (w9) attachments.push({ filename: "ROCA1 W-9.pdf", content: b64(w9) });
  const first = esc(String(cw.name || "").split(/\s+/)[0] || "there");
  await sendEmail({
    to: cw.email,
    subject: `Signed lease${w9 ? " and W-9" : ""} for ${d.unit_label || "your client"}`,
    html: `<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>Hi ${first},</p>
<p>The lease for <b>${where}</b> is signed${starts ? ` and starts ${esc(starts)}` : ""}. ${w9 ? "The signed lease and ROCA1's W-9 are attached as PDFs. You do not need to sign in to anything." : "The signed lease is attached as a PDF."}</p>
<p>Payments are made out to Royal Orleans Condominium - Addition One, Inc. (ROCA1), the agent named on the lease, 6626 N Bourbon St, Milwaukee, WI 53224. We post each one to your client's rent account.</p>
<p>If you would like to pay by secure bank transfer, you can use <a href="${esc(new URL("/caseworker/", PORTAL_BASE_URL).toString())}">our payment page</a> (sign-in is optional; it is not needed for the documents). Or reply to this email or call or text (262) 236-5443 for the bank transfer (ACH) details.</p>
<p>2nd Chance Housing</p></div>`,
    attachments,
  });
  return { lease: d.unit_label, w9: !!w9 };
}
