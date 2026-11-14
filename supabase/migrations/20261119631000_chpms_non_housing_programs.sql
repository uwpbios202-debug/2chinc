-- The Human Mirror Phase N, handoff step 20, TN.3 part B: non-housing Milwaukee programs in the resource directory (ID, health, food, phone
-- and internet, work, education). Researched 11/13/2026 by Claude from each program's OWN official page, fetched that day; nothing estimated.
-- Rules followed (the directory's own, About the data): every fact cites its source (chpms_sources TN3-S01..S09); amounts appear only
-- where the page publishes one; a fact the page does not state is written "Not stated on the official page"; "Verified – Current" only
-- where the official page was fetched and states it, otherwise "Verified – Limited" with the reason in the notes.
-- Legal help was already in the directory (Legal Action of Wisconsin, Legal Aid Society of Milwaukee, Centro Legal, Marquette Volunteer
-- Legal Clinic) and its programs already carry the life area "Identity, documentation and legal standing", so none is added.
-- Rows are office-added (is_local, import_version 'tn3-11/13'), so no workbook import touches them, and Find help > Show can list them.
-- Each program gets office life-area links (mirror.resource_categories, source 'office'), so the Mirror's "Help I could get" (T7.2) and
-- Find help's Life area filter (part A) find them. Call before you refer, as always.

insert into chpms_sources (source_id, title, url, publisher, source_type, date_accessed) values
  ('TN3-S01', 'Obtaining an identification (ID) card', 'https://wisconsindot.gov/Pages/dmv/license-drvs/how-to-apply/id-card.aspx', 'Wisconsin Department of Transportation (DMV)', 'Official state', date '2026-11-13'),
  ('TN3-S02', 'Vital Records: Requesting a Vital Record', 'https://www.dhs.wisconsin.gov/vitalrecords/record.htm', 'Wisconsin Department of Health Services', 'Official state', date '2026-11-13'),
  ('TN3-S03', 'FoodShare Wisconsin', 'https://www.dhs.wisconsin.gov/foodshare/index.htm', 'Wisconsin Department of Health Services', 'Official state', date '2026-11-13'),
  ('TN3-S04', 'Emergency Food', 'https://www.hungertaskforce.org/get-help/emergency-food/', 'Hunger Task Force', 'Official provider', date '2026-11-13'),
  ('TN3-S05', 'Progressive Community Health Centers (home page)', 'https://www.progressivechc.org/', 'Progressive Community Health Centers', 'Official provider', date '2026-11-13'),
  ('TN3-S06', 'Lifeline Support', 'https://www.lifelinesupport.org/', 'Universal Service Administrative Company (Lifeline, FCC program)', 'Official federal', date '2026-11-13'),
  ('TN3-S07', 'Milwaukee Public Library: home page and Computers & Internet', 'https://www.mpl.org/library/computers_internet/', 'Milwaukee Public Library', 'Official government', date '2026-11-13'),
  ('TN3-S08', 'Employ Milwaukee (home page)', 'https://www.employmilwaukee.org/', 'Employ Milwaukee', 'Official provider', date '2026-11-13'),
  ('TN3-S09', 'Literacy Services of Wisconsin (home page)', 'https://www.literacyservices.org/', 'Literacy Services of Wisconsin', 'Official provider', date '2026-11-13'),
  ('TN3-S10', 'Job Center of Wisconsin (home page)', 'https://jobcenterofwisconsin.com/', 'Job Center of Wisconsin', 'Official state', date '2026-11-13')
on conflict (source_id) do nothing;

insert into chpms_orgs (org_id, legal_name, org_type, website, physical_address, main_phone, service_area, accepts_outside_referrals, verification_status,
  verification_notes, source_ids, primary_source_url, provenance, date_accessed, is_local, import_version) values
  ('TN3-ORG01', 'Wisconsin Department of Transportation – Division of Motor Vehicles (DMV)', 'Government (state)', 'https://wisconsindot.gov/Pages/dmv/default.aspx',
   'DMV customer service centers (locations on the DMV site)', '(844) 588-1069 (voter ID hotline)', 'Wisconsin', 'Not stated', 'Verified – Current',
   'Official page fetched 11/13/2026. It gives no general DMV phone number; the number listed is the voter ID hotline.', 'TN3-S01', 'https://wisconsindot.gov/Pages/dmv/license-drvs/how-to-apply/id-card.aspx',
   'Original research (TN.3, 11/13/2026)', date '2026-11-13', true, 'tn3-11/13'),
  ('TN3-ORG02', 'Hunger Task Force', 'Nonprofit', 'https://www.hungertaskforce.org/', '5000 W. Electric Avenue, West Milwaukee, WI 53219', '(414) 777-0483',
   'Milwaukee County', 'Not stated', 'Verified – Current', 'Official page fetched 11/13/2026. Pantry days and times change; the site map and 2-1-1 have them.', 'TN3-S04',
   'https://www.hungertaskforce.org/get-help/emergency-food/', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', true, 'tn3-11/13'),
  ('TN3-ORG03', 'Progressive Community Health Centers', 'FQHC', 'https://www.progressivechc.org/',
   'Lisbon Avenue Health Center, 3522 W Lisbon Avenue, Milwaukee, WI 53208; Hillside Family Health Center, 1452 N 7th Street, Milwaukee, WI 53205; 12th Street Urgent Care, 945 N 12th Street, Milwaukee, WI 53233',
   '(414) 935-8000', 'Milwaukee (patients)', 'Not stated', 'Verified – Current', 'Official page fetched 11/13/2026. Org type FQHC is from directories, not the page itself.', 'TN3-S05',
   'https://www.progressivechc.org/', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', true, 'tn3-11/13'),
  ('TN3-ORG04', 'Lifeline (federal phone and internet discount, run by USAC for the FCC)', 'Government (federal program)', 'https://www.lifelinesupport.org/',
   null, '(800) 234-9473 (application help, 7 days, 9 a.m. to 9 p.m. ET)', 'United States', 'Not stated', 'Verified – Current',
   'Official page fetched 11/13/2026. Applications go through getinternet.gov/apply.', 'TN3-S06', 'https://www.lifelinesupport.org/', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', true, 'tn3-11/13'),
  ('TN3-ORG05', 'Milwaukee Public Library', 'Government (city)', 'https://www.mpl.org/', 'Central Library, 814 W. Wisconsin Avenue, Milwaukee, WI 53233', '(414) 286-3000',
   'City of Milwaukee', 'Not stated', 'Verified – Current', 'Official pages fetched 11/13/2026. Reference help (414) 286-3011, text (414) 895-6663.', 'TN3-S07',
   'https://www.mpl.org/library/computers_internet/', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', true, 'tn3-11/13'),
  ('TN3-ORG06', 'Employ Milwaukee', 'Nonprofit (workforce board)', 'https://www.employmilwaukee.org/', '1322 North 8th Street, Milwaukee, WI 53205', '(414) 270-1700',
   'Milwaukee County', 'Not stated', 'Verified – Current', 'Official page fetched 11/13/2026. Wisconsin Relay 711. The page gives no step-by-step enrollment; call or use the contact page.', 'TN3-S08',
   'https://www.employmilwaukee.org/', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', true, 'tn3-11/13'),
  ('TN3-ORG07', 'Literacy Services of Wisconsin', 'Nonprofit', 'https://www.literacyservices.org/', '1737 N Palmer St., Milwaukee, WI 53212', '(414) 344-5878',
   'Milwaukee area', 'Not stated', 'Verified – Current', 'Official page fetched 11/13/2026. Older listings show 555 N. Plankinton Ave.; the official page lists only Palmer St.', 'TN3-S09',
   'https://www.literacyservices.org/', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', true, 'tn3-11/13'),
  ('TN3-ORG08', 'Job Center of Wisconsin', 'Government (state)', 'https://jobcenterofwisconsin.com/', 'Local job centers (locations on the site; open by appointment)', null,
   'Wisconsin', 'Not stated', 'Verified – Limited', 'Official page fetched 11/13/2026. It does not name its operator (it links to the Department of Workforce Development) and lists no phone number; cost not stated.', 'TN3-S10',
   'https://jobcenterofwisconsin.com/', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', true, 'tn3-11/13')
on conflict (org_id) do nothing;

insert into chpms_programs (program_id, org_id, program_name, assistance_form, max_assistance, current_status, eligibility_summary, how_to_apply, application_url,
  intake_phone, direct_financial, is_direct_financial, amount_publicly_disclosed, verification_status, source_ids, notes, provenance, date_accessed, self_referral,
  application_method, currently_open, is_local, import_version) values
  ('TN3-PRG01', 'TN3-ORG01', 'Wisconsin ID card (free ID card for voting)', 'Photo ID card', 'Not publicly disclosed (regular ID fee not stated on the page; the voting ID is free)',
   'Active (official page 11/13/2026)',
   'Original ID: proof of name and date of birth, proof of identity, proof of Wisconsin residency, proof of U.S. citizenship or legal status, and the Social Security number. A person eligible to vote can ask for the ID card free for voting; an ID Petition Process helps people who cannot provide all the proofs.',
   'In person at a DMV customer service center with form MV3004 (original card). Duplicates and renewals by mail (WisDOT, P.O. Box 7995, Madison, WI 53707-7995) or online.',
   'https://wisconsindot.gov/Pages/dmv/license-drvs/how-to-apply/id-card.aspx', '(844) 588-1069 (voter ID hotline)', 'No', false, 'No', 'Verified – Current', 'TN3-S01',
   'Free only when used for voting. Online payment services were shown as unavailable on 11/13/2026.', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes',
   'In person at the DMV; mail or online for duplicates and renewals', 'Yes (official page 11/13/2026)', true, 'tn3-11/13'),
  ('TN3-PRG02', 'ORG113', 'Certified Wisconsin birth certificate (State Vital Records Office)', 'Document copy', '$20 for the first copy, $3 for each additional copy of the same record (mail orders, as published)',
   'Active (official page 11/13/2026)',
   'State law limits who can get a certified copy (see page 2 of the application). Mail orders need a copy of one ID (state ID or driver license, U.S. government photo ID, passport, tribal or military ID) or two other papers (for example a bank statement, a signed lease, a health insurance card, a utility bill).',
   'Online or by phone through VitalChek (877-885-2981, extra VitalChek fee, about 5 business days); by mail to Wisconsin Vital Records Office, PO Box 309, Madison, WI 53701 (about 10 business days); or at a county Register of Deeds office.',
   'https://www.dhs.wisconsin.gov/vitalrecords/record.htm', '877-885-2981 (VitalChek)', 'No', false, 'Yes', 'Verified – Current', 'TN3-S02',
   'Milwaukee County Register of Deeds also issues them; its page could not be fetched 11/13/2026, so call before going.', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes',
   'Online, phone, mail or county Register of Deeds', 'Yes (official page 11/13/2026)', true, 'tn3-11/13'),
  ('TN3-PRG03', 'ORG113', 'FoodShare (SNAP food benefits)', 'Food benefits card', 'Not publicly disclosed (depends on household income and size)', 'Active (official page 11/13/2026)',
   'For people with limited money to buy food; eligibility is based on household income and size (monthly income limits on the DHS site).',
   'Apply and manage benefits only on ACCESS: https://access.wisconsin.gov', 'https://access.wisconsin.gov', '800-362-3002 (ForwardHealth Member Services)', 'No', false, 'No',
   'Verified – Current', 'TN3-S03;TN3-S04', 'Hunger Task Force also points people who lost work or hours to FoodShare on ACCESS.', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes',
   'Online (ACCESS)', 'Yes (official page 11/13/2026)', true, 'tn3-11/13'),
  ('TN3-PRG04', 'TN3-ORG02', 'Free food: pantry and meal-site map, Senior Stockbox', 'Food', 'N/A (free food)', 'Active (official page 11/13/2026)',
   'Food pantries and Hunger Task Force services are for people with little or no money for food. Senior Stockbox: a free box of healthy food for low-income adults age 60 or older who are income eligible.',
   'Find the nearest trusted site on the Hunger Task Force map, or dial 2-1-1 (414-773-0211 from a cell, toll-free 1-866-211-3380). Pantries do not deliver; a support person may pick up a Stockbox with a note.',
   'https://www.hungertaskforce.org/get-help/emergency-food/', '2-1-1 (414-773-0211)', 'No', false, 'N/A', 'Verified – Current', 'TN3-S04',
   'Children in the home can also get school meals.', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes', 'Walk in at a site, or call 2-1-1', 'Yes (official page 11/13/2026)', true, 'tn3-11/13'),
  ('TN3-PRG05', 'TN3-ORG03', 'Primary, dental and behavioral health care with the Sliding Fee Program', 'Health care', 'Not publicly disclosed', 'Active (official page 11/13/2026)',
   'New patients are welcome. For people without health insurance or worried about paying: the Sliding Fee Program; financial counselors help with insurance options and enrollment. Services: family and internal medicine, pediatrics, OB/GYN, podiatry, urgent care, pharmacy, dental care, integrated behavioral health, substance use disorder care.',
   'Call (414) 935-8000 to schedule at any of the three locations (Hillside also has online scheduling).', 'https://www.progressivechc.org/', '(414) 935-8000', 'No', false, 'No',
   'Verified – Current', 'TN3-S05', null, 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes', 'Phone', 'Yes (official page 11/13/2026)', true, 'tn3-11/13'),
  ('TN3-PRG06', 'TN3-ORG04', 'Lifeline phone or internet discount', 'Monthly bill discount', 'Up to $9.25 a month on phone, internet or bundled service (as published)', 'Active (official page 11/13/2026)',
   'Based on income or on taking part in a government assistance program (for example SNAP/FoodShare or Medicaid). The page does not state the income limit.',
   'Apply at https://getinternet.gov/apply; help with the application at (800) 234-9473.', 'https://getinternet.gov/apply', '(800) 234-9473', 'No', false, 'Yes',
   'Verified – Current', 'TN3-S06', 'A discount on the bill, not money paid to the person.', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes', 'Online', 'Yes (official page 11/13/2026)', true, 'tn3-11/13'),
  ('TN3-PRG07', 'TN3-ORG05', 'Computers, internet and Chromebooks at the library; free library card', 'Computer and internet access', 'N/A (printing 15 cents a page black and white, 50 cents color, as published)',
   'Active (official page 11/13/2026)',
   'A library card is free for City of Milwaukee residents. Public computers: standard session two hours a day; children''s and teen computers by age. Broadband internet at all locations.',
   'Visit any library; get a card in person or register online.', 'https://www.mpl.org/library/computers_internet/', '(414) 286-3000', 'No', false, 'N/A', 'Verified – Current', 'TN3-S07',
   'The pages do not describe Wi-Fi hotspot lending or computer classes; Chromebooks are listed under services.', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes', 'Walk in',
   'Yes (official page 11/13/2026)', true, 'tn3-11/13'),
  ('TN3-PRG08', 'TN3-ORG06', 'Job seeker services and training (adult, dislocated worker, reentry, youth and apprenticeship programs)', 'Training and job placement', 'Not publicly disclosed',
   'Active (official page 11/13/2026)',
   'Programs listed: Adult and Dislocated Worker, Reentry, Registered Apprenticeship, BankWork$ (free banking training), MediWork$, BioHealth Tech Hub, FORWD, MEND nursing, Serve MKE, Skills to Build; for young adults: Earn & Learn summer jobs, YouthBuild, WIOA Opportunity Youth, Youth Apprenticeship and more. Costs not stated except BankWork$ (free).',
   'Call (414) 270-1700 or use the contact page; job openings through Job Center of Wisconsin.', 'https://www.employmilwaukee.org/', '(414) 270-1700', 'No', false, 'No', 'Verified – Current', 'TN3-S08',
   null, 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes', 'Phone or contact form', 'Yes (official page 11/13/2026)', true, 'tn3-11/13'),
  ('TN3-PRG09', 'TN3-ORG07', 'Free adult education: reading, writing, math, English, GED and HSED', 'Classes and one-on-one tutoring', 'N/A (free)', 'Active (official page 11/13/2026)',
   'Free adult education programs: one-on-one reading, writing and math; English language learning; GED and HSED preparation. Free digital literacy classes for eligible FSET (FoodShare Employment and Training) participants.',
   'Sign up at https://www.literacyservices.org/enroll/ or call (414) 344-5878.', 'https://www.literacyservices.org/enroll/', '(414) 344-5878', 'No', false, 'N/A', 'Verified – Current', 'TN3-S09',
   'The online HSED program (summer and fall 2026) has no price stated on the page.', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes', 'Online sign-up or phone',
   'Yes (official page 11/13/2026)', true, 'tn3-11/13'),
  ('TN3-PRG10', 'TN3-ORG08', 'Job search, resume and job centers (Job Center of Wisconsin)', 'Job search tools', 'Not publicly disclosed', 'Active (official page 11/13/2026)',
   'Online job search, resume builder, online workshops and virtual meetings; local job centers are open by appointment. Cost not stated on the page.',
   'Use the site, or book a job center appointment through its Job Center Locations page.', 'https://jobcenterofwisconsin.com/', null, 'No', false, 'No', 'Verified – Limited', 'TN3-S10',
   'No phone number on the page; it does not name its operator.', 'Original research (TN.3, 11/13/2026)', date '2026-11-13', 'Yes', 'Online or by appointment', 'Yes (official page 11/13/2026)', true, 'tn3-11/13')
on conflict (program_id) do nothing;

-- Life areas (office links; they survive every directory refresh).
insert into mirror.resource_categories (chpms_program_id, dimension_key, expense_category_key, source, note, added_by)
select v.pid, v.dim, null, 'office', 'TN.3 research 11/13/2026', 'claude (TN.3)'
  from (values ('TN3-PRG01', 'identity_legal'), ('TN3-PRG02', 'identity_legal'), ('TN3-PRG03', 'food'), ('TN3-PRG03', 'finances'), ('TN3-PRG04', 'food'),
               ('TN3-PRG05', 'physical_health'), ('TN3-PRG05', 'mental_health'), ('TN3-PRG06', 'technology'), ('TN3-PRG07', 'technology'), ('TN3-PRG07', 'development'),
               ('TN3-PRG08', 'work'), ('TN3-PRG09', 'work'), ('TN3-PRG09', 'development'), ('TN3-PRG10', 'work')) v(pid, dim)
 where exists (select 1 from chpms_programs p where p.program_id = v.pid)
on conflict do nothing;
