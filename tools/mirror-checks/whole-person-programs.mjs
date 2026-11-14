// The Human Mirror Phase 11, T11.9: resource-directory programs for the whole-person topics (clothing and laundry, household goods,
// substance use and recovery, grief, justice involvement, veterans, debt and credit, childcare, kinship and caregiving).
// Researched 11/14/2026 by Claude from each program's OWN official page, fetched that day; leads came from Stephen's folder audits
// (Issues and fixes/Databases_TheMirror/), but every fact here is from the official page. Same rules as TN.3 (20261119631000).
//
// node tools/mirror-checks/whole-person-programs.mjs > supabase/migrations/20261119702000_chpms_whole_person_programs.sql

const D = "2026-11-14";
const NS = "Not stated on the official page";
const S = [ // source id, title, url, publisher, type
  ["P11-S01", "Clothes (House of Peace Clothes Closet)", "https://www.capuchincommunityservices.org/services/clothes/", "Capuchin Community Services", "Official provider"],
  ["P11-S02", "Other services (St. Ben's Open Door Ministry)", "https://www.capuchincommunityservices.org/services/other-services/", "Capuchin Community Services", "Official provider"],
  ["P11-S03", "Bottomless Closet", "https://communityadvocates.net/what-we-do/milwaukee-womens-center/what-we-do/bottomless-closet.html", "Community Advocates", "Official provider"],
  ["P11-S04", "Programs (free clothing)", "https://www.fathergeneshelp.org/programs/", "Father Gene's Help Center", "Official provider"],
  ["P11-S05", "Children's Clothing Center", "https://www.locmilwaukee.org/children-s-clothing-center", "Milwaukee Ladies of Charity", "Official provider"],
  ["P11-S06", "Repairers of the Breach (home page)", "https://www.repairers.org/", "Repairers of the Breach", "Official provider"],
  ["P11-S07", "Request Help", "https://svdpmilw.org/request-help/", "Society of St. Vincent de Paul – Milwaukee", "Official provider"],
  ["P11-S08", "Relief Center", "https://adullamoutreach.org/relief-center/", "Adullam Outreach", "Official provider"],
  ["P11-S09", "ReStore Franklin", "https://milwaukeerestore.org/locations/restore-franklin/", "Milwaukee Habitat for Humanity ReStore", "Official provider"],
  ["P11-S10", "Furnishings for Heroes", "https://www.wisconsinvets.org/home-support", "Milwaukee Homeless Veterans Initiative", "Official provider"],
  ["P11-S11", "DHS hotlines (Addiction Recovery Helpline)", "https://www.dhs.wisconsin.gov/aboutdhs/hotline.htm", "Wisconsin Department of Health Services", "Official state"],
  ["P11-S12", "Contact (admissions)", "https://www.metahouse.org/contact", "Meta House", "Official provider"],
  ["P11-S13", "Grief Resource Center", "https://www.horizonhomecareandhospice.org/grief-resources/grief-resource-center/", "Horizon Home Care & Hospice", "Official provider"],
  ["P11-S14", "Milwaukee Vet Center", "https://www.va.gov/milwaukee-vet-center/", "U.S. Department of Veterans Affairs", "Official federal"],
  ["P11-S15", "Veterans Crisis Line (home page)", "https://www.veteranscrisisline.net/", "U.S. Department of Veterans Affairs", "Official federal"],
  ["P11-S16", "Expungement and pardon", "https://www.milwaukeejusticecenter.org/expardon.html", "Milwaukee Justice Center", "Official provider"],
  ["P11-S17", "Center for Driver's License Recovery & Employability", "https://www.wiscs.org/cdlre/", "Wisconsin Community Services", "Official provider"],
  ["P11-S18", "Financial Clinic", "https://www.riverworksmke.org/financialclinic", "Riverworks Development Corporation", "Official provider"],
  ["P11-S19", "Wisconsin Shares: Apply", "https://dcf.wisconsin.gov/wishares/apply", "Wisconsin Department of Children and Families", "Official state"],
  ["P11-S20", "Milwaukee Early Care Administration (MECA)", "https://dcf.wisconsin.gov/meca", "Wisconsin Department of Children and Families", "Official state"],
  ["P11-S21", "Child care contacts (Child Care Finder)", "https://dcf.wisconsin.gov/childcare/contacts", "Wisconsin Department of Children and Families", "Official state"],
  ["P11-S22", "Enrollment (Head Start and Early Head Start)", "https://www.nextdoormke.org/enrollment/", "Next Door", "Official provider"],
  ["P11-S23", "Kinship Care", "https://wellpointcare.org/services/child-family-well-being/kinship-care", "Wellpoint Care Network", "Official provider"],
  ["P11-S24", "Helping Fathers (Parent Helpline, Dad Matters)", "https://www.theparentingnetwork.org/fatherhood", "The Parenting Network", "Official provider"],
  ["P11-S25", "Family Caregiver Support Programs", "https://www.dhs.wisconsin.gov/aging/caregiver.htm", "Wisconsin Department of Health Services", "Official state"],
];
const O = [ // org id, name, type, website, address, phone, area, notes, source
  ["P11-ORG01", "Father Gene's Help Center", "Nonprofit", "https://www.fathergeneshelp.org/", "5919 W. National Avenue, West Allis, WI 53214", "414-258-4357", "Greater Milwaukee Area",
    "Official page fetched 11/14/2026.", "P11-S04"],
  ["P11-ORG02", "Milwaukee Ladies of Charity (Children's Clothing Center)", "Nonprofit", "https://www.locmilwaukee.org/", "621 S. 4th Street, Milwaukee, WI 53204", "414-331-2391", "Milwaukee",
    "Official page fetched 11/14/2026.", "P11-S05"],
  ["P11-ORG03", "Horizon Home Care & Hospice (Grief Resource Center)", "Nonprofit", "https://www.horizonhomecareandhospice.org/", "Grief Resource Center: 11002 W. Park Place, Milwaukee, WI 53224",
    "(414) 586-8383 (Grief Resource Center); (414) 365-8300 (Horizon)", "Milwaukee area (open to the public)", "Official page fetched 11/14/2026. Other listings give an older address (11400 W. Lake Park Dr.); the official page gives 11002 W. Park Place.", "P11-S13"],
  ["P11-ORG04", "Riverworks Development Corporation (Riverworks Financial Clinic)", "Nonprofit", "https://www.riverworksmke.org/", "518 E Concordia Ave, Milwaukee, WI 53212", "414-882-7430", "Milwaukee",
    "Official page fetched 11/14/2026.", "P11-S18"],
  ["P11-ORG05", "Next Door (Head Start and Early Head Start)", "Nonprofit", "https://www.nextdoormke.org/", "2545 N. 29th Street, Milwaukee, WI 53210 (also a Capitol Dr. center; address not on the enrollment page)",
    "414-562-2929", "Milwaukee", "Official page fetched 11/14/2026.", "P11-S22"],
  ["P11-ORG06", "Wellpoint Care Network", "Nonprofit", "https://wellpointcare.org/", "8901 W. Capitol Drive, Milwaukee, WI 53222", "(414) 463-1880; Kinship line 414-604-5777", "Milwaukee County",
    "Official page fetched 11/14/2026. Milwaukee County's Kinship Care administrator.", "P11-S23"],
  ["P11-ORG07", "The Parenting Network", "Nonprofit", "https://www.theparentingnetwork.org/", "7516 West Burleigh Street, Milwaukee, WI 53210 (mailing)", "Parent Helpline (414) 671-0566", "Milwaukee",
    "Official page fetched 11/14/2026. Office hours Mon.–Thurs. 8:30 AM–5:30 PM, Fri. 8:30 AM–3:00 PM; IMPACT 2-1-1 after hours.", "P11-S24"],
];
// program id, org, name, form, max, eligibility, how to apply, url, phone, status ('C' current / 'L' limited), source, notes, self referral, method, life areas
const P = [
  ["P11-PRG01", "ORG019", "House of Peace Clothes Closet (free clothes, by appointment)", "Clothing", "Up to 15 items for each person in the family (as published)",
    "Guests from any ZIP code. Bring an ID.", "Call for a free appointment, then come Monday to Friday, 1:00 to 3:30 p.m., to 1702 W. Walnut Street, Milwaukee, WI 53205.",
    "https://www.capuchincommunityservices.org/services/clothes/", "(414) 933-1300", "C", "P11-S01",
    "Free. The same page also lists (414) 271-0135 for the House of Peace; the clothing section gives (414) 933-1300. How often a family may come again: " + NS + ".", "Yes", "Phone for an appointment", ["self_care"]],
  ["P11-PRG02", "ORG019", "St. Ben's Open Door Ministry: showers, laundry, haircuts, help getting a birth certificate or ID, eyeglasses", "Hygiene, laundry and ID help", "N/A",
    NS + " (eligibility).", "Contact St. Ben's at 930 W. State Street, Milwaukee, WI 53233, (414) 271-0135. Days, hours and sign-up: " + NS + ".",
    "https://www.capuchincommunityservices.org/services/other-services/", "(414) 271-0135", "L", "P11-S02",
    "Verified – Limited: the official page lists the services but not the days, hours, eligibility or cost. Call before going.", "Yes", "Phone or in person", ["self_care", "identity_legal"]],
  ["P11-PRG03", "ORG001", "Bottomless Closet (work clothes and interview preparation)", "Work clothing and job readiness", "Two interview outfits; up to five more once hired (as published)",
    "Men and women entering or re-entering the workforce, referred by a community or government agency.", "By appointment, with a referral from a community or government agency. 728 N. James Lovell St., Milwaukee, WI 53233.",
    "https://communityadvocates.net/what-we-do/milwaukee-womens-center/what-we-do/bottomless-closet.html", "(414) 449-4777", "C", "P11-S03",
    "Free. Hours: " + NS + ". Also coaching on appearance, grooming, body language and interviewing.", "No (agency referral)", "Agency referral, by appointment", ["self_care", "work"]],
  ["P11-PRG04", "P11-ORG01", "Free clothing: workwear, winter coats, hats and gloves, shoes and boots for all ages", "Clothing", "N/A (free)",
    "Anyone in the Greater Milwaukee Area facing financial hardship. Bring a photo ID (state ID, driver license, military ID or MCTS card); a photo of the ID on a phone is accepted.",
    "Walk in, no appointment: Monday to Thursday, 9:00 a.m. to 1:15 p.m. (last shoppers 1:15 p.m.), 5919 W. National Avenue, West Allis, WI 53214.",
    "https://www.fathergeneshelp.org/programs/", "414-258-4357", "C", "P11-S04",
    "All items free. New socks and underwear when available. How often someone may shop: " + NS + ". Agencies, schools and churches may refer.", "Yes", "Walk in", ["self_care"]],
  ["P11-PRG05", "P11-ORG02", "Children's Clothing Center (school-aged children)", "Children's clothing", "Each child: 7 pairs of underwear and socks, 5 shirts, 3 pairs of pants, 1 hoodie, a winter coat, hat and gloves (as published)",
    "Children in need, 3K through high school, in Milwaukee.", "A school principal or social worker refers the family with a voucher. Open during the school year: Tuesdays and Thursdays 10:00 a.m. to 1:00 p.m., and the 2nd Saturday of each month 1:00 to 3:00 p.m.",
    "https://www.locmilwaukee.org/children-s-clothing-center", "414-331-2391", "C", "P11-S05", "Cost: " + NS + ".", "No (school voucher)", "School referral voucher", ["self_care", "relationships"]],
  ["P11-PRG06", "ORG018", "Repairers of the Breach day center: showers, hygiene products, clean clothes (including interview clothes), meals", "Day shelter services", "N/A",
    "Members: people who are homeless or at risk.", "Come to 1335 W Vliet St, Milwaukee, WI 53205, Monday to Saturday, 7:00 a.m. to 3:45 p.m.",
    "https://www.repairers.org/", "414-342-9323 (center); 414-934-9305 (office)", "C", "P11-S06",
    "Milwaukee's only daytime homeless shelter open six days a week (as published). Also a free medical clinic and employment help. Laundry and cost: " + NS + ".", "Yes", "Walk in", ["self_care", "food", "housing"]],
  ["P11-PRG07", "ORG064", "Neighbors helping neighbors: basic needs (food, clothing, household items) after a home or phone visit", "Home visit and basic needs", "Not publicly disclosed",
    NS + " (eligibility). The address on the form must be where help is needed; Milwaukee County.", "Fill in the online form, or call 414-462-7837 ext. 110 if you cannot. Processing takes 3 to 4 weeks; a volunteer then calls within 1 to 3 weeks to arrange a home or phone visit.",
    "https://svdpmilw.org/request-help/", "414-462-7837 ext. 110", "C", "P11-S07", "Furniture, beds and gift certificates are not named on the page.", "Yes", "Online form or phone", ["housing", "food", "self_care"]],
  ["P11-PRG08", "ORG024", "Relief Center: free furniture and household goods (mattresses, dressers, couches, bedding, dishes, pots and pans)", "Furniture and household goods", "N/A (free)",
    "Families and individuals in great need, with a furniture referral from Catholic Charities.", "Get a furniture referral for Adullam Outreach at a Catholic Charities office, then come on the 1st or 3rd Thursday, 10:00 a.m. to 2:00 p.m., to 3033 N. 30th St, Milwaukee, WI 53210 with a photo ID, proof of current address (names must match) and the referral.",
    "https://adullamoutreach.org/relief-center/", "(414) 509-5050", "C", "P11-S08", "Email reliefcenter@adullamoutreach.org. Delivery or pickup for recipients: " + NS + ".", "No (Catholic Charities referral)", "Referral, then in person", ["housing", "life_skills"]],
  ["P11-PRG09", "ORG098", "Habitat ReStore (Franklin and Wauwatosa): donated furniture, appliances and home goods", "Low-cost store", "Not publicly disclosed (store prices)",
    "Open hours are published; whether anyone may shop is not stated on the page.", "Franklin: 6939 S Riverwood Blvd, Franklin, WI 53132, Tuesday to Friday 10:00 a.m. to 6:00 p.m., Saturday 10:00 a.m. to 4:00 p.m. Wauwatosa: 3015 N 114th St, Wauwatosa, WI 53222.",
    "https://milwaukeerestore.org/locations/restore-franklin/", "(414) 257-9078", "L", "P11-S09",
    "Verified – Limited: the page describes the donations the store takes, not what it sells or delivery for buyers. Call before going.", "Yes", "In store", ["housing"]],
  ["P11-PRG10", "ORG029", "Furnishings for Heroes: furniture, household goods, bedding, toiletries, kitchenware and groceries for veterans setting up a home", "Household set-up for veterans", "N/A (free)",
    "Veterans and their families (criteria " + NS + ").", "How to apply: " + NS + ". Call the office: 6300 W. National Ave., West Allis, WI 53214.",
    "https://www.wisconsinvets.org/home-support", "414-257-4111", "L", "P11-S10", "Verified – Limited: the page gives no application or referral steps. Email info@MHVIvets.org.", "Yes", "Phone", ["housing", "identity_legal"]],
  ["P11-PRG11", "ORG113", "Wisconsin Addiction Recovery Helpline (dial 211)", "Phone help and referral", "N/A",
    NS + " (who may call).", "Dial 211, 24 hours a day, seven days a week.", "https://www.dhs.wisconsin.gov/aboutdhs/hotline.htm", "211", "C", "P11-S11",
    "Cost and what the line covers beyond its name: " + NS + ".", "Yes", "Phone", ["mental_health"]],
  ["P11-PRG12", "ORG088", "Meta House residential and outpatient treatment (women 18 and older)", "Substance use treatment", "Not publicly disclosed",
    "Women 18 or older.", "Call the admissions team: residential (414) 977-5884, outpatient (414) 962-1200. 535 N. 39th Street, Milwaukee, WI 53208.",
    "https://www.metahouse.org/contact", "(414) 977-5884 (residential); (414) 962-1200 (outpatient)", "C", "P11-S12",
    "Recovery housing is a separate program already listed (PRG064, (414) 977-5880). Hours, cost and insurance: " + NS + ".", "Yes", "Phone (admissions)", ["mental_health", "physical_health"]],
  ["P11-PRG13", "P11-ORG03", "Grief Resource Center: short-term individual and family counseling, support groups for different losses, workshops, library", "Grief support", "N/A (free; no insurance required)",
    "Anyone experiencing the death of someone significant to them; open to the public.", "Call (414) 586-8383 for a counseling appointment. Walk-ins welcome during open hours (information, tour, library): Monday, Tuesday, Thursday 12:00 to 6:00 p.m.; Wednesday, Friday 12:00 to 4:30 p.m. 11002 W. Park Place, Milwaukee, WI 53224.",
    "https://www.horizonhomecareandhospice.org/grief-resources/grief-resource-center/", "(414) 586-8383", "C", "P11-S13",
    "Group registration steps: " + NS + "; call. Referrals for longer-term counseling.", "Yes", "Phone or walk in", ["mental_health"]],
  ["P11-PRG14", "ORG030", "Milwaukee Vet Center: counseling for veterans, service members and families (PTSD, depression, grief, couples and family, bereavement)", "Counseling", "N/A (no cost)",
    "Veterans and service members (including National Guard and Reserve) who meet service requirements such as combat-theater duty; any character of discharge; VA health care enrollment not needed; family as the veteran defines it.",
    "Call 414-434-1311 (scheduling) or the 24/7 call center 877-927-8387. Monday to Friday 8:00 a.m. to 4:30 p.m.; other hours by appointment. 11925 W. Lake Park Drive, Milwaukee, WI 53224.",
    "https://www.va.gov/milwaukee-vet-center/", "414-434-1311; 877-927-8387 (24/7)", "C", "P11-S14", "Confidential.", "Yes", "Phone", ["mental_health", "relationships", "identity_legal"]],
  ["P11-PRG15", "ORG030", "Veterans Crisis Line (dial 988 then press 1; text 838255; chat)", "Crisis line", "N/A (free)",
    "Veterans, service members, National Guard and Reserve members, and those who support them. No VA enrollment needed.", "Dial 988 then press 1, text 838255, or chat online. 24/7, 365 days a year.",
    "https://www.veteranscrisisline.net/", "988, press 1", "C", "P11-S15", "Free and confidential.", "Yes", "Phone, text or chat", ["mental_health", "safety", "identity_legal"]],
  ["P11-PRG16", "ORG044", "Pardon application clinics and expungement information (clinics paused August to December 2026)", "Legal information", "N/A",
    "Pardon: at least one Wisconsin felony conviction, at least 5 years since finishing any sentence, no open cases, not on the sex offender registry. Expungement: very narrow (generally under 25 at the time, case from 2009 or later, judge found eligibility at sentencing).",
    "The clinics are on hiatus as of August 2026 and cannot help or answer questions until then; check back from January 2027.", "https://www.milwaukeejusticecenter.org/expardon.html", NS, "C", "P11-S16",
    "Paused (official page 11/14/2026). Address, phone and cost: " + NS + ". Legal Action of Wisconsin (already listed) also helps with record barriers.", "Yes", "Not taking requests until January 2027", ["identity_legal"]],
  ["P11-PRG17", "ORG052", "Center for Driver's License Recovery & Employability (CDLRE)", "Legal help with license suspensions and revocations", "Not publicly disclosed",
    "Low-income Milwaukee County residents with an active Wisconsin license suspension or revocation, or who cannot get a license.", "Call (414) 297-6407. Pre-approved appointments, weekday mornings and afternoons. 700 West State Street, Student Center, Room S215, Milwaukee, WI 53233.",
    "https://www.wiscs.org/cdlre/", "(414) 297-6407", "C", "P11-S17", "Cost: " + NS + ".", "Yes", "Phone", ["identity_legal", "transportation", "work"]],
  ["P11-PRG18", "P11-ORG04", "Riverworks Financial Clinic (Milwaukee Financial Empowerment Center): coaching on debt, credit building and budgeting", "Free financial coaching", "N/A (free)",
    "All residents, regardless of income.", "Schedule online at riverworksmke.org/clinic-appointment or call 414-882-7430. Monday to Friday 9:00 a.m. to 5:00 p.m., by appointment only. 518 E Concordia Ave, Milwaukee, WI 53212.",
    "https://www.riverworksmke.org/financialclinic", "414-882-7430", "C", "P11-S18", "Riverworks also offers free tax preparation (VITA) for people who generally make $69,000 or less.", "Yes", "Online or phone appointment", ["finances"]],
  ["P11-PRG19", "ORG035", "Wisconsin Shares child care subsidy (apply)", "Child care subsidy", "Not publicly disclosed (depends on income, household size and care; a copayment applies)",
    "Family income up to 200% of the federal poverty level (for example $3,607 a month for 2 people, $5,500 for 4, as published) and an approved activity such as work, school or an apprenticeship.",
    "Online through ACCESS, or in Milwaukee County call Milwaukee Enrollment Services (MilES) at 1-888-947-6583, option 2. Bring ID, the children's Social Security numbers, proof of address and the last 30 days of pay stubs.",
    "https://dcf.wisconsin.gov/wishares/apply", "1-888-947-6583, option 2 (MilES)", "C", "P11-S19",
    "The family pays any amount the provider charges above the subsidy. Child support cooperation is required unless the other parent threatens your safety.", "Yes", "Online (ACCESS) or phone", ["relationships", "finances"]],
  ["P11-PRG20", "ORG035", "Milwaukee Early Care Administration (MECA): child care authorizations for Wisconsin Shares", "Subsidy authorization", "N/A",
    "Milwaukee County families approved for Wisconsin Shares.", "Call 1-888-947-6583, option 3 then 3 (711 TTY): Monday, Tuesday, Wednesday, Friday 8:00 a.m. to 4:30 p.m.; Thursday 8:00 a.m. to 2:00 p.m. Or use the MyWIChildCare Parent Portal. No in-person authorization services.",
    "https://dcf.wisconsin.gov/meca", "1-888-947-6583 (option 3, then 3)", "C", "P11-S20", "General questions voicemail 414-615-6318, returned within 48 business hours. Document drop-off at 6055 N. 64th St. or 2701 S. Chase Ave.", "Yes", "Phone or online portal", ["relationships"]],
  ["P11-PRG21", "ORG035", "Child Care Finder (search licensed and certified child care)", "Search tool", "N/A",
    "Anyone.", "Search at childcarefinder.wisconsin.gov.", "https://childcarefinder.wisconsin.gov/", NS, "C", "P11-S21",
    "The state page also points to Child Care Resource and Referral agencies (thrivingwi.org); the Milwaukee agency's name and phone: " + NS + ".", "Yes", "Online", ["relationships"]],
  ["P11-PRG22", "P11-ORG05", "Head Start and Early Head Start (ages 6 weeks to 4 years)", "Early childhood education", "Not publicly disclosed",
    "Income-based; priority points for foster children, families in crisis and families on public assistance.", "Complete the online interest form, then finish enrollment in person (walk-in enrollment Monday to Friday, 9:00 a.m. to 3:00 p.m., at the 29th St. or Capitol Dr. center).",
    "https://www.nextdoormke.org/enrollment/", "414-562-2929", "C", "P11-S22", "Center hours Monday to Friday 8:00 a.m. to 3:00 p.m. (extended hours for qualified families). Cost: " + NS + ".", "Yes", "Online interest form, then in person", ["relationships", "development"]],
  ["P11-PRG23", "P11-ORG06", "Kinship Care (Milwaukee County): financial support for a relative raising a child", "Monthly payment for a relative caregiver", "Not publicly disclosed on the official page",
    "A child living with a relative or like-kin caregiver whose needs are better met there, in the child's best interest, who meets or would meet the need-for-protection rules; background check of the caregiver and adults in the home; apply for other benefits.",
    "Call the Kinship line 414-604-5777, email, use the online form, or visit Monday to Friday 9:00 a.m. to 5:00 p.m., 8901 W. Capitol Drive, Milwaukee, WI 53222.",
    "https://wellpointcare.org/services/child-family-well-being/kinship-care", "414-604-5777", "C", "P11-S23", "Annual reviews; referral of the parents to child support unless exempt.", "Yes", "Phone, email, online or in person", ["relationships", "finances"]],
  ["P11-PRG24", "P11-ORG07", "Parent Helpline and Dad Matters fatherhood classes", "Parent support", "N/A (Dad Matters free)",
    "Dad Matters: open enrollment, join any time. Helpline: " + NS + " (eligibility).", "Call the Parent Helpline (414) 671-0566. Dad Matters meets Saturdays at 10:00 a.m., 4828 W. Fond du Lac Ave., Milwaukee, WI 53216.",
    "https://www.theparentingnetwork.org/fatherhood", "(414) 671-0566", "C", "P11-S24", "Also Triple P and parenting classes (details not on the page).", "Yes", "Phone", ["relationships"]],
  ["P11-PRG25", "ORG113", "Family caregiver support (National Family Caregiver Support Program; Alzheimer's Family and Caregiver Support Program)", "Respite, training and support for caregivers", "Not publicly disclosed",
    "Caregivers of an adult 60 or older; a grandparent or relative 55 or older raising a child under 18; the primary caregiver of an adult with a severe disability (priority: low income, dementia). The Alzheimer's program needs a diagnosis and care at home.",
    "First call your local Aging and Disability Resource Center: 1-844-WIS-ADRC, or FindMyADRC.org.", "https://www.dhs.wisconsin.gov/aging/caregiver.htm", "1-844-WIS-ADRC", "C", "P11-S25",
    "Respite (bathing, shopping, meals, snow removal, rides), caregiver training, support groups, counseling, adaptive equipment and minor home changes. Cost: " + NS + ".", "Yes", "Phone (ADRC)", ["relationships", "physical_health"]],
];

