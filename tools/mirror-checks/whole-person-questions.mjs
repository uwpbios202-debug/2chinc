// The Human Mirror Phase 11 (Stephen 11/14/2026: "we are treating the WHOLE person as a standard"): seven life topics that had no
// question, plus the short clothing and laundry check of the Clothes paper, added as questions inside the existing life areas.
// Every question is optional; plain words. Privacy: each question takes its area's category unless set here (custody is legal,
// money questions are financial). Sorts start at 110, after the area's own nine-question pattern and "would you like help" (100).
//
// node tools/mirror-checks/whole-person-questions.mjs > supabase/migrations/20261119700000_mirror_whole_person_questions.sql

import fs from "node:fs";
const HELP = [{ value: "now", label: "Yes, now" }, { value: "later", label: "Maybe later" }, { value: "no", label: "No, thank you" }];
const o = (...labels) => labels.map((l) => (Array.isArray(l) ? { value: l[0], label: l[1] } : { value: l.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, ""), label: l }));
const PRIVATE_MH = "This is private. Only you see it, unless you share \"How you feel inside\" with an organization. In a crisis, call or text 988.";

/** [area, key, type, prompt, help, options, category] (category null = the area's) */
const Q = [
  // ---- Clothing and laundry (self-care): the Clothes paper's short check; the full inventory is the clothing page (T11.1)
  ["self_care", "cl_laundry_access", "choice", "Where can you wash your clothes?", null,
    o(["home", "Washer and dryer at home"], ["shared", "Shared laundry where I live"], ["laundromat", "A laundromat"], ["helper", "Someone else helps me"], ["none", "I have no reliable place"]), null],
  ["self_care", "cl_laundry_often", "choice", "About how often can you do laundry?", "This helps work out how many of each thing you need.",
    o(["weekly", "Every week"], ["two_weeks", "Every 2 weeks"], ["month", "Every 3 or 4 weeks"], ["rarely", "Less often than that"]), null],
  ["self_care", "cl_laundry_cost", "money", "About how much do you spend on laundry in a month?", "Washing, drying, soap and supplies. A rough number is fine.", [], "financial"],
  ["self_care", "cl_condition", "choice", "How are your clothes right now?", null,
    o(["good", "Clean, they fit and they're in good shape"], ["some", "Some need washing or fixing"], ["worn", "A lot are worn out or don't fit"], ["not_enough", "I don't have enough clothes"], ["almost_none", "I have almost no clothes I can use"]), null],
  ["self_care", "cl_needs", "multi", "What clothes do you need right now?", "Pick all that fit.",
    o(["everyday", "Everyday clothes"], ["under", "Underwear and socks"], ["outer", "A coat and clothes for the weather"], ["shoes", "Shoes or boots"], ["work", "Clothes for work or interviews"],
      ["sleep", "Sleepwear"], ["occasion", "Clothes for a special occasion"], ["adaptive", "Adaptive or special clothing"], ["all", "Almost everything"], ["none", "Nothing right now"]), null],
  ["self_care", "cl_barriers", "multi", "What makes it hard to keep your clothes clean and in good shape?", "Pick all that fit.",
    o(["cost", "The cost of laundry"], ["no_machine", "No washer or dryer"], ["transport", "Getting there with my laundry"], ["supplies", "No soap or supplies"], ["drying", "No place to dry clothes"],
      ["storage", "No place to keep clothes"], ["physical", "It's hard for my body"], ["learning", "I'd like to learn how"], ["none", "Nothing gets in the way"]), null],

  // ---- Household furnishings (housing)
  ["housing", "hf_have", "multi", "Which of these do you have for your home?", "Pick all you have.",
    o(["bed", "A bed and mattress"], ["bedding", "Sheets, blankets and pillows"], ["storage", "A dresser or a place for clothes"], ["table", "A table and chairs"], ["seating", "A couch or chairs to sit on"],
      ["kitchen", "Pots, pans, dishes and silverware"], ["towels", "Towels"], ["lights", "Lamps or lights"], ["cleaning", "Cleaning supplies"], ["window", "Curtains or blinds"],
      ["fridge", "A refrigerator (if the place has none)"], ["none", "None of these yet"]), null],
  ["housing", "hf_need_first", "long_text", "What do you need first to make your place feel livable?", null, [], null],
  ["housing", "hf_moving", "choice", "Are you moving soon, or did you just move in?", null,
    o(["soon", "Moving soon"], ["just", "I just moved in"], ["settled", "I'm settled"], ["no_place", "I don't have a place yet"]), null],
  ["housing", "hf_help", "choice", "Would you like help getting furniture or household things?", "You can change this any time.", HELP, null],

  // ---- Substance use and recovery (how you feel inside; private)
  ["mental_health", "su_use", "choice", "Do alcohol, drugs or other substances play a part in your life right now?", PRIVATE_MH,
    o(["no", "No"], ["some", "Sometimes, and it isn't a problem for me"], ["cut_down", "Yes, and I'd like to cut down or stop"], ["recovery", "I'm in recovery"], ["prefer_not", "I'd rather not say"]), null],
  ["mental_health", "su_support", "multi", "What support do you have now?", "Pick all that fit.",
    o(["counseling", "Counseling or outpatient treatment"], ["residential", "A residential program"], ["medication", "Medication for recovery"], ["group", "A support group or meetings"],
      ["sponsor", "A sponsor or peer coach"], ["faith", "My faith community"], ["family", "Family or friends"], ["none", "None right now"]), null],
  ["mental_health", "su_helps", "long_text", "What helps you stay on track?", "For example meetings, people, routines, faith, or staying away from certain places.", [], null],
  ["mental_health", "su_hard", "long_text", "What makes it hard to get or keep support?", null, [], null],
  ["mental_health", "su_housing", "choice", "Would a home that supports recovery (sober living) help you?", null,
    o(["yes", "Yes"], ["maybe", "Maybe"], ["no", "No"]), null],
  ["mental_health", "su_help", "choice", "Would you like help finding treatment or recovery support?", "You can change this any time.", HELP, null],

  // ---- Grief and loss (how you feel inside; private)
  ["mental_health", "gl_loss", "choice", "Have you lost someone or something important to you in the last few years?", PRIVATE_MH,
    o(["yes", "Yes"], ["no", "No"], ["prefer_not", "I'd rather not say"]), null],
  ["mental_health", "gl_now", "long_text", "If you'd like, tell us about the loss and how it affects you now.", "Only as much as you want to share.", [], null],
  ["mental_health", "gl_support", "long_text", "Who or what helps you with grief?", null, [], null],
  ["mental_health", "gl_help", "choice", "Would you like help finding grief support?", "You can change this any time.", HELP, null],

  // ---- Justice involvement (ID, papers and legal; private)
  ["identity_legal", "ji_history", "choice", "Do you have a criminal record, or have you been in jail or prison?", "This is private. Only you see it, unless you share \"ID, papers and legal matters\".",
    o(["no", "No"], ["record", "I have a record"], ["past", "I was in jail or prison in the past"], ["recent", "I came home in the last year"], ["prefer_not", "I'd rather not say"]), null],
  ["identity_legal", "ji_supervision", "choice", "Are you on probation, parole or extended supervision now?", null,
    o(["no", "No"], ["probation", "Probation"], ["parole", "Parole"], ["extended", "Extended supervision"], ["other", "Something else"]), null],
  ["identity_legal", "ji_requirements", "long_text", "What do your supervision or court rules ask of you?", "For example meetings, classes, curfew, testing, fees, or places you can't go.", [], null],
  ["identity_legal", "ji_fees", "money", "About how much do you owe in court fines, fees or restitution?", "A rough number is fine. Skip it if it doesn't apply.", [], "financial"],
  ["identity_legal", "ji_effects", "long_text", "How does your record affect your housing, work or other parts of your life?", null, [], null],
  ["identity_legal", "ji_clear", "choice", "Would you like to find out about clearing or sealing your record, or a pardon?", "In Wisconsin some records can be expunged or pardoned. A legal aid office can tell you what applies.",
    o(["yes", "Yes"], ["started", "I've already started"], ["no", "No"]), null],
  ["identity_legal", "ji_help", "choice", "Would you like help with any of this?", "You can change this any time.", HELP, null],

  // ---- Veteran status (ID, papers and legal; private)
  ["identity_legal", "vet_served", "choice", "Have you served in the U.S. military, the National Guard or the Reserves?", null,
    o(["yes", "Yes"], ["no", "No"], ["prefer_not", "I'd rather not say"]), null],
  ["identity_legal", "vet_papers", "choice", "Do you have your discharge papers (DD-214)?", null, o(["yes", "Yes"], ["no", "No"], ["not_sure", "I'm not sure"]), null],
  ["identity_legal", "vet_va", "multi", "Which veterans' services do you use now?", "Pick all that fit.",
    o(["health", "VA health care"], ["disability", "VA disability pay"], ["pension", "VA pension"], ["education", "GI Bill or education help"], ["housing", "VA housing help (HUD-VASH or SSVF)"],
      ["none", "None"], ["not_sure", "I'm not sure what I can get"]), null],
  ["identity_legal", "vet_help", "choice", "Would you like help connecting with veterans' services?", "You can change this any time.", HELP, null],

  // ---- Debt and credit (money; private)
  ["finances", "dc_kinds", "multi", "What kinds of debt do you have, if any?", "Pick all that fit. This is private: only you see it, unless you share \"Money\".",
    o(["none", "None"], ["cards", "Credit cards"], ["medical", "Medical bills"], ["student", "Student loans"], ["utilities", "Past-due utility bills"], ["rent", "Past-due rent or a landlord judgment"],
      ["payday", "Payday or title loans"], ["car", "A car loan"], ["court", "Court fines or fees"], ["support", "Back child support"], ["taxes", "Taxes owed"], ["other", "Something else"]), null],
  ["finances", "dc_total", "money", "About how much do you owe in all?", "A rough number is fine.", [], null],
  ["finances", "dc_collections", "choice", "Are any debts in collections, or is your pay or bank account being garnished?", null, o(["yes", "Yes"], ["no", "No"], ["not_sure", "I'm not sure"]), null],
  ["finances", "dc_credit", "choice", "Do you know what's on your credit report?", "You can get your reports free at annualcreditreport.com.",
    o(["yes", "Yes"], ["no", "No"], ["want", "I'd like to find out"]), null],
  ["finances", "dc_goal", "long_text", "What would you like to do about debt or credit?", null, [], null],
  ["finances", "dc_help", "choice", "Would you like help with debt or credit (for example free credit counseling)?", "You can change this any time.", HELP, null],

  // ---- Caregiving and children (family and community)
  ["relationships", "cg_children", "choice", "Do you have children under 18?", null,
    o(["with_me", "Yes, living with me"], ["not_with_me", "Yes, not living with me"], ["both", "Some with me, some not"], ["expecting", "I'm expecting"], ["no", "No"]), null],
  ["relationships", "cg_childcare", "choice", "Do you need childcare so you can work, study or get to appointments?", null,
    o(["yes", "Yes"], ["sometimes", "Sometimes"], ["no", "No"]), null],
  ["relationships", "cg_who", "long_text", "Who takes care of your children when you're busy?", null, [], null],
  ["relationships", "cg_kids_needs", "long_text", "Do your children need help with school, health care or activities?", null, [], null],
  ["relationships", "cg_custody", "choice", "Are you dealing with custody, child support or child protective services?", "This one is private: only you see it, unless you share \"ID, papers and legal matters\".",
    o(["yes", "Yes"], ["no", "No"], ["prefer_not", "I'd rather not say"]), "legal"],
  ["relationships", "cg_other", "choice", "Do you take care of someone else, like a parent, partner or relative who needs help?", null, o(["yes", "Yes"], ["no", "No"]), null],
  ["relationships", "cg_load", "rating", "How is caring for others going for you?", "1 means very hard. 5 means very good. Skip it if it doesn't apply.", [], null],
  ["relationships", "cg_help", "choice", "Would you like help with childcare or caregiving?", "You can change this any time.", HELP, null],
];

