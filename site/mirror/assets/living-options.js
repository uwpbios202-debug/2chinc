// @ts-check
// The Human Mirror Phase 5 (T5.2): living options and the housing profile's lists, as data, plus the public page renderer.
// ONE source: the public page (/mirror/living-options/), the person's page (/mirror/my-mirror/living/) and the seed migration
// (tools/mirror-checks/phase5-seed.mjs) all come from this file. No database calls here (the public page is signed out).
// Rule (prompt Part 5): never recommend assisted living or any setting automatically. These are options a person can explore;
// the person chooses. "Professional review needed" is a note from someone helping them, never a decision.

/** @typedef {{ key: string, title: string, summary: string, what: string, support: string, who: string, pay: string, ask: string[] }} Option */

/** The 7 living options (DATABASE_DESIGN housing_options keys). @type {Option[]} */
export const OPTIONS = [
  { key: "independent", title: "Living on my own",
    summary: "Your own apartment or house, rented or owned, run your way.",
    what: "You hold the lease or own the home. You decide who lives with you, when you come and go, and how you run your day.",
    support: "No support comes with the home itself. Family, friends or community services can still help when you want them.",
    who: "Anyone who wants to run their own home, with or without help from outside.",
    pay: "Rent or a mortgage, plus utilities. Rent help such as a housing choice voucher can lower what you pay.",
    ask: ["What is the full monthly cost, with utilities?", "Is it close to the bus, stores and the people I count on?", "Can I make changes I need, like grab bars?"] },
  { key: "supported_independent", title: "My own place, with support that comes to me",
    summary: "Your own home, with help that visits you there.",
    what: "You live in your own place. Help comes to you: for example a home care worker, a nurse visit, meals, or someone who checks in.",
    support: "As much or as little as you choose and qualify for, from a few hours a month to help every day.",
    who: "People who want to stay in their own home and would like help with some everyday tasks.",
    pay: "Rent as usual. In Wisconsin, programs such as Family Care or IRIS may pay for support at home for people who qualify.",
    ask: ["Which tasks would I like help with?", "Who would come, and how often?", "Can I choose or change my helper?"] },
  { key: "assisted", title: "Assisted living",
    summary: "A home with your own room or apartment, where help is there every day.",
    what: "You live in a place where staff help with things like meals, medicine and personal care. In Wisconsin this includes adult family homes, community-based residential facilities (CBRFs) and residential care apartment complexes (RCACs).",
    support: "Staff are on site; how much they help depends on the place and on what you need.",
    who: "People who would like daily help close by. It is one option among several, never the only one, and it is your choice.",
    pay: "Usually a monthly fee for room, board and care. Medicaid programs may pay the care part for people who qualify.",
    ask: ["Will I have my own room and my own bathroom?", "What does the monthly fee include, and what costs extra?", "Can I keep my routines, my visitors and my things?"] },
  { key: "skilled_nursing", title: "Nursing home (skilled nursing care)",
    summary: "Nursing care around the clock, for a short stay or longer.",
    what: "Nurses and aides are on duty day and night. Many people stay for a short time, for example to recover after a hospital stay, then go home.",
    support: "Medical and personal care at any hour.",
    who: "Usually people whose doctor or care team says they need nursing care every day. You still have a say in where you go and for how long.",
    pay: "Medicare may pay for a short stay after a hospital visit; Medicaid may pay for a longer stay for people who qualify.",
    ask: ["Is this for a short stay or longer?", "What is the plan to go home?", "Who can I talk to if I want to leave?"] },
  { key: "accessible", title: "Accessible housing",
    summary: "A home built or changed to fit your body and your needs.",
    what: "For example no steps at the door, wide doorways, a roll-in shower, grab bars, or flashing smoke alarms. It can be your own place or any other kind of housing.",
    support: "The home itself is the support. Help from people can be added, as in the other options.",
    who: "Anyone who would be safer or freer in a home without barriers.",
    pay: "Like any rent. Landlords may have to allow reasonable changes you ask for; some programs help pay for changes.",
    ask: ["Which features do I need, and which would be nice?", "Is the building and the way in accessible, not only the unit?", "Can changes be made if I need more later?"] },
  { key: "permanent_supportive", title: "Permanent supportive housing",
    summary: "Your own lease, with rent help and support services, and no time limit.",
    what: "A home of your own with a lease, plus a case manager or support staff you can work with. You can stay as long as you follow the lease.",
    support: "Support services you can work with. In Housing First programs, using them is not a condition of keeping your home; ask each program.",
    who: "Often people who have been without a home for a long time and live with a disability. Entry is usually through a referral or a waiting list.",
    pay: "Usually about 30 percent of your income goes to rent; the program pays the rest.",
    ask: ["How do I get on the list, and who refers me?", "What support is offered, and is it required?", "How long is the wait?"] },
  { key: "other_specialized", title: "Other specialized housing",
    summary: "Homes for a particular group or purpose.",
    what: "For example senior apartments, recovery housing, shared housing with roommates, housing for young adults, or for families leaving violence.",
    support: "Depends on the place: from none to a lot.",
    who: "People for whom one of these fits what they want right now.",
    pay: "Depends on the program; many charge rent based on income.",
    ask: ["What are the house rules?", "How long can I stay?", "What happens if my needs change?"] },
];