const q = (s) => (s == null ? "null" : "'" + String(s).replace(/'/g, "''") + "'");
const out = [];
out.push(`-- The Human Mirror Phase 11, T11.9: ${P.length} resource-directory programs for the whole-person topics (clothing and laundry, household goods,
-- substance use and recovery, grief, justice involvement, veterans, debt and credit, childcare, kinship and caregiving). GENERATED by
-- tools/mirror-checks/whole-person-programs.mjs (edit there, never by hand).
-- Researched 11/14/2026 by Claude from each program's OWN official page, fetched that day. Leads came from Stephen's folder audits
-- (Issues and fixes/Databases_TheMirror/); no fact is copied from them. Same rules as TN.3: every fact cites its source (P11-S01..S25);
-- amounts only where the page publishes one; a missing fact is written "${NS}"; "Verified – Current" only where the
-- official page states it, otherwise "Verified – Limited" with the reason. Left out because the official page could not be checked on
-- 11/14/2026: Milwaukee County CARS access points and County Veterans Services (the county site refuses automated reads), SAMHSA's helpline
-- and FindTreatment.gov (page did not load). Kids Matter's kinship page was out of date (a 2024 rate) and is not used.
-- Existing directory organizations are reused and not changed (the workbook import owns them); 7 organizations are new. Rows are
-- office-added (is_local, import_version 't119-11/14'). Each program gets office life-area links (mirror.resource_categories). Call before you refer.

insert into chpms_sources (source_id, title, url, publisher, source_type, date_accessed) values
${S.map(([id, t, u, p, ty]) => `  (${q(id)}, ${q(t)}, ${q(u)}, ${q(p)}, ${q(ty)}, date '${D}')`).join(",\n")}
on conflict (source_id) do nothing;

insert into chpms_orgs (org_id, legal_name, org_type, website, physical_address, main_phone, service_area, accepts_outside_referrals, verification_status,
  verification_notes, source_ids, primary_source_url, provenance, date_accessed, is_local, import_version) values
${O.map(([id, n, ty, w, a, ph, ar, no, src]) => `  (${q(id)}, ${q(n)}, ${q(ty)}, ${q(w)}, ${q(a)}, ${q(ph)}, ${q(ar)}, 'Not stated', 'Verified – Current', ${q(no)}, ${q(src)}, ${q(S.find((s) => s[0] === src)[2])}, 'Original research (T11.9, 11/14/2026)', date '${D}', true, 't119-11/14')`).join(",\n")}
on conflict (org_id) do nothing;

insert into chpms_programs (program_id, org_id, program_name, assistance_form, max_assistance, current_status, eligibility_summary, how_to_apply, application_url,
  intake_phone, direct_financial, is_direct_financial, amount_publicly_disclosed, verification_status, source_ids, notes, provenance, date_accessed, self_referral,
  application_method, currently_open, is_local, import_version) values
${P.map(([id, org, n, f, mx, el, how, url, ph, st, src, no, self, meth]) => {
  const paused = /paused|hiatus/i.test(n + how);
  const money = ["Child care subsidy", "Monthly payment for a relative caregiver"].includes(f);   // money paid for the person
  return `  (${q(id)}, ${q(org)}, ${q(n)}, ${q(f)}, ${q(mx)}, ${q(paused ? "Paused (official page 11/14/2026)" : "Active (official page 11/14/2026)")}, ${q(el)}, ${q(how)}, ${q(url)},
   ${q(ph)}, ${q(money ? "Yes" : "No")}, ${money}, ${q(/\$/.test(mx) ? "Yes" : "No")}, ${q(st === "C" ? "Verified – Current" : "Verified – Limited")}, ${q(src)}, ${q(no)},
   'Original research (T11.9, 11/14/2026)', date '${D}', ${q(self)}, ${q(meth)}, ${q(paused ? "No (official page 11/14/2026)" : "Yes (official page 11/14/2026)")}, true, 't119-11/14')`;
}).join(",\n")}
on conflict (program_id) do nothing;

-- Life areas (office links; they survive every directory refresh).
insert into mirror.resource_categories (chpms_program_id, dimension_key, expense_category_key, source, note, added_by)
select v.pid, v.dim, null, 'office', 'T11.9 research 11/14/2026', 'claude (T11.9)'
  from (values ${P.flatMap(([id, , , , , , , , , , , , , , areas]) => areas.map((a) => `(${q(id)}, ${q(a)})`)).join(", ")}) v(pid, dim)
 where exists (select 1 from chpms_programs p where p.program_id = v.pid)
on conflict do nothing;`);
console.log(out.join("\n"));
