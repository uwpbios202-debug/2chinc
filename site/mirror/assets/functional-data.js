// @ts-check
// The Human Mirror Phase 5 (T5.1): everyday activities and the 11 other functional areas, as data.
// ONE source: the pages import this file, and tools/mirror-checks/phase5-seed.mjs turns it into the seed migration.
// Changing a question later: change it here and generate a NEW migration (the question-version trigger keeps the old wording).
// Rule (prompt Part 5): this is the person's own view of what they do and where they might like support. It is NEVER a diagnosis,
// never a score, and nothing here decides where anyone lives. All of it is private: Physical health (health) or, for memory and
// feelings, How I feel inside (mental_health). A helper sees it only when the person shares that topic with their organization (D-14).

/** @typedef {{ key: string, label: string, help?: string }} Item */

export const NOT_A_DIAGNOSIS = "This is not a diagnosis and not a test. It is your own view of what you do now and what you would like. You decide what happens next.";

/** ADL: personal care (DATABASE_DESIGN: bathing, dressing, transferring, eating, toileting, continence). @type {Item[]} */
export const ADL = [
  { key: "bathing", label: "Bathing or showering" },
  { key: "dressing", label: "Getting dressed" },
  { key: "transferring", label: "Getting in and out of bed or a chair" },
  { key: "eating", label: "Eating" },
  { key: "toileting", label: "Using the toilet" },
  { key: "continence", label: "Bladder and bowel control", help: "For example, getting to the bathroom in time, or using pads." },
];

/** IADL: running a home (meal_prep, shopping, medication, finances, transportation, housekeeping, laundry, devices). @type {Item[]} */
export const IADL = [
  { key: "meal_prep", label: "Making meals" },
  { key: "shopping", label: "Shopping for food and the things I need" },
  { key: "medication", label: "Taking medicine the right way" },
  { key: "finances", label: "Paying bills and handling money" },
  { key: "transportation", label: "Getting where I need to go" },
  { key: "housekeeping", label: "Keeping my home clean" },
  { key: "laundry", label: "Doing laundry" },
  { key: "devices", label: "Using a phone or computer" },
];

/** How it goes now. `not_assessed` = skipped for now. @type {Item[]} */
export const LEVELS = [
  { key: "independent", label: "I do this on my own" },
  { key: "with_device", label: "On my own, with a tool or device", help: "For example a cane, grab bar, pill box or reminder." },
  { key: "some_help", label: "With some help from someone" },
  { key: "full_help", label: "Someone does this for me" },
  { key: "not_assessed", label: "Skip for now" },
];

/** What the person would like, shown beside each level (roadmap T5.1). @type {Item[]} */
export const PREFERENCES = [
  { key: "as_now", label: "Keep it as it is" },
  { key: "more_on_own", label: "Do more on my own" },
  { key: "tools", label: "Try a tool or a change at home" },
  { key: "some_help", label: "Get some help" },
  { key: "more_help", label: "Get more help" },
  { key: "not_sure", label: "Not sure yet" },
];

const AREA_LEVELS = [
  ["on_my_own", "I manage this on my own"], ["with_tools", "On my own, with a tool or device"], ["some_help", "With some help"],
  ["a_lot_of_help", "With a lot of help"], ["hard_now", "This is hard for me right now"], ["not_sure", "Not sure"],
];
const AREA_WANT = PREFERENCES.map((p) => [p.key, p.label]);

/**
 * The 11 other functional areas (question sets of kind "functional", keys functional_<key>). Each asks the same five things:
 * how it goes, what helps, when it is harder, how the person would like it to be, and anything a helper should know.
 * @type {{ key: string, title: string, intro: string, ask: string, category: "health"|"mental_health"|"general" }[]}
 */
export const AREAS = [
  { key: "mobility", title: "Moving around", intro: "Walking, stairs, standing, and getting around inside and outside your home.", ask: "How do you manage moving around?", category: "health" },
  { key: "seeing", title: "Seeing", intro: "Reading signs and mail, seeing at night, and getting around with the sight you have.", ask: "How do you manage with your eyesight?", category: "health" },
  { key: "hearing", title: "Hearing", intro: "Hearing people talk, the phone, the doorbell or an alarm.", ask: "How do you manage with your hearing?", category: "health" },
  { key: "communication", title: "Talking and being understood", intro: "Saying what you need and understanding others, in the language you prefer.", ask: "How do you manage talking with people and being understood?", category: "general" },
  { key: "memory", title: "Memory and thinking", intro: "Remembering things, keeping your focus, and making decisions.", ask: "How do you manage remembering things and making decisions?", category: "mental_health" },
  { key: "organizing", title: "Planning and keeping track", intro: "Keeping track of dates, appointments, papers, and the steps of a task.", ask: "How do you manage keeping track of dates, papers and tasks?", category: "general" },
  { key: "reading_numbers", title: "Reading, writing and numbers", intro: "Reading mail and forms, writing, and working with numbers.", ask: "How do you manage reading, writing and numbers?", category: "general" },
  { key: "feelings", title: "Handling stress and feelings", intro: "Coping when things are hard, and knowing what helps you feel steady.", ask: "How do you manage when things get stressful?", category: "mental_health" },
  { key: "getting_along", title: "Being with other people", intro: "Getting along with neighbors, roommates, landlords, and people in offices.", ask: "How do you manage being around and dealing with other people?", category: "general" },
  { key: "home_safety", title: "Staying safe at home", intro: "Knowing what to do in an emergency, using the stove safely, locking up, and calling for help.", ask: "How do you manage staying safe at home?", category: "general" },
  { key: "health_care", title: "Looking after my health", intro: "Keeping up with health conditions, appointments, sleep, and eating well.", ask: "How do you manage looking after your health?", category: "health" },
];

/** The five questions of one area: [key, type, prompt, help, options|null]. @param {typeof AREAS[number]} a */
export function areaQuestions(a) {
  return [
    ["how", "choice", a.ask, "Choose the one closest to how it goes now.", AREA_LEVELS],
    ["helps", "long_text", "What helps you with this now?", "Tools, devices, people, routines: anything that helps.", null],
    ["harder", "long_text", "When is it harder for you?", "For example at night, on bad days, or in new places.", null],
    ["want", "choice", "How would you like it to be?", "There is no wrong answer. You choose.", AREA_WANT],
    ["know", "long_text", "Is there anything someone helping you should know?", "Only what you want to share. " + NOT_A_DIAGNOSIS, null],
  ];
}

/** @param {Item[]} list @param {string|null|undefined} key */
export const labelOf = (list, key) => (list.find((i) => i.key === key) || { label: key || "" }).label;