const AREA_CAT = { housing: "general", self_care: "general", mental_health: "mental_health", identity_legal: "legal", finances: "financial", relationships: "general" };
const lit = (s) => (s == null ? "null" : "'" + String(s).replace(/'/g, "''") + "'");
const next = {};
const rows = Q.map(([area, key, type, prompt, help, options, cat]) => {
  next[area] = (next[area] || 100) + 10;
  return `  (${lit(area)}, ${lit(key)}, ${lit(prompt)}, ${lit(help)}, ${lit(type)}, ${lit(JSON.stringify(options || []))}::jsonb, ${lit(cat || AREA_CAT[area])}, ${next[area]})`;
});

console.log(`-- The Human Mirror Phase 11 (T11.2-T11.8 and the T11.1 short check): ${rows.length} questions for seven life topics that had none
-- (substance use and recovery, grief and loss, justice involvement, veteran status, debt and credit, caregiving and children, household
-- furnishings) and the Clothes paper's clothing and laundry check, added to the existing life areas. GENERATED by
-- tools/mirror-checks/whole-person-questions.mjs (edit there, never by hand). Stephen 11/14/2026: "All of them are critical ... we are
-- treating the WHOLE person as a standard". Every question is optional. Privacy by area (How you feel inside = mental_health; ID, papers
-- and legal = legal; Money = financial), custody = legal, money amounts = financial. New questions start at version 1 (question_versions
-- by trigger); no answer changes. No new table.

insert into mirror.reflection_questions (set_id, key, prompt, help, answer_type, options, category, sort)
select s.id, v.key, v.prompt, v.help, v.answer_type, v.options, v.category, v.sort
from (values
${rows.join(",\n")}
) v(dim, key, prompt, help, answer_type, options, category, sort)
join mirror.question_sets s on s.key = 'dimension_' || v.dim
on conflict (set_id, key) do nothing;

${fs.readFileSync(new URL("./whole-person-suggestions.sql", import.meta.url), "utf8")}`);
