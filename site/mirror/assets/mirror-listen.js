// @ts-check
// The Human Mirror: open questions -> what we heard -> the Navigator's draft plan (D-21, option 1: phrase matching).
//
// Stephen 11/13/2026: guide the person with open-ended questions (spoken or typed, D-19), find the needs in their own
// words, and give the Navigator a preliminary plan of help connections from the CHPMS directory (D-11).
// Option 1 (chosen): phrase matching on our side. Free, nothing goes to another company, every flag shows the words
// that caused it. The person checks "what I heard" first; the Navigator confirms every suggestion.
//
//   QUESTIONS            the open questions (data; add or reword freely)
//   analyse(answers)     -> Finding[]  (needs, who the help is for, urgent signals), each with the person's own words
//   draftPlan(findings, directory)  -> Plan  (needs in order, with suggested programs from chpms_directory())
//
// Categories (HELP) and groups (POPS) are exactly the directory's (chpms_program_assist / chpms_program_pops), so
// a finding matches programs with no extra table. OTHER needs (food, jobs, ID...) are not in the housing directory yet.

/** @typedef {{ id: string, text: string, hint?: string, private?: boolean }} Question */
/** @typedef {{ kind: "help"|"pop"|"other"|"urgent", key: string, label: string, private: boolean, quotes: {q: string, words: string}[], urgent?: string }} Finding */

/** @type {Question[]} */
export const QUESTIONS = [
  { id: "home", text: "Tell me about where you are living or staying right now. How is it going?" },
  { id: "hardest", text: "What has been the hardest thing this month?" },
  { id: "money", text: "Tell me about money: what comes in each month, and from where? Which bills worry you most?" },
  { id: "people", text: "Who lives with you or depends on you? Who helps you?" },
  { id: "day", text: "How are you doing day to day: your health, sleep, food, getting around?", private: true },
  { id: "safety", text: "Is there anything about your safety, or about someone you live with, that worries you?", private: true,
    hint: "You can skip this one. Only you decide who sees it." },
  { id: "past", text: "Is there anything from the past that keeps getting in the way, like an eviction, a record, credit, or missing papers?", private: true },
  { id: "future", text: "If the next three months went well, what would be different?" },
];

// ------------------------------------------------------------------ the phrase list
// Each rule: words (regular expression, matched without regard to case), what it means, and options:
//   neg: true  = skip when "not", "no", "never"... comes just before (e.g. "I'm not behind on rent")
//   private: a private topic (D-14): hidden from the Navigator unless the person shares it
//   urgent: shown to the person at once with the crisis line, and first on the Navigator's plan
/** @typedef {{ re: RegExp, kind: Finding["kind"], key: string, label?: string, neg?: boolean, private?: boolean, urgent?: string }} Rule */

const R = (/** @type {string} */ s) => new RegExp(s, "gi");

export const URGENT = {
  tonight: { title: "No safe place to sleep tonight", help: "Call 2-1-1 (IMPACT 2-1-1, any time) for shelter tonight." },
  harm: { title: "Thoughts of hurting yourself", help: "Call or text 988 (Suicide and Crisis Lifeline), any time, free." },
  violence: { title: "Not safe at home", help: "National Domestic Violence Hotline: 1-800-799-7233, or text START to 88788. In danger now: call 911." },
};

