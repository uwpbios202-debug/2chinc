// @ts-check
// The Human Mirror: the 8 perspectives and the 15 life dimensions as data (the prompt, Parts 2 and 3).
// One source for the public pages now and the assessment engine later (T3.1 seeds the same keys).
//
//   <ol data-mm-list="perspectives"></ol>   or   <ol data-mm-list="dimensions"></ol>   fills itself on load.

/** @typedef {{ key: string, n: number, title: string, question?: string, intro: string }} Item */

/** @type {Item[]} */
export const PERSPECTIVES = [
  { key: "identity", n: 1, title: "Identity", question: "Who am I today?", intro: "Where I am right now: where I live, what I have, what my days look like, what makes me happy and what I'm proud of." },
  { key: "history", n: 2, title: "History", question: "Who have I been?", intro: "Where I came from, what I've done, learned and overcome. The past helps explain the journey; it does not decide the future." },
  { key: "vision", n: 3, title: "Vision", question: "Who do I want to become?", intro: "The life I want: the home, the work, the learning, the relationships. My vision, in my words; nobody writes it for me." },
  { key: "assets", n: 4, title: "Assets", question: "What do I have within me?", intro: "What I'm good at, what I know, what people appreciate about me, and the strengths that helped me get through hard times." },
  { key: "needs", n: 5, title: "Needs", question: "What must change, and what do I need?", intro: "What stands between today and the life I want, and what would help most. The bridge from today to tomorrow." },
  { key: "function", n: 6, title: "Function", question: "What can I do now, and where might I want support?", intro: "Everyday tasks I handle on my own, and the ones where a little help would make life easier. Never a diagnosis." },
  { key: "preferences", n: 7, title: "Preferences", question: "How do I want to live?", intro: "Where, how and with whom I want to live, and the choices that matter to me." },
  { key: "contribution", n: 8, title: "Contribution", question: "Who can I help, and what can I give back?", intro: "What I can share or teach, who I'd like to help, and what I'd like to be remembered for. Contribution is more than a paycheck." },
];

/** @type {Item[]} */
export const DIMENSIONS = [
  { key: "housing", n: 1, title: "Shelter, housing and personal environment", intro: "A safe, stable place to live, and a space that feels like your own." },
  { key: "physical_health", n: 2, title: "Physical health and healthcare", intro: "Your body, your care, and getting to the doctor, dentist and pharmacy." },
  { key: "mental_health", n: 3, title: "Mental health and emotional well-being", intro: "How you feel, what weighs on you, and what helps you feel steady." },
  { key: "identity_legal", n: 4, title: "Identity, documentation and legal standing", intro: "ID, birth certificate, Social Security card and any legal matters that need sorting out." },
  { key: "food", n: 5, title: "Food, nutrition and basic necessities", intro: "Enough good food, and the everyday things a household needs." },
  { key: "transportation", n: 6, title: "Transportation and mobility", intro: "Getting where you need to go: bus, car, rides, or help moving around." },
  { key: "technology", n: 7, title: "Technology and digital inclusion", intro: "A working phone, internet, and the skills to use them for the things that matter." },
  { key: "work", n: 8, title: "Education, employment and career development", intro: "Learning, work, training and the career you'd like to build." },
  { key: "finances", n: 9, title: "Financial stability and economic independence", intro: "Income, bills, savings and what it really costs to live one day: your Daily Number." },
  { key: "self_care", n: 10, title: "Personal presentation, hygiene and self-care", intro: "Clothing, laundry, hygiene and feeling good about how you show up." },
  { key: "relationships", n: 11, title: "Social relationships, family and community", intro: "The people in your life, the people who count on you, and where you belong." },
  { key: "life_skills", n: 12, title: "Life skills and independent living", intro: "Cooking, budgeting, keeping a home, and the skills for running your own life." },
  { key: "safety", n: 13, title: "Personal safety, security and protection", intro: "Feeling safe where you live and with the people around you." },
  { key: "development", n: 14, title: "Personal development, interests and fulfillment", intro: "What you enjoy, what you're curious about, and what makes life feel full." },
  { key: "purpose", n: 15, title: "Purpose, contribution and long-term independence", intro: "Where you're headed, what you give back, and standing on your own for the long run." },
];

/** @param {unknown} s */
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => /** @type {Record<string,string>} */ ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

/** Fills <ol data-mm-list="perspectives|dimensions">. */
export function fillLists() {
  document.querySelectorAll("[data-mm-list]").forEach((ol) => {
    const items = ol.getAttribute("data-mm-list") === "perspectives" ? PERSPECTIVES : DIMENSIONS;
    ol.classList.add("mm-list-num");
    ol.innerHTML = items.map((d) => `<li id="${esc(d.key)}">
      <div class="mm-card-num">${d.n}</div>
      <h3>${esc(d.question || d.title)}</h3>
      ${d.question ? `<p class="mm-small" style="color:var(--mm-warm);font-weight:700;margin-bottom:var(--mm-space-1)">${esc(d.title)}</p>` : ""}
      <p>${esc(d.intro)}</p></li>`).join("");
  });
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", fillLists);
else fillLists();