/** Where someone lives (current arrangement and housing history). Category = who may see it (D-14). */
export const ARRANGEMENTS = [
  { key: "own_home", label: "My own home (I own it)", category: "general" },
  { key: "renting", label: "Renting my own place", category: "general" },
  { key: "with_others", label: "With family or friends", category: "general" },
  { key: "shelter", label: "A shelter", category: "general" },
  { key: "transitional", label: "A transitional or short-term program", category: "general" },
  { key: "supportive", label: "Supportive housing", category: "general" },
  { key: "care_setting", label: "Assisted living, a nursing home or another care setting", category: "health" },
  { key: "hospital_treatment", label: "A hospital or treatment program", category: "health" },
  { key: "jail", label: "Jail or prison", category: "legal" },
  { key: "hotel", label: "A hotel or motel", category: "general" },
  { key: "outside", label: "Outside, in a car, or somewhere not meant for living", category: "general" },
  { key: "other", label: "Somewhere else", category: "general" },
];

/** What makes finding a home hard. Legal and health ones stay private unless shared. */
export const BARRIERS = [
  { key: "rent_cost", label: "Rent is too high for my income", category: "general" },
  { key: "move_in_cost", label: "Saving for a deposit and first month", category: "general" },
  { key: "credit", label: "My credit history", category: "general" },
  { key: "eviction", label: "An eviction on my record", category: "legal" },
  { key: "criminal_record", label: "A criminal record", category: "legal" },
  { key: "no_id", label: "Missing ID or papers", category: "general" },
  { key: "income_proof", label: "Proving my income", category: "general" },
  { key: "references", label: "No landlord references", category: "general" },
  { key: "fit_needs", label: "Finding a place that fits my body or my needs", category: "health" },
  { key: "pets", label: "A pet or service animal", category: "general" },
  { key: "household_size", label: "The size of my household", category: "general" },
  { key: "location", label: "Getting to work, school or the bus", category: "general" },
  { key: "waitlists", label: "Long waiting lists", category: "general" },
  { key: "unfair", label: "Being treated unfairly", category: "general" },
  { key: "other", label: "Something else", category: "general" },
];

/** What a home needs to have (all private health information). */
export const ACCESS_NEEDS = [
  { key: "no_stairs", label: "No stairs, or a ground floor" },
  { key: "elevator", label: "An elevator" },
  { key: "wheelchair", label: "Room for a wheelchair or walker" },
  { key: "grab_bars", label: "Grab bars" },
  { key: "roll_in_shower", label: "A walk-in or roll-in shower" },
  { key: "wide_doors", label: "Wide doorways" },
  { key: "visual_alarms", label: "A flashing doorbell or smoke alarm" },
  { key: "service_animal", label: "Room for a service animal" },
  { key: "quiet", label: "A quiet place" },
  { key: "near_care", label: "Close to my doctor or clinic" },
  { key: "other", label: "Something else" },
];

export const REVIEW_MEANS = "Someone helping you marked \"professional review needed\". It means a trained professional, such as a nurse, a social worker or an options counselor, could help you look at your choices. It is not a decision, it does not move you anywhere, and you still choose.";

/** @param {unknown} s */
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => /** @type {Record<string,string>} */ ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

/** One option as a card (public page and the person's page). @param {Option} o @param {string} [extra] trusted HTML */
export function optionCard(o, extra = "") {
  return `<article class="mm-card mm-read" id="opt-${esc(o.key)}">
    <h3 style="margin-top:0">${esc(o.title)}</h3>
    <p class="mm-lead" style="font-size:1.05em">${esc(o.summary)}</p>
    <p><strong>What it is.</strong> ${esc(o.what)}</p>
    <p><strong>Help that comes with it.</strong> ${esc(o.support)}</p>
    <p><strong>Who it may suit.</strong> ${esc(o.who)}</p>
    <p><strong>Paying for it.</strong> ${esc(o.pay)}</p>
    <p style="margin-bottom:var(--mm-space-1)"><strong>Questions to ask</strong></p>
    <ul>${o.ask.map((q) => `<li>${esc(q)}</li>`).join("")}</ul>${extra}
  </article>`;
}

/** Fills the public page's list. */
export function livingOptionsPublic() {
  const el = document.getElementById("mmOptions");
  if (el) el.innerHTML = OPTIONS.map((o) => optionCard(o)).join("");
}