/** @type {Rule[]} */
const RULES = [
  // urgent first
  { re: R(String.raw`\b(no ?where|no place|nowhere|no place)\b[^.!?]{0,25}\b(sleep|stay|go)\b[^.!?]{0,15}\btonight\b|\bsleep(ing)? (outside|in (my|the|a) car|on the street)[^.!?]{0,15}\btonight\b|\btonight\b[^.!?]{0,30}\b(outside|in (my|the|a) car|on the street|no ?where to (sleep|stay))`),
    kind: "urgent", key: "tonight", urgent: "tonight" },
  { re: R(String.raw`\b(kill (my ?self|myself)|end (it all|my life)|suicid\w*|(don'?t|do not) want to (live|be here)( anymore)?|hurt(ing)? myself)\b`),
    kind: "urgent", key: "harm", urgent: "harm", private: true },
  { re: R(String.raw`\b((he|she|they) (hit|hits|beat|beats|choked?|hurts?|threaten\w*)|abus(e|ed|ive)|domestic violence|afraid (of (him|her|them)|to go home)|(don'?t|do not) feel safe|not safe (at home|there|with)|restraining order|protection order)\b`),
    kind: "urgent", key: "violence", urgent: "violence", private: true },

  // help the directory gives (chpms_program_assist categories)
  { re: R(String.raw`\b(evict(ed|ion|ing)?|(5|five|14|fourteen|28|twenty[- ]eight|30|thirty)[- ]day notice|pay or (quit|vacate)|landlord (is )?(taking me to court|filed|took me to court)|small claims|sheriff|writ)\b`),
    kind: "help", key: "Eviction prevention", neg: true },
  { re: R(String.raw`\b(behind (on|in|with) (the |my )?rent|owe[a-z]* [^.!?]{0,20}\brent|(can'?t|cannot|couldn'?t) (afford|pay|make|cover) (the |my )?rent|late (on|with) (the |my )?rent|back rent|past[- ]due rent|rent (is|was) (late|due))\b`),
    kind: "help", key: "Emergency rental assistance", neg: true },
  { re: R(String.raw`\b(rent is too (high|much)|(half|most) (of )?(my|the) (check|income|money) (goes )?(to|on) rent|can'?t keep up with (the )?rent|help (with|paying) (the |my )?rent every month)\b`),
    kind: "help", key: "Monthly rental assistance" },
  { re: R(String.raw`\b(security deposit|need (a|the) deposit|deposit (to move|for (an|a|the) (apartment|place|unit)))\b`),
    kind: "help", key: "Security deposit assistance", neg: true },
  { re: R(String.raw`\b(first month'?s rent|move[- ]in (money|costs?|fees?))\b`), kind: "help", key: "First month's rent" },
  { re: R(String.raw`\b(shut[- ]?off|disconnect(ion)? notice|(gas|light|lights|electric|water|heat|energy|utility) bill|we energies|(lights?|power|gas|heat|water) (got |was |were |is )?(cut|turned|shut) off|no heat)\b`),
    kind: "help", key: "Utility assistance", neg: true },
  { re: R(String.raw`\b(moving (truck|costs?|help)|help moving|u-?haul|(have|got) to (move|be out)( out)? by)\b`), kind: "help", key: "Moving expenses" },
  { re: R(String.raw`\b(no (bed|beds|furniture|mattress|couch)|sleep(ing)? on the floor|need (a )?(bed|beds|furniture|couch|table|dishes|pots)|nothing in (the|my) (apartment|place))\b`),
    kind: "help", key: "Furniture and household items" },
  { re: R(String.raw`\b(sleep(ing)? in (my|a|the) car|living in (my|a|the) car|on the street|homeless|in a shelter|at the shelter|couch[- ]?surf\w*|staying (with|at) (a |my )?(friend|cousin|sister|brother|aunt|uncle|mom|mother|dad|grandma|family)\w*|no ?where to (stay|go|live)|no place to (stay|go|live)|kicked (me )?out|in a tent)\b`),
    kind: "help", key: "Rapid rehousing" },
  { re: R(String.raw`\b(section 8|voucher|housing choice|hacm|public housing|housing authority|housing (wait|waiting) ?list)\b`), kind: "help", key: "Housing vouchers" },
  { re: R(String.raw`\b(supportive housing|need (some )?help living on my own|(group|sober|recovery) (home|house|living))\b`), kind: "help", key: "Supportive housing" },
  { re: R(String.raw`\b(a place of (my|our) own|my own place|our own place|somewhere (permanent|stable)|stable (place|home|housing)|long[- ]term (place|housing))\b`),
    kind: "help", key: "Permanent housing" },
  { re: R(String.raw`\b(transitional (housing|living)|halfway house|somewhere to stay (for now|until))\b`), kind: "help", key: "Transitional housing" },
  { re: R(String.raw`\b((don'?t|do not) know where to start|need someone to help me|overwhelmed|case ?worker|case manager|so much going on)\b`), kind: "help", key: "Case management" },
  { re: R(String.raw`\b(find(ing)? (an? )?(apartment|place|house|housing|home)|looking for (an? )?(apartment|place|house|housing|home)|(applications?|apps) (keep )?(get(ting)? )?(denied|turned down)|(bad|no|poor) credit|credit is (bad|poor|shot)|eviction (filing|case )?(is )?on my record|eviction filing|landlords? (won'?t|keep) (rent|taking|accept))\b`),
    kind: "help", key: "Housing navigation" },
  { re: R(String.raw`\b(landlord (won'?t|isn'?t|refuses to|never) (fix|repair|answer|call|respond)|problem with (my |the )?landlord|landlord (is )?(harass\w*|threaten\w*)|repairs? (not|never) (done|fixed|made)|mold|roaches|bed ?bugs|mice)\b`),
    kind: "help", key: "Landlord mediation" },
  { re: R(String.raw`\b(budget|debt|collections?|credit score|bills (are )?pil(e|ing)|payday loan|title loan|save money|saving money)\b`), kind: "help", key: "Financial counseling" },
  { re: R(String.raw`\b((apply(ing)? for|need|lost|losing|cut off|denied|don'?t have|no)\b[^.!?]{0,20}\b(food ?stamps|snap|food ?share|ssi|ssdi|disability (check|benefits)|medicaid|badger ?care|w-?2|unemployment|benefits)|apply for benefits)\b`),
    kind: "help", key: "Benefits enrollment" },

  // who the help is for (chpms_program_pops)
  { re: R(String.raw`\b(veteran|vet\b|served in the (army|navy|marines?|air force|coast guard|military)|the va\b|va (benefits|check|hospital|pension))`), kind: "pop", key: "Veterans" },
  { re: R(String.raw`\b((6[2-9]|[7-9]\d) (years old|yrs old)|i'?m (6[2-9]|[7-9]\d)\b|senior|retired)\b`), kind: "pop", key: "Seniors" },
  { re: R(String.raw`\b(ssi|ssdi|social security|disability check|va (check|pension)|fixed income|pension)\b`), kind: "pop", key: "Fixed income (SS/SSI/SSDI/VA)" },
  { re: R(String.raw`\b(my (kids?|children|son|daughter|baby|babies|grandkids?)|(\d|one|two|three|four|five|six) (kids|children)|pregnant|custody)\b`), kind: "pop", key: "Families with children" },
  { re: R(String.raw`\b(sleep(ing)? in (my|a|the) car|on the street|homeless|in a shelter|at the shelter|couch[- ]?surf\w*|staying (with|at) (a |my )?(friend|cousin|sister|brother|aunt|uncle|mom|mother|dad|grandma|family)\w*|no ?where to (stay|go|live)|no place to (stay|go|live)|kicked (me )?out)\b`),
    kind: "pop", key: "Experiencing homelessness" },
  { re: R(String.raw`\b(evict(ed|ion|ing)?|(5|five|14|fourteen|28|30)[- ]day notice|pay or (quit|vacate)|behind (on|in|with) (the |my )?rent|(have|got) to (move|be out)( out)? by)\b`),
    kind: "pop", key: "At risk of eviction", neg: true },
  { re: R(String.raw`\b(disab(led|ility)|wheelchair|walker|can'?t (walk|climb|do) (the )?stairs|chronic (pain|illness)|blind|deaf|ssdi)\b`), kind: "pop", key: "Disabilities" },
  { re: R(String.raw`\b((got|get|getting|just got) out (of )?(prison|jail|doc|the joint)|released from|incarcerat\w*|probation|parole|my record|a record|felony|conviction)\b`),
    kind: "pop", key: "Returning citizens", private: true },
  { re: R(String.raw`\b(i work (at|for|as|in|part|full)|my job|(part|full)[- ]time|hours (got |were )?cut|paycheck|minimum wage|warehouse|second shift|third shift)\b`), kind: "pop", key: "Low-income working" },
  { re: R(String.raw`\b(no (income|job|money coming in)|(lost|lose) my job|unemployed|laid off|got fired|(don'?t|do not) (have|get) any (money|income))\b`), kind: "pop", key: "No current income" },

  // needs outside the housing directory (a Navigator adds the connection by hand for now)
  { re: R(String.raw`\b(hungry|food pantry|no food|groceries|(can'?t|cannot) (afford|buy) food|skip(ping)? meals)\b`), kind: "other", key: "food", label: "Food" },
  { re: R(String.raw`\b(no (car|ride|transportation)|bus (pass|fare)|need a ride|car (broke|broken|died)|getting around is hard)\b`), kind: "other", key: "transport", label: "Getting around (transportation)" },
  { re: R(String.raw`\b(need a job|looking for (a )?(job|work)|job training|resume|get (a )?job|find work)\b`), kind: "other", key: "work", label: "Work and job training" },
  { re: R(String.raw`\b(child ?care|day ?care|babysitter|someone to watch (my|the) (kids|children|baby))\b`), kind: "other", key: "childcare", label: "Child care" },
  { re: R(String.raw`\b(no phone|phone (got |was )?(cut|shut) off|need a phone|no internet|no wifi)\b`), kind: "other", key: "phone", label: "Phone and internet" },
  { re: R(String.raw`\b(doctor|clinic|medication|meds|prescription|insurance|sick|surgery|diabetes|high blood pressure|asthma|dentist)\b`), kind: "other", key: "health", label: "Health care", private: true },
  { re: R(String.raw`\b(depress\w*|anxiety|mental health|ptsd|panic|stress(ed)?|can'?t sleep|counsel(ing|or)|therap(y|ist))\b`), kind: "other", key: "mental", label: "Mental health and stress", private: true },
  { re: R(String.raw`\b(drinking|drugs|using again|relapse|sober|recovery|addiction|aoda)\b`), kind: "other", key: "recovery", label: "Recovery support", private: true },
  { re: R(String.raw`\b(no (state )?id|lost my (id|wallet|papers)|birth certificate|social security card|driver'?s license (is )?(suspended|revoked)|no license)\b`), kind: "other", key: "id", label: "ID and documents", private: true },
  { re: R(String.raw`\b(court date|lawyer|attorney|warrant|tickets?|fines?|child support)\b`), kind: "other", key: "legal", label: "Legal matters", private: true },
  { re: R(String.raw`\b(immigration|visa|green card|undocumented|deport\w*|citizenship)\b`), kind: "other", key: "immigration", label: "Immigration", private: true },
];

