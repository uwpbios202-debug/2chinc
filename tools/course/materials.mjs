// The printable handouts for the researcher course (site/probate-help/course/materials/*.html). Light, print-friendly pages.
// Everything about the practice family is FICTIONAL. Statutes and pages were read on CHECKED; nothing here states a fee or a processing time.
import { FACTS, BRANCHES, CHECKED, esc } from "./lib.mjs";

const wrap = (title, desc, body, o = {}) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} · Researcher course · 2nd Chance Housing</title><meta name="description" content="${esc(desc)}"><meta name="robots" content="noindex, follow">
<style>
 :root{color-scheme:light}
 *{box-sizing:border-box}
 body{margin:0; font:15px/1.5 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; color:#17231C; background:#F6F7F2}
 main{max-width:960px; margin:0 auto; padding:20px 18px 60px; background:#fff}
 h1{font:700 1.7rem/1.2 Georgia,serif; margin:6px 0 4px} h2{font:700 1.2rem/1.3 Georgia,serif; margin:22px 0 6px; border-bottom:2px solid #2E7D1F; padding-bottom:3px} h3{font-size:1rem; margin:14px 0 4px}
 .top{display:flex; justify-content:space-between; gap:10px; flex-wrap:wrap; font-size:.85rem; color:#506055; border-bottom:1px solid #D4DCD2; padding-bottom:8px; margin-bottom:10px}
 .top a{color:#2E7D1F; font-weight:700}
 .warn{border-left:6px solid #B47A0A; background:#FFF8E6; padding:8px 12px; margin:10px 0; font-size:.92rem}
 .fic{border-left:6px solid #506055; background:#EEF2EA; padding:8px 12px; margin:10px 0; font-size:.88rem}
 table{width:100%; border-collapse:collapse; margin:8px 0; font-size:.88rem} th,td{border:1px solid #AEB9AE; padding:6px 8px; vertical-align:top; text-align:left} th{background:#E6EBE3; font-size:.78rem; text-transform:uppercase; letter-spacing:.05em}
 td.blank{height:28px}
 ul,ol{margin:6px 0 6px 20px} li{margin:3px 0}
 .box{display:inline-block; width:14px; height:14px; border:2px solid #17231C; border-radius:3px; vertical-align:-2px; margin-right:6px}
 .ck{list-style:none; margin-left:0} .ck li{padding-left:24px; position:relative} .ck li::before{content:""; position:absolute; left:0; top:3px; width:14px; height:14px; border:2px solid #17231C; border-radius:3px}
 .line{border-bottom:1px solid #17231C; min-height:22px; margin:6px 0}
 .sig{display:grid; grid-template-columns:1fr 1fr; gap:18px; margin-top:16px} .sig div{border-top:1px solid #17231C; padding-top:3px; font-size:.82rem}
 code{background:#EEF2EA; padding:1px 4px; border-radius:3px; font-size:.86em}
 .small{font-size:.82rem; color:#506055}
 .btn{display:inline-block; background:#2E7D1F; color:#fff; padding:6px 14px; border-radius:6px; border:0; font:700 .85rem sans-serif; cursor:pointer}
 @media print{ body{background:#fff} main{max-width:none; padding:0} .noprint{display:none} h2{break-after:avoid} table,tr{break-inside:avoid} @page{margin:14mm} }
</style></head><body><main>
<div class="top noprint"><span><a href="/probate-help/course/materials/">← All handouts</a> · <a href="/probate-help/course/">Course</a></span><button class="btn" onclick="window.print()">Print this page</button></div>
${o.fiction ? `<div class="fic"><b>Fictional practice material.</b> No real person, parcel, record or court order. Do not use these names or numbers on a real case.</div>` : ""}
<h1>${esc(title)}</h1>
<p class="small">2nd Chance Housing, Inc. Researcher training · Draft for organizational and counsel review · Statutes and official pages last read ${CHECKED} · Not legal advice.</p>
${body}
</main></body></html>`;

const T = (head, rows, o = {}) => `<table><tr>${head.map((h) => `<th>${h}</th>`).join("")}</tr>${rows.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join("")}</tr>`).join("")}</table>`;
const CK = (items) => `<ul class="ck">${items.map((i) => `<li>${i}</li>`).join("")}</ul>`;
const blankRows = (n, cols) => Array.from({ length: n }, () => Array(cols).fill('<span class="blank"></span>'));

export const buildMaterials = (slides) => {
  const pages = {};

  // ---- 1. field checklist ---------------------------------------------------------------------------------------------
  pages["field-checklist.html"] = wrap("Researcher field checklist", "A printable one-sheet checklist for researchers from the first lead to the handoff.",
    `<div class="warn"><b>Rule for every line:</b> done means the evidence is obtained <u>and checked</u>, not that a field is filled. Unknown stays blank. Stop and ask when you reach a line marked <b>ESCALATE</b>.</div>
<h2>1. The lead log (one line per lead)</h2>
${T(["Lead #", "Date / initials", "Channel", "What I saw or read (their words)", "Saved as (file name)", "Status"], blankRows(5, 6))}
<p class="small">Channels: walk (public sidewalk only), obituary, records (recorder, assessor, treasurer), court (existing proceedings). A lead is not proof. Name files like <code>L-0003_recorder-search_PIN-001_2026-04-05.pdf</code>.</p>
<h2>2. Before you approach the family</h2>
${CK(["Searched the Clerk's Recordings for <b>every PIN</b> and saved each result with the search date and the index-through date.", "Checked for an existing estate case and for a lawyer already acting. <b>ESCALATE</b> if either exists.", "Have the organization's card and the approved consent form from my supervisor.", "I will say the four things: who we are; what we offer; what we cannot promise; how to say no."])}
<h2>3. First contact and consent</h2>
${CK(["Said the four things. Did not imply any court, county, city or agency sent me.", "Confirmed who I am speaking with and how they are related. Did not accept a stranger's claim.", "Signed consent obtained: collect, store, share (with whom), contact preferences, how to withdraw.", "Wrote down: date, time, who, what they agreed to, and how they want to be contacted."])}
<h2>4. Intake (one or more sittings)</h2>
${CK(["The person who died: legal name, other names, date and place of death, county of residence, marital status.", "The property: address, <b>every PIN</b>, occupancy, tenants, rent, insurance, taxes, mortgage.", "Papers: death certificate, deed, will or trust, any TODI; who holds each <b>original</b>.", "Family: every spouse or partner, every child (adopted, earlier relationships, deceased), every earlier death; whereabouts.", "Their goal (keep, share, sell, refinance), in their words."])}
<h2>5. Urgent-issues screen (ask every time)</h2>
${CK(["Tax-sale or tax-delinquency notice?", "Foreclosure or lender letter?", "Insurance cancellation, non-renewal, vacancy?", "Dangerous conditions (heat, fire, structure)?", "Lawsuit, court date or lawyer letter?"])}
<p class="small"><b>If yes to any:</b> photograph both sides and the envelope (with permission); copy every date <u>exactly</u> into <b>Urgent deadlines</b>; a second person checks the date; <b>ESCALATE the same day</b> by phone and email to my supervisor. Do not tell the family what it means or what to do.</p>
<h2>6. Evidence and system entries</h2>
${CK(["Before <b>every</b> upload: title, decedent name and one PIN on screen match the paper in my hand.", "Entered facts exactly as written. Left unknowns blank. Wrote each fact's source in the note.", "After a save: watched the bar say <b>All changes saved</b>, then reloaded and checked the value is still there.", "Death certificate fields typed by a person and compared to the scan by a <b>second person</b>. (The page does not read the certificate.)", "Heirs: every spouse, child and earlier death entered or written as an unresolved question. <b>Not</b> ticked complete until double-checked.", "Plan facts ticked only where I hold the evidence."])}
<h2>7. Unresolved questions (keep every one)</h2>
${T(["#", "Question", "Why it matters", "Who can answer", "How I will find out", "Status"], blankRows(4, 6))}
<h2>8. Quality control and handoff</h2>
${CK(["Second person compared identity, dates, <b>every PIN</b>, legal description, family and shares, route, amounts, signatures, notary, privacy, version.", "Numbered file set, evidence index, originals register and unresolved-issues sheet complete.", "One-page cover memo says what is <b>unresolved first</b>.", "Sent to counsel on: ____ . Counsel's reply saved. Accepted / Needs changes / Declined: ____ . Counsel's written approval is on file (a typed name or checkbox in the system is <b>not</b> approval)."])}
<h2>9. Never</h2>
<ul><li>Claim to be a court, county, city or government worker, or a law firm.</li><li>Promise free counsel, ownership, eligibility, savings or results.</li><li>Pressure, return after a no, enter private grounds, or touch mail.</li><li>Use a deceased person's login, card or PIN; treat an old power of attorney as the estate's authority.</li><li>Send a waiver of notice before the petition is filed; sign anything for anyone; backdate.</li><li>Give legal advice: choose a route, say who inherits, or explain what a notice means.</li></ul>
<div class="sig"><div>Researcher (name, date)</div><div>Second-person reviewer (name, date)</div></div>`);

  // ---- 2. intake and consent --------------------------------------------------------------------------------------------
  pages["intake-consent.html"] = wrap("Family intake and consent", "A printable intake interview form and a draft consent form, for organizational and counsel review.",
    `<div class="warn"><b>DRAFT, not approved.</b> The consent text below is a starting point for <b>2nd Chance's leadership and counsel to review, correct and approve</b> before any family signs it. Use only the version your supervisor issues. It is not legal advice.</div>
<h2>Part 1: Consent (read aloud, then sign)</h2>
<p><b>Who we are.</b> 2nd Chance Housing, Inc. is a nonprofit. We are not a law firm and not part of any court or government office. We cannot give legal advice.</p>
<p><b>What we offer.</b> With your permission, we help you gather and organize facts and papers about the property and family of <span class="line" style="display:inline-block;width:260px"></span>, so a lawyer can review them.</p>
<p><b>What we cannot promise.</b> We cannot promise that a lawyer will take the case, that any help will be free, who owns the property, whether you qualify for anything, or any result. A lawyer, the court or a title company decides.</p>
<p><b>I give permission for 2nd Chance Housing to (check each that applies):</b></p>
${CK(["<b>Collect</b> documents and facts about the person who died, the property, and my family.", "<b>Store</b> them in 2nd Chance's secure system and files for: ______________ (period to be set by the organization).", "<b>Share</b> them with this lawyer or organization: ______________________________.", "<b>Share</b> them with a title company, only if I say so later in writing.", "Contact me by (check): &#9744; email &#9744; phone &#9744; text &#9744; in person. Best times: __________ . Do not contact me: __________ ."])}
<p><b>Who may speak for our family:</b> ______________________________ &nbsp; <b>Who should not be told yet:</b> ______________________________</p>
<p><b>My rights.</b> I may say no, ask 2nd Chance to stop, or ask 2nd Chance to delete what it holds, at any time, by contacting ______________________ . Declining changes nothing about how I am treated.</p>
<div class="sig"><div>Signature (family contact)</div><div>Printed name, relationship, date</div><div>Researcher (name, date)</div><div>Supervisor review (name, date)</div></div>
<p class="small">Questions for counsel on this form: retention period; whether Illinois privacy law adds requirements; whether a witness or notary is wise; wording for minors and incapacitated persons; sharing with a title company.</p>
<h2>Part 2: Intake interview</h2>
<table><tr><th style="width:36%">Item</th><th>Answer and source (who said it, or which record)</th></tr>
${[["Person who died: full legal name; other names", ""], ["Date and place of death; source", ""], ["County where she lived at death", ""], ["Marital status; every spouse or partner, ever", ""], ["Every child (adopted, earlier relationships, deceased), with dates of any death", ""], ["Property address; every PIN", ""], ["Who lives there; rent; tenants; deposits; who collects rent now", ""], ["Insurance (company, renewal, vacant or occupied)", ""], ["Taxes owed; mortgage or HELOC; liens known", ""], ["Will, trust or TODI? Who holds the original?", ""], ["Existing estate case? Lawyer already acting?", ""], ["Accounts, vehicles, other assets (last four digits only)", ""], ["Funeral costs; who paid; other debts", ""], ["Medicaid received?", ""], ["Urgent issues (tax sale, foreclosure, insurance, danger, lawsuit)", ""], ["Their goal (their words)", ""]].map(([a]) => `<tr><td>${a}</td><td class="blank"></td></tr>`).join("")}</table>
<p class="small">Collect only what the family agrees to share and the case needs. Anything said is a lead until you see the record.</p>`);

  // ---- 3. evidence matrix ------------------------------------------------------------------------------------------------
  pages["evidence-matrix.html"] = wrap("Document and evidence collection matrix", "What to collect, from where, who may request it, and what makes it complete, plus the route-specific document matrix.",
    `<div class="warn"><b>Fees, processing times and eligibility change.</b> This matrix states none. Read each office's page on the day you order and write the date you checked. A column marked &ldquo;verify&rdquo; is blank on purpose.</div>
<h2>A. Evidence to collect</h2>
${T(["Item", "Purpose", "Best source", "Who may request / authorization", "Fee / time (verify, date)", "Original / copy / certified?", "When", "Complete when"], [
    ["Death certificate", "Date, place, residence, marital status, informant", "Cook County Clerk, Vital Records (page opened " + CHECKED + ")", "Verify", "Verify", "<b>Certified</b>; several copies", "First", "Fields typed and compared to the scan by a second person"],
    ["Recorded deed(s), every PIN", "Last recorded owner; legal description; how held", "Clerk's Recordings, by PIN", "Public record", "Verify", "Certified if counsel asks", "First", "Copy saved per PIN with search date and index-through date"],
    ["Later recorded documents", "TODI, trust, mortgage, release, lien, later deed", "Clerk's Recordings", "Public record", "Verify", "Copy; certified if counsel asks", "First", "Each listed with number, type, date, parties; or &ldquo;none found&rdquo; per PIN"],
    ["Will, trust, TODI", "May change the route", "Family; holder; Clerk if filed", "The holder", "n/a", "<b>Original matters</b>", "Early", "Original located; holder and place written"],
    ["Marriage, birth, name records", "Relationships; name differences", "Vital Records; courts", "Verify; rules differ", "Verify", "Certified where needed", "When a relationship or name is questioned", "Record matches the heirs card or the question is logged"],
    ["Tax bills, mortgage statement, payoff", "Debts, liens, urgency", "Treasurer by PIN; lender", "Lender may need written permission", "Verify", "Copy", "Before first appointment", "Each PIN has a bill or &ldquo;none&rdquo;; lender statement dated"],
    ["Leases, rent roll, deposits, insurance declarations", "Rent, bond estimate, risk", "Family; tenants (with permission); insurer", "Family", "n/a", "Copy", "Before first appointment", "Annual rent ties to leases"],
    ["Account statements; funeral bill; creditor mail", "Assets and debts", "Family; mail she received", "Family (not her logins)", "n/a", "Copy; last four digits only", "Before first appointment", "Each creditor listed or &ldquo;none known&rdquo; after a search"],
    ["Medicaid inquiry", "Possible estate-recovery claim", "Illinois HFS (page opened " + CHECKED + ")", "Counsel / representative", "Verify", "Letter", "After appointment, as counsel confirms", "Inquiry date and reply recorded"],
    ["Credit reports", "Find creditors", "Each bureau, separately", "Per each bureau's current page", "Verify", "Request letter", "<b>After letters</b> (counsel confirms)", "Each bureau tracked; TransUnion not verified here"]]).replace(/<table>/, '<table style="font-size:.76rem">')}
<h2>B. Route-specific documents (counsel selects the route; forms per the Cook County Probate Division list, read ${CHECKED})</h2>
${T(["Document", "Purpose", "Required?", "Prepared / signed by", "Public or private", "Complete when"], [
    ["Cover sheet CCP 0199 (category)", "Type of case", "If administration, heirship-only or summary", "You prepare; counsel files", "Proposed public filing", "Category agreed with counsel"],
    ["Petition: letters of administration with Exhibit A (CCP 0302); with a will CCP 0315 / 0316", "Open the estate", "Administration", "Counsel reviews; petitioner signs", "Proposed public filing", "Every fact matches evidence; all heirs with addresses"],
    ["Copy of will CCP 0317 and the <b>original will</b>", "Prove the will", "Will cases (755 ILCS 5/6-1; Cook Rule 12.3(a))", "Holder files original with Clerk", "Public once filed", "Original filed at least 3 court days before the hearing"],
    ["Heirship affidavit (notarized)", "Swear family facts", "Administration (no will), heirship-only, summary, title-company routes", "You draft facts; affiant swears; counsel reviews", "Proposed public filing", "Matches the tree; notarized; signed scan"],
    ["Proposed order declaring heirship CCP 0305", "Judge may sign", "As counsel decides", "You draft; <b>judge signs</b>", "Proposed", "Names and shares match the petition"],
    ["Proposed order appointing representative CCP 0314 (or CCP 0319 with will)", "Judge may sign", "Administration", "You draft; judge signs", "Proposed", "Representative and bond match"],
    ["Oath and surety bond CCP 0312 (CCP 0313 no surety)", "Representative's oath and bond", "Administration", "Surety agent; representative; counsel", "Proposed public filing", "Amount approved by surety; dated signatures"],
    ["Waiver of notice CCP 0303", "Person agrees to waive notice", "Optional; <b>after filing only</b>", "Each person signs voluntarily", "Public once filed", "Signed scan dated after filing"],
    ["Notice by certified mail (CCP 1004); proof", "Notify interested people", "As the court directs", "Counsel directs; sent after filing", "Proof is public", "Tracking, date, receipt for each"],
    ["Fee waiver application", "Waive fees", "Only if used; counsel decides", "Petitioner", "Public", "Never presumed"],
    ["Summary administration: consents, refunding bonds, publication proof", "Meet 755 ILCS 5/9-8", "Only if every condition is met (gross estate $100,000 or less)", "Counsel drafts; each heir and distributee signs", "Public once filed", "Every heir's written consent; every bond"],
    ["Title-company requirements; conveyances; indemnities", "Title route", "Only if the title company agrees in writing", "Title company; heirs", "Private until recorded", "Written requirements saved"],
    ["Evidence (folder C): certificates, deeds, tax bills, statements, ID, leases, bills", "Support every fact", "Supporting", "You gather", "<b>Private</b>", "Indexed with source and date"]]).replace(/<table>/, '<table style="font-size:.76rem">')}
<p class="small">Source for form numbers and titles: the system's document list (read in the page's code ${CHECKED}) and the Cook County Probate Division forms page. Forms are revised; open each from the court's site before use.</p>`);

  // ---- 4. handoff -------------------------------------------------------------------------------------------------------
  pages["handoff.html"] = wrap("Lawyer handoff: checklist, templates and sample cover memo", "A second-person review sheet, file set, evidence index, originals register, unresolved-issues sheet, response tracker and a sample cover memo.",
    `<div class="warn"><b>An internal status checkbox is not proof of attorney approval.</b> Keep counsel's written message in the file. The package is a draft for counsel's review, corrections, approval and filing. Nothing here is filed by us.</div>
<h2>1. Second-person review sheet</h2>
<p class="small">Reviewer is not the preparer. Compare, do not just count.</p>
${T(["Check", "Compare", "OK?", "Finding / who fixes / re-checked"], [["Identity", "Decedent's name on deed, certificate, petition, affidavit; differences explained"], ["Dates", "Birth, death, certificate issue, search and index dates"], ["Every PIN", "Property card, search log, petition, deed, tax bills"], ["Legal description", "Recorded deed vs every document that copies it, word for word"], ["Family and shares", "Heirs card, tree, affidavit, petition exhibit, proposed order; shares add to 1"], ["Route and amounts", "Route box, document list, value, income, bond estimate"], ["Signatures, notary, certification", "Each signed scan; notary block; certified copies truly certified"], ["Privacy", "No full SSN or account numbers; private evidence marked private"], ["Version", "Newest versions; superseded marked; names match the file set"]].map((r) => [...r, "", ""]))}
<div class="sig"><div>Preparer (name, date)</div><div>Reviewer (name, date)</div></div>
<h2>2. Numbered file set (the order counsel reads)</h2>
${T(["#", "File name", "What it is", "Status (draft / ready / signed)", "Version"], [["01", "01_cover-memo.pdf", "One-page cover memo", "", ""], ["02", "02_unresolved-issues.pdf", "Unresolved-issues sheet", "", ""], ["03", "03_cover-sheet-CCP0199-DRAFT.pdf", "Cover sheet draft", "", ""], ["04", "04_petition-DRAFT.pdf", "Petition draft with Exhibit A", "", ""], ["05", "05_heirship-affidavit-DRAFT.pdf", "Affidavit draft (not sworn)", "", ""], ["06", "06_proposed-orders.pdf", "Proposed orders (judge signs)", "", ""], ["C01+", "C01_death-certificate.pdf …", "Private evidence, one file per record", "", ""]])}
<h2>3. Evidence index</h2>
${T(["Ref", "What it is", "What it proves", "Source", "Date obtained", "File name", "Checked by"], blankRows(6, 7))}
<h2>4. Originals register</h2>
${T(["Original", "Who holds it", "Where kept", "Date received / handed over", "Receipt signed by"], blankRows(4, 5))}
<h2>5. Unresolved-issues sheet</h2>
${T(["#", "Question", "Why it matters", "Who can answer", "Tried so far", "Status"], blankRows(5, 6))}
<h2>6. Counsel response tracker</h2>
${T(["Date", "Event (sent / accepted / corrections / revised / approved)", "Counsel (name)", "In their own words (or where the message is saved)", "Version"], blankRows(5, 5))}
<h2>7. Sample cover memo (fictional)</h2>
<div style="border:1px solid #17231C; padding:10px 14px; font-size:.92rem">
<p><b>To:</b> [Counsel] &nbsp; <b>From:</b> [Researcher], 2nd Chance Housing &nbsp; <b>Date:</b> [date]<br><b>Re:</b> Marsh, 4410 S Example Ave, Chicago (FICTIONAL): package for your review</p>
<p><b>1. What this is.</b> A package prepared with the family's written permission, for your review. Nothing has been filed or sent to any court. We are not a law firm and give no legal advice.</p>
<p><b>2. What is unresolved (please read first).</b> Q1: Naomi Marsh's address is unknown. Q2: a 2023 church certificate names a possible spouse; the death certificate says widowed. Q3: deed says &ldquo;Delia A. Marsh,&rdquo; certificate says &ldquo;Delia Ann Marsh.&rdquo; Q4: a 2009 mortgage has no recorded release. Q5: PIN 20-00-000-002-0000 is deeded jointly with Robert Marsh (d. 2011). The heirs list is <b>not</b> marked complete.</p>
<p><b>3. What we found.</b> Delia Ann Marsh died 03/14/2026 (certified certificate, C01). Recorder search 04/05/2026 for both PINs (index through 04/03/2026), results in C02 and C03.</p>
<p><b>4. What we ask.</b> Please confirm the route and tell us which items to correct or add. Known dates: none.</p>
<p><b>5. Where things are.</b> Files 01 to 06 and C01 to C12; originals register attached. All drafts are marked DRAFT.</p></div>`, { fiction: true });

  // ---- 5. practice case --------------------------------------------------------------------------------------------------
  const ans = [
    ["1. Missing address (Naomi)", "Leave her address blank; note &ldquo;whereabouts unknown, asked Marcus and Renee on [date]&rdquo;; Q1 on the register; heirs list not ticked complete.", "Entering Marcus's address; ticking the list complete; searching by unauthorized means."],
    ["2. Terrence refuses to waive notice", "Record his refusal and the date, only that; do not pressure or revisit; waivers are after filing anyway; counsel chooses another way to give notice.", "Sending a waiver before filing; telling siblings what he said without his permission; arguing."],
    ["3. Name discrepancy", "Owner of record stays &ldquo;Delia A. Marsh&rdquo; (deed); certificate name in the certificate field; name check lists records (1998 marriage license, ID); heir confirms the name to use; Q3.", "Changing the deed name; concluding they are the same person."],
    ["4. A later death (Renee d. 05/20/2026)", "Obtain her certified death certificate; record that she survived her mother; record who her heirs or representative are; she cannot sign a waiver; heirs list not complete.", "Deciding who receives her share; dropping her from the list."],
    ["5. Possible surviving spouse", "Record both documents with sources; Q2; do not tick &ldquo;no surviving spouse&rdquo; in plan facts; counsel decides.", "Concluding she did or did not remarry; discarding the church certificate."],
    ["6. A lien (2009 mortgage)", "Add to documents found: number, type, date, parties, &ldquo;no release found&rdquo;; written payoff or release request with the family's permission; Q4.", "Writing &ldquo;paid&rdquo;; telling the family nothing is owed."],
    ["7. Different title interests", "PIN 002 title examined as survivorship (joint tenancy) <u>only as the records show</u>; Robert's certified death certificate; the plan fact &ldquo;title held by her alone&rdquo; stays unticked; question for counsel.", "Writing &ldquo;she owned it alone&rdquo;; choosing a route."]];
  pages["practice-case.html"] = wrap("The fictional practice case and answer guide", "The master fact sheet for the practice family, the seven branches, exercises and an answer guide.",
    `<h2>Master fact sheet (one source of truth)</h2>
${T(["Fact", "Value"], [["Person who died", `${FACTS.decedent} (deed: &ldquo;${FACTS.deedName}&rdquo;), born ${FACTS.born}, died ${FACTS.died}, ${FACTS.diedWhere}`], ["Residence at death", FACTS.address + " (Cook County)"], ["Marital status per certificate", FACTS.marital], ["Death certificate", `No. ${FACTS.certNo}, issued ${FACTS.certIssued}; ${FACTS.copies}; informant Marcus Marsh (son)`], ["PIN 001", `${FACTS.pin1} (4410 S Example Ave): ${FACTS.deed1}; held alone`], ["PIN 002", `${FACTS.pin2}: see branch 7`], ["Search", `Recorder search ${FACTS.searched}; the Clerk's index ran through ${FACTS.indexThrough}`], ["Value; income", `Real estate about ${FACTS.realValue} (two comparable sales and a broker opinion, as of 04/01/2026); personal estate ${FACTS.personal}; annual rent ${FACTS.income} (${FACTS.incomeCalc})`], ["Tenants", "Unit 1: J. Doe, $900 a month, no arrears, deposit $900 held by Delia. Unit 2: R. Roe, $900 a month."], ["Dates used in examples", `Consultation ${FACTS.consult}; hearing date example ${FACTS.hearing}`]])}
<h3>The four children</h3>
${T(["Name", "Relationship", "Address", "Phone", "Notes"], FACTS.kids.map((k) => [k[0], k[1], k[2], k[3], k[4]]))}
<p class="small">All names, numbers and addresses are invented. Document numbers like 0000000000 are placeholders.</p>
<h2>Seven branches</h2>
${T(["#", "Branch", "What happens"], BRANCHES)}
<h2>Exercises</h2>
<ol><li>Fill in a field checklist for the practice case up to the first appointment. Mark every item you cannot complete, and why.</li>
<li>For each branch you choose, write the system entries and the register question. Do not conclude any legal result.</li>
<li>Compile a numbered file set, an evidence index and an originals register using only records the fact sheet says exist.</li>
<li>Run the cross-document comparison on this fact sheet. Find any place two statements here disagree (there should be none; say so with evidence).</li></ol>
<h2 id="answers">Answer guide (for supervisors)</h2>
${T(["Branch", "Good answer", "Common mistakes"], ans)}
<h3>Final assignment rubric</h3>
${CK(["Every fact has a source; nothing is guessed.", "Every unresolved question is on the register with who can answer and how to find out.", "No legal conclusions: no route chosen, no heirs or shares declared, no one told what a notice means.", "No waiver sent before filing; no original moved without a receipt.", "The cover memo lists what is unresolved <b>first</b> and says the package is for counsel's review.", "The ready/not-ready paragraph is honest: this case is <b>not</b> ready as complete until Q1 to Q5 are answered by evidence or counsel."])}`, { fiction: true });

  // ---- 6. sources --------------------------------------------------------------------------------------------------------
  const src = [
    ["755 ILCS 5/2-1 rules of descent", "Read in full", "ilga.gov", "Who inherits depends on spouse and descendants, per stirpes; why Module F collects every spouse and child."],
    ["755 ILCS 5/5-3 heirship, how declared and proved", "Read in full", "ilga.gov", "Affidavit before a notary, or evidence; order is prima facie evidence."],
    ["755 ILCS 5/6-1 duty to file the will", "Read in full", "ilga.gov", "Person holding a will must file it with the clerk immediately upon the death (the 30 days in the section is for the felony of secreting it, not a filing deadline)."],
    ["755 ILCS 5/9-8 summary administration", "Read in full", "ilga.gov", "$100,000 gross; claimants listed; no taxes; awards; written consent of all heirs; refunding bond; publication once a week for 3 weeks, first at least 30 days before the hearing."],
    ["755 ILCS 5/14-1 inventory", "Read in full", "ilga.gov", "Verified inventory within 60 days after letters issue."],
    ["755 ILCS 5/18-3 notice to creditors", "Read in full", "ilga.gov", "Publish once a week for 3 successive weeks and mail to known creditors; claims date at least 6 months from first publication or 3 months from mailing, whichever is later."],
    ["755 ILCS 5/18-12 limits on claims", "Read (first part)", "ilga.gov", "Claims barred after notice; outer limit 2 years after death unless sooner barred."],
    ["755 ILCS 5/25-1 small estate affidavit", "Read (a-5 and form)", "ilga.gov", "Personal property only, no letters outstanding, limits as stated; not a way to convey real estate."],
    ["755 ILCS 5/28-2 independent administration", "Read (first section)", "ilga.gov", "Court grants independent administration unless a will forbids it or supervision is required; a minor or person with a disability can lead the court to require supervision."],
    ["755 ILCS 5/28-10 distribution; 28-11 closing", "Read (28-10 in full; 28-11 first part)", "ilga.gov", "Independent representative records and delivers an instrument releasing the estate's real-estate interest; closing requires accounting and a verified report."],
    ["755 ILCS 27/75 TODI notice of death affidavit", "Read in full", "ilga.gov", "Optional; filing it is not a condition of the transfer."],
    ["Cook County Circuit Court Rule 12 (12.2 heirship; 12.3 will filing)", "Page opened; 12.2 and 12.3 read", "cookcountycourtil.gov", "Heirship petition content; will filed at least 3 court days before the hearing. 12.5 (bond) not re-read; the system describes it."],
    ["Cook County Clerk: Probate Division page", "Page opened", "cookcountyclerkofcourt.org", "Daley Center, Room 1202; 312-603-6441."],
    ["Cook County Clerk: Recordings search", "Page opened (200)", "crs.cookcountyclerkil.gov/Search", "Search by PIN."],
    ["Cook County Vital Records: death certificates", "Page opened (200); details not extracted", "cookcountyil.gov", "Eligibility, ID and fees <b>not stated</b> in this course."],
    ["Illinois HFS Medicaid Estate Recovery", "Page opened (200); specifics not extracted", "hfs.illinois.gov", "The protected amount stated on the system's page was not independently confirmed."],
    ["Equifax: report of a deceased person", "Page read", "equifax.com", "Executor requests by mail; death certificate or letters testamentary per its page."],
    ["Experian: report of a deceased person", "Page read", "experian.com", "Executor, with proof of authority and a death certificate, per its page."],
    ["TransUnion: managing credit for a loved one", "<b>Blocked (403)</b>", "transunion.com", "Not verified. Check the bureau directly."],
    ["Illinois Supreme Court Rule 138 (personal identity information)", "Linked by the system; not re-read", "illinoiscourts.gov", "Why the course says to redact; counsel confirms."],
    ["705 ILCS 205/1 unauthorized practice", "Linked by the system; not re-read", "ilga.gov", "Why researchers never give legal advice; counsel to confirm the scope of the researcher role."],
    ["Case page source (site/staff/deeds/transfer/index.html)", "Read in full 10/29/2026; last commit 10/28/2026 (c0aa77e)", "this repository", "Every system claim in Module H."],
    ["Review package (Claude outputs/review-package)", "Read README; identical to the repository page", "this repository", "Known limits and open reviews."]];
  pages["sources.html"] = wrap("Dated source register", "Every legal and procedural source used in the researcher course, with what was checked and when.",
    `<div class="warn">Checked <b>${CHECKED}</b>. &ldquo;Read in full&rdquo; means the section text was read on that date. &ldquo;Page opened&rdquo; means the page loaded but the specific rule was not extracted. Laws change: look up each rule on the day you rely on it. No fee, processing time or deadline in this course was invented: where one is not shown, it was not confirmed.</div>
${T(["Source", "How checked", "Where", "Used for"], src)}`);

  // ---- 7. inventory + open items ------------------------------------------------------------------------------------------
  pages["inventory.html"] = wrap("Source-of-truth inventory", "What the preparation system does today, what is described but not verified, what is manual, known defects, and what only counsel decides.",
    `<div class="warn">Compiled ${CHECKED} by reading the page's source (<code>site/staff/deeds/transfer/index.html</code>, last changed 10/28/2026) and the 10/28/2026 review package. The page was <b>not</b> clicked through live (it needs a staff sign-in). The live site could differ from this copy.</div>
<h2>1. In the system (read in the page's code)</h2>
<ul><li>Case list, new case (kind: owner died, heir needs the deed), delete; per-case access list; save, saved, unsaved, error and conflict bar; version checks that refuse a stale save; History (who changed what).</li>
<li>Property card (title, address, PINs, county, legal description, owner of record, decedent, date of death); Title search at the recorder; Route evaluation with a title answer per PIN and a contradiction check.</li>
<li>Death certificate: <b>upload</b> and typed fields (name, birth, place of death, county, address, marital status, spouse, number, issue date, informant, copies, last four of SSN); name-difference warning; county warning if not Cook.</li>
<li>Heirs with a row each (relationship, living, address, adult, survived, agrees, can sign, notice status, tracking, mailing receipt, signed return receipt), heirs list marked complete, draft affidavit, petition worksheet with Exhibit A, certified-mail envelopes.</li>
<li>Plan facts, name check, search log, administrator eligibility, assets and bond estimate, creditors, HFS box, documents tracker (folders A, B and C; status Not started to Filed; scans; where the original is kept; a replaced scan is kept and flagged for re-check).</li>
<li>Steps with status and target dates, a preparation calendar, consultation log (Scheduled, Accepted, Needs changes first, Declined, Go to next), four readiness lists, counsel packet print, daily deadline reminder emails (per the review package).</li></ul>
<h2>2. Described elsewhere but <u>not</u> in the system</h2>
<ul><li><b>Automatic reading of the death certificate.</b> The page does not read it. The instructor walkthrough at /probate-help/walkthrough/ says it does (&ldquo;Upload the certificate, let the page read it&rdquo;). That slide, and its audio, are inaccurate.</li>
<li>Filling the official court forms, or exporting an approved-documents bundle with a manifest (open items V16 and R12 in the review package).</li>
<li>Redacted copies of uploaded scans and retention rules; before and after values in the history (V20); a complete model of successive deaths and deeper family trees; per-route filing steps beyond checklists for heirship-only, summary administration and the title-company route.</li></ul>
<h2>3. Manual tasks (outside the system)</h2>
<ul><li>Finding leads, consent, interviews, searching the recorder and the court's records, ordering records, reading and typing the certificate, second-person review, the evidence index, originals register, unresolved-issues sheet, cover memo, the lead log, and tracking counsel's approval.</li></ul>
<h2>4. Known defects and unsupported scenarios</h2>
<ul><li>Tested with a stub page and stub database, not a real browser or staging database (review package, &ldquo;Known limits&rdquo;).</li><li>Cook County only. The page warns if she lived elsewhere.</li><li>Built around the four-child intestate case; fractional interests are supported only as share text and a check that shares add to 1.</li><li>Bond rule: Cook Rule 12.5(a) is described, an estimate only; the personal-estate bond (Probate Act) is not computed.</li><li>The page's statements about the filing fee, transfer-tax exemption and Medicaid protected amount were <b>not</b> independently confirmed for this course.</li></ul>
<h2>5. Decisions reserved</h2>
<ul><li><b>Counsel:</b> the route; who the legal heirs are and their shares; who may serve; petition contents; notice method; whether a deed is proper; fees and scope.</li><li><b>The court:</b> declaring heirship, appointing a representative, independent or supervised administration, bond amount.</li><li><b>The title company:</b> whether it insures without letters, and on what terms.</li></ul>`);

  pages["open-items.html"] = wrap("Unverified features, unresolved legal questions and missing inputs", "What this course could not confirm, what counsel must answer, and what is missing.",
    `<h2>A. Unverified features and facts</h2>
${T(["Item", "What is unverified", "What the course does instead"], [
      ["The live case page", "Whether it is identical to the repository copy (needs a staff sign-in)", "Screens are labelled drawings from the code; a supervisor confirms any unusual screen"],
      ["Real screenshots", "None taken", "Drawings with fictional data; ask a signed-in staff member to supply real screenshots"],
      ["Filing fee, death certificate fee, processing times", "Not stated anywhere in the course", "&ldquo;Verify on the day&rdquo; columns"],
      ["Medicaid protected amount (page says $25,000 for deaths on or after 7/1/2022)", "Not independently confirmed", "Marked not verified"],
      ["Transfer-tax exemption statements on the page", "Not independently confirmed", "Marked not verified"],
      ["Phone numbers for Chicago Volunteer Legal Services (312-332-1624) and the Probate Division staff attorney (312-603-7545)", "Taken from the system and the earlier help deck; only 312-603-6441 (Probate Division) was confirmed on the Clerk's site", "Course uses 312-603-6441 and says to confirm the others"],
      ["TransUnion's requirements", "Page blocked to our request", "Check directly"],
      ["Whether Clerk probate cases can be searched by name online", "Not confirmed", "Ask the Probate Division; keep a log of every spelling tried"],
      ["Cook Rule 12.5 (bond)", "Not re-read for this course", "Described as an estimate; the system's own text is the source"],
      ["The seven-branch practice case on the live system", "The branches were designed for this course, not loaded into the live page", "Used as a paper exercise"]])}
<h2>B. Unresolved legal and policy questions for counsel and leadership</h2>
<ol><li>Is the researcher role (finding families, collecting records, typing facts, printing draft affidavits and worksheets) within what a non-lawyer organization may do? (705 ILCS 205/1; the system already says it is a checklist.)</li>
<li>Approve, correct or replace the draft consent form: retention period, sharing with counsel and title companies, minors and persons with a disability, a witness or notary, applicable Illinois privacy rules.</li>
<li>Is door-to-door and obituary-based outreach to bereaved families acceptable, and are there local solicitation or disclosure rules?</li>
<li>2nd Chance's rule is email for ordinary communication and mail only for legal notices. Are printed cards, door notes and leave-behind sheets allowed for outreach? (Leadership decision; the course assumes the organization issues an approved card.)</li>
<li>Representative-capacity acknowledgment wording on the deed (open in the review package).</li>
<li>Exact wording of &ldquo;do not sign&rdquo; guidance and the plan facts, and whether any should be softened or expanded.</li>
<li>Who the researchers' supervisor and escalation contact are, and the organization's emergency steps for a person in crisis.</li></ol>
<h2>C. Missing inputs</h2>
<ul><li>Approved consent form, organization card or leave-behind (if allowed), ID badge policy.</li><li>Names and phone numbers of the supervisor and the counsel who receive packages.</li><li>Staff accounts and access-list setup for each researcher (the page is staff only, with two-step sign-in).</li><li>A signed-in review of the live case page to confirm the screens.</li><li>Narration audio: the deck uses the browser's own voice unless clips are recorded from <code>docs/course-narration.txt</code>.</li><li>A real-case pilot with one researcher and a supervisor, to test pacing.</li></ul>`);

  // ---- 8. transcript ------------------------------------------------------------------------------------------------------
  pages["transcript.html"] = wrap("Course transcript", "The full narration of the researcher course, slide by slide, also used for captions.",
    slides.map((s, i) => `<h3 id="s${i + 1}">${i + 1}. ${esc((s.h || "").replace(/<[^>]*>/g, ""))}</h3><p>${esc(s.say)}</p><p class="small"><a href="/probate-help/course/#${i + 1}">Open slide ${i + 1}</a></p>`).join(""));

  // ---- 9. index ------------------------------------------------------------------------------------------------------------
  const L = [["field-checklist.html", "Researcher field checklist", "One sheet from the first lead to the handoff"], ["intake-consent.html", "Family intake and consent", "Interview form and a draft consent for review"], ["evidence-matrix.html", "Document and evidence matrix", "What to collect, and the route-specific documents"], ["handoff.html", "Lawyer handoff", "Review sheet, file set, evidence index, originals register, unresolved issues, tracker, sample cover memo"], ["practice-case.html", "Practice case and answer guide", "The master fact sheet, seven branches, exercises and answers"], ["sources.html", "Dated source register", "Every legal source and when it was checked"], ["inventory.html", "Source-of-truth inventory", "What is in the system, what is manual, known defects, decisions reserved"], ["open-items.html", "Unverified items and open questions", "What we could not confirm, questions for counsel, missing inputs"], ["transcript.html", "Course transcript", "All narration, slide by slide"]];
  pages["index.html"] = wrap("Researcher course handouts", "Printable handouts for the 2nd Chance probate researcher course.",
    `<p>Open the <a href="/probate-help/course/"><b>course deck</b></a> first. These handouts print cleanly (use your browser's Print).</p>
<ul>${L.map(([f, t, d]) => `<li><a href="/probate-help/course/materials/${f}"><b>${t}</b></a><br><span class="small">${d}</span></li>`).join("")}</ul>
<div class="warn">Draft for organizational and counsel review. 2nd Chance Housing is not a law firm and none of this is legal advice.</div>`);

  return pages;
};