const NEG = /\b(not|no|never|isn'?t|aren'?t|wasn'?t|haven'?t|hasn'?t|didn'?t|don'?t|ain'?t)\b[^.!?,]{0,18}$/i;

// ------------------------------------------------------------------ what each finding means (T1.6)
// The same list as the database table mirror.listen_keys (migration 20261119360000): kind:key -> label, area of life, privacy topic.
// A finding is private when its topic is not "general" (D-14); a finding with an area of life can become a need (Phase 6).
/** @typedef {{ label: string, dimension: string|null, category: string }} Meaning */
/** @type {Record<string, Meaning>} */
export const MEANINGS = {};
const M = (/** @type {string} */ kind, /** @type {string} */ key, /** @type {string} */ label, /** @type {string|null} */ dimension, category = "general") => {
  MEANINGS[kind + ":" + key] = { label, dimension, category };
};
M("urgent", "tonight", "No safe place to sleep tonight", "housing"); M("urgent", "harm", "Thoughts of hurting yourself", "mental_health", "mental_health");
M("urgent", "violence", "Not safe at home", "safety", "safety");
["Eviction prevention", "Emergency rental assistance", "Monthly rental assistance", "Security deposit assistance", "First month's rent", "Utility assistance",
  "Moving expenses", "Furniture and household items", "Rapid rehousing", "Housing vouchers", "Supportive housing", "Permanent housing",
  "Transitional housing", "Housing navigation", "Landlord mediation"].forEach((k) => M("help", k, k, "housing"));
M("help", "Case management", "Case management", "life_skills");
M("help", "Financial counseling", "Financial counseling", "finances", "financial"); M("help", "Benefits enrollment", "Benefits enrollment", "finances", "financial");
M("other", "food", "Food", "food"); M("other", "transport", "Getting around (transportation)", "transportation"); M("other", "work", "Work and job training", "work");
M("other", "childcare", "Child care", "relationships"); M("other", "phone", "Phone and internet", "technology");
M("other", "health", "Health care", "physical_health", "health"); M("other", "mental", "Mental health and stress", "mental_health", "mental_health");
M("other", "recovery", "Recovery support", "mental_health", "mental_health"); M("other", "id", "ID and documents", "identity_legal", "legal");
M("other", "legal", "Legal matters", "identity_legal", "legal"); M("other", "immigration", "Immigration", "identity_legal", "immigration");
["Veterans", "Seniors", "Fixed income (SS/SSI/SSDI/VA)", "Families with children", "Experiencing homelessness", "At risk of eviction", "Disabilities",
  "Low-income working", "No current income"].forEach((k) => M("pop", k, k, null));
M("pop", "Returning citizens", "Returning citizens", null, "legal");

/** Words a Navigator added because the list missed them: plain words, matched as whole words (spaces match any spacing). */
/** @param {{ phrase: string, kind: Finding["kind"], key: string }[]} phrases @returns {Rule[]} */
function phraseRules(phrases) {
  return (phrases || []).filter((p) => MEANINGS[p.kind + ":" + p.key] && /^[a-z0-9][a-z0-9' -]*[a-z0-9]$/i.test(p.phrase || "")).map((p) => ({
    re: new RegExp("\\b" + p.phrase.trim().replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\s+/g, "\\s+") + "\\b", "gi"),
    kind: p.kind, key: p.key, urgent: p.kind === "urgent" ? p.key : undefined,
  }));
}

/** The sentence around a match, trimmed, so the Navigator sees the person's own words. */
function sentence(/** @type {string} */ text, /** @type {number} */ at, /** @type {number} */ len) {
  let s = at, e = at + len;
  while (s > 0 && !/[.!?\n]/.test(text[s - 1])) s--;
  while (e < text.length && !/[.!?\n]/.test(text[e])) e++;
  let out = text.slice(s, Math.min(e + 1, text.length)).trim();
  if (out.length > 220) out = (at - s > 100 ? "…" : "") + text.slice(Math.max(s, at - 100), Math.min(e, at + len + 100)).trim() + "…";
  return out;
}

/**
 * Finds needs, groups and urgent signals in the answers.
 * @param {Record<string, string>} answers question id -> what the person said
 * @param {{ phrase: string, kind: Finding["kind"], key: string }[]} [phrases] words added by the person's organizations (T1.6)
 * @returns {Finding[]}
 */
export function analyse(answers, phrases = []) {
  /** @type {Map<string, Finding>} */
  const found = new Map();
  const rules = RULES.concat(phraseRules(phrases));
  for (const q of QUESTIONS) {
    const text = (answers[q.id] || "").trim();
    if (!text) continue;
    for (const rule of rules) {
      rule.re.lastIndex = 0;
      let m;
      while ((m = rule.re.exec(text))) {
        if (rule.neg && NEG.test(text.slice(Math.max(0, m.index - 30), m.index))) continue;
        const id = rule.kind + ":" + rule.key;
        let f = found.get(id);
        if (!f) {
          const meaning = MEANINGS[id];
          f = { kind: rule.kind, key: rule.key, label: meaning ? meaning.label : (rule.label || rule.key),
            private: meaning ? meaning.category !== "general" : !!rule.private, quotes: [], urgent: rule.urgent };
          found.set(id, f);
        }
        const words = sentence(text, m.index, m[0].length);
        if (!f.quotes.some((x) => x.words === words) && f.quotes.length < 3) f.quotes.push({ q: q.id, words });
        if (m[0].length === 0) rule.re.lastIndex++;
      }
    }
  }
  const order = { urgent: 0, help: 1, other: 2, pop: 3 };
  return [...found.values()].sort((a, b) => order[a.kind] - order[b.kind]);
}

/** Urgent signals in one piece of text (used while the person is still answering). @param {string} text */
export function urgentIn(text) {
  return analyse({ home: text }).filter((f) => f.kind === "urgent").map((f) => /** @type {string} */ (f.urgent));
}

// ------------------------------------------------------------------ the draft plan

/** Which needs come first on the plan. */
const PRIORITY = ["Eviction prevention", "Rapid rehousing", "Emergency rental assistance", "Utility assistance", "Transitional housing",
  "Security deposit assistance", "First month's rent", "Housing navigation", "Housing vouchers", "Supportive housing", "Permanent housing",
  "Monthly rental assistance", "Landlord mediation", "Moving expenses", "Furniture and household items", "Benefits enrollment",
  "Financial counseling", "Case management"];

/**
 * @param {Finding[]} shared the findings the person chose to share
 * @param {any} directory the result of chpms_directory(), or null when not signed in
 */
export function draftPlan(shared, directory) {
  const pops = shared.filter((f) => f.kind === "pop").map((f) => f.key);
  const needs = shared.filter((f) => f.kind === "help").sort((a, b) => PRIORITY.indexOf(a.key) - PRIORITY.indexOf(b.key));
  /** @type {any[]} */
  const programs = [];
  if (directory) for (const o of directory.orgs || []) {
    if (o.our_relationship === "do_not_refer") continue;
    for (const p of o.programs || []) {
      if (/inactive|expired/i.test(p.verification_status || "") || /^(closed|ended)/i.test(p.current_status || "")) continue;
      programs.push({ ...p, org: o });
    }
  }
  // Programs written for one group only (from their name and eligibility text): left out when the person did not say
  // they are in that group; youth programs are moved down instead (age is rarely said out loud).
  const has = new Set([...pops, ...shared.filter((f) => f.kind === "urgent").map((f) => String(f.urgent))]);
  const ONLY = /** @type {[RegExp, string][]} */ ([
    [/\bveteran/i, "Veterans"], [/\b(senior|elderly|aged? (55|60|62|65)\+?|(55|60|62|65)\s*(\+|and older|or older))/i, "Seniors"],
    [/\b(re-?entry|returning citizens?|formerly incarcerated)/i, "Returning citizens"], [/\bHIV\b|\bAIDS\b/, "hiv"],
    [/\b(domestic (violence|abuse)|survivors? of|DV survivors?|fleeing violence)/i, "violence"],
  ]);
  const youth = /\b1[6-8]\s*[–-]\s*2[0-9]\b|\b(youth|young adults?)\b/i;
  const shown = new Map();   // program id -> times already suggested for an earlier need
  const steps = needs.map((n) => {
    const list = programs.filter((p) => (p.assist || []).includes(n.key)).flatMap((p) => {
      const words = (p.program_name || "") + " " + (p.eligibility_summary || "");
      if (ONLY.some(([re, tag]) => re.test(words) && !has.has(tag))) return [];
      const popHits = (p.pops || []).filter((/** @type {string} */ x) => pops.includes(x));
      const otherHelp = needs.filter((m) => m !== n && (p.assist || []).includes(m.key)).length;
      const score = popHits.length * 3 + otherHelp * 2 + (p.org.our_relationship === "partner" ? 4 : 0)
        + (/^Verified/.test(p.verification_status || "") ? 2 : 0) + (p.org.is_local ? 1 : 0) + ((p.pops || []).length === 0 ? 1 : 0)
        - (youth.test(words) ? 6 : 0) - (shown.get(p.program_id) || 0) * 4;
      return [{ p, popHits, score }];
    }).sort((a, b) => b.score - a.score);
    const top = list.slice(0, 3);
    top.forEach((x) => shown.set(x.p.program_id, (shown.get(x.p.program_id) || 0) + 1));
    return { need: n, suggestions: top, more: Math.max(0, list.length - 3) };
  });
  return {
    urgent: shared.filter((f) => f.kind === "urgent"),
    steps,
    other: shared.filter((f) => f.kind === "other"),
    pops,
  };
}
