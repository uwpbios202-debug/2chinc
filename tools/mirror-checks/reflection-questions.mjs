// The Human Mirror T3.3: questions for the 8 reflections, as data. Source: Stephen's "Mirror 2" email (Today, History, Vision,
// Assets, Needs, Contribution question lists) and the prompt (Parts 2 and 5: Function, Preferences). Plain words, every question
// optional (the page always offers I don't know / Doesn't apply / Prefer not to say / I'd like help). Function is never a diagnosis.
//
// Generates the migration:  node tools/mirror-checks/reflection-questions.mjs > supabase/migrations/<version>_mirror_reflection_questions.sql
// Editing a question later: change it here and generate a NEW migration (answers already given stay with the old wording's id).

const opt = (pairs) => pairs.map(([value, label]) => ({ value, label }));
const DIMENSION_OPTIONS = opt([
  ["housing", "A place to live"], ["physical_health", "Physical health"], ["mental_health", "How I feel inside"],
  ["identity_legal", "ID, papers or legal matters"], ["food", "Food and basic needs"], ["transportation", "Getting around"],
  ["technology", "Phone, internet, computers"], ["work", "School, work or career"], ["finances", "Money"],
  ["self_care", "Clothes, hygiene, self-care"], ["relationships", "Family, friends, community"], ["life_skills", "Everyday life skills"],
  ["safety", "Feeling safe"], ["development", "Interests and fun"], ["purpose", "Purpose and the future"],
]);
const DO_IT = opt([["on_my_own", "I do this on my own"], ["with_some_help", "I do it with a little help"], ["want_help", "I'd like help with this"], ["not_for_me", "This doesn't apply to me"]]);
const RATING_HELP = "1 means very hard. 5 means very good.";

/** [set, key, type, prompt, help, options, category] */
const Q = [
  // 1 IDENTITY: Who am I today?
  ["identity", "about_me", "long_text", "Tell me a little about yourself. Who are you today?", "Anything you'd like to share: where you're from, what matters to you, what you'd like people to know."],
  ["identity", "living_now", "choice", "Where are you staying right now?", null, opt([["own_place", "My own place"], ["with_others", "With family or friends"], ["shelter", "A shelter"], ["program", "A program, treatment or care setting"], ["outside", "Outside, in a car, or somewhere not meant for living"], ["other", "Somewhere else"]])],
  ["identity", "living_how", "long_text", "How is it going where you're staying?"],
  ["identity", "have", "long_text", "What do you have right now that helps you get by?", "People, things, skills, places, anything."],
  ["identity", "missing", "long_text", "What don't you have right now that you need?"],
  ["identity", "health_now", "rating", "How is your physical health these days?", RATING_HELP, null, "health"],
  ["identity", "feeling_now", "rating", "How are you feeling inside these days?", RATING_HELP, null, "mental_health"],
  ["identity", "money_now", "rating", "How are things with money right now?", RATING_HELP, null, "financial"],
  ["identity", "responsibilities", "long_text", "What are you responsible for right now?", "For example children, a job, caring for someone, a pet, appointments."],
  ["identity", "ordinary_day", "long_text", "What does an ordinary day look like for you?"],
  ["identity", "happy", "long_text", "What makes you happy?"],
  ["identity", "unhappy", "long_text", "What makes you unhappy?"],
  ["identity", "afraid", "long_text", "Is there anything you are afraid of?", "Only if you want to say.", null, "mental_health"],
  ["identity", "proud", "long_text", "What are you proud of?"],

  // 2 HISTORY: Who have I been?
  ["history", "from", "long_text", "Where did you grow up, and where have you lived since?"],
  ["history", "growing_up", "long_text", "What was growing up like for you?"],
  ["history", "shaped", "long_text", "What experiences shaped who you are?"],
  ["history", "accomplished", "long_text", "What have you done that you're glad about?"],
  ["history", "schooling", "choice", "How far did you go in school?", null, opt([["grade_school", "Grade school"], ["some_high_school", "Some high school"], ["high_school", "High school diploma or GED"], ["some_college", "Some college or training"], ["certificate", "A trade certificate or license"], ["degree", "A college degree"]])],
  ["history", "learned", "long_text", "What have you learned along the way?"],
  ["history", "differently", "long_text", "Looking back, is there anything you would do differently?", "Only if you want to. The past explains the journey; it does not decide the future."],
  ["history", "got_through", "long_text", "What hard things have you gotten through?"],
  ["history", "missed", "long_text", "Were there chances you missed that you still think about?"],
  ["history", "people", "long_text", "Who has made a difference in your life?"],
  ["history", "talents", "long_text", "What talents or skills have you built over the years?"],
  ["history", "old_dreams", "long_text", "What dreams did you once have?"],
  ["history", "leave_behind", "long_text", "What parts of your past would you like to leave behind?"],

  // 3 VISION: Who do I want to become?
  ["vision", "person", "long_text", "What kind of person do you want to be?", "This is your vision, in your words."],
  ["vision", "one_year", "long_text", "A year from now, what would you like to be different?"],
  ["vision", "where_live", "long_text", "Where would you like to live?"],
  ["vision", "home", "long_text", "What kind of home would you like?"],
  ["vision", "work", "long_text", "What would you like to do for a living?"],
  ["vision", "income", "money", "About how much would you like to earn in a month?", "A rough number is fine.", null, "financial"],
  ["vision", "learn", "long_text", "What would you like to learn?"],
  ["vision", "own", "long_text", "What would you like to own one day?"],
  ["vision", "health", "long_text", "What would you like your health to be like?", null, null, "health"],
  ["vision", "relationships", "long_text", "What relationships would you like to have?"],
  ["vision", "experiences", "long_text", "What would you like to experience or enjoy?"],
  ["vision", "fulfilled", "long_text", "What would make you feel fulfilled?"],
  ["vision", "proud_five_years", "long_text", "What would make you proud of yourself five years from now?"],

  // 4 ASSETS: What do I have within me?
  ["assets", "good_at", "long_text", "What are you naturally good at?"],
  ["assets", "can_do", "multi", "Which of these can you do?", "Choose all that fit.", opt([["cooking", "Cooking"], ["cleaning", "Cleaning"], ["childcare", "Caring for children"], ["eldercare", "Caring for older or sick people"], ["driving", "Driving"], ["repairs", "Fixing things"], ["construction", "Building or construction work"], ["computers", "Using computers"], ["customer_service", "Sales or customer service"], ["managing", "Leading or managing people"], ["money", "Stretching money and budgeting"], ["arts", "Art, music or writing"], ["sewing", "Sewing or crafts"], ["gardening", "Gardening"], ["teaching", "Teaching or coaching"], ["languages", "Speaking more than one language"]])],
  ["assets", "more_skills", "long_text", "What other skills do you have?"],
  ["assets", "appreciate", "long_text", "What do people appreciate about you?"],
  ["assets", "know", "long_text", "What do you know a lot about?"],
  ["assets", "teach", "long_text", "What could you teach someone else?"],
  ["assets", "interests", "long_text", "What interests or excites you?"],
  ["assets", "keeps_going", "long_text", "What keeps you going?"],
  ["assets", "strengths", "long_text", "What strengths have helped you get through hard times?"],
  ["assets", "languages", "text", "What languages do you speak?"],
  ["assets", "experience_to_skill", "long_text", "What life experience could become a work skill?", "For example raising children, caring for a relative, running a household, or making money stretch."],
  ["assets", "become_good_at", "long_text", "What would you like to become good at?"],

  // 5 NEEDS: What must change, and what do I need?
  ["needs", "help_areas", "multi", "Which parts of life would you like help with?", "Choose all that fit. You can change this any time.", DIMENSION_OPTIONS],
  ["needs", "in_the_way", "long_text", "What is getting in the way of the life you want?"],
  ["needs", "first", "long_text", "What should come first?"],
  ["needs", "missing_resources", "long_text", "What things or resources are you missing?"],
  ["needs", "know_more", "long_text", "What would you like to know more about?"],
  ["needs", "skills", "long_text", "What skills would you like to build?"],
  ["needs", "opportunities", "long_text", "What opportunities would help you most?"],
  ["needs", "support", "long_text", "What kind of support, or which people, would help you?"],
  ["needs", "must_change", "long_text", "What needs to change in your life right now?"],
  ["needs", "work_toward", "long_text", "What are you willing to work toward?"],
  ["needs", "someones_help", "long_text", "Where would you like someone else's help?"],

  // 6 FUNCTION: What can I do now, and where might I want support? (never a diagnosis; the full assessment is Phase 5)
  ["function", "meals", "choice", "Making meals", null, DO_IT],
  ["function", "shopping", "choice", "Shopping for food and the things I need", null, DO_IT],
  ["function", "medicine", "choice", "Keeping track of medicine", null, DO_IT, "health"],
  ["function", "bills", "choice", "Paying bills and keeping track of money", null, DO_IT, "financial"],
  ["function", "getting_around", "choice", "Getting where I need to go", null, DO_IT],
  ["function", "housekeeping", "choice", "Keeping my home clean", null, DO_IT],
  ["function", "laundry", "choice", "Doing laundry", null, DO_IT],
  ["function", "phone", "choice", "Using a phone or computer", null, DO_IT],
  ["function", "paperwork", "choice", "Filling out forms and paperwork", null, DO_IT],
  ["function", "appointments", "choice", "Keeping appointments", null, DO_IT],
  ["function", "personal_care", "choice", "Bathing and getting dressed", null, DO_IT, "health"],
  ["function", "easier", "long_text", "Where would a little help make everyday life easier?", "This is about what would help you. It is never a diagnosis, and you decide what happens next."],

  // 7 PREFERENCES: How do I want to live?
  ["preferences", "live_with", "choice", "Who would you like to live with?", null, opt([["alone", "On my own"], ["children", "With my children"], ["partner", "With a partner"], ["family", "With family"], ["roommates", "With roommates"], ["shared_house", "In a shared house"], ["not_sure", "Not sure yet"]])],
  ["preferences", "area", "long_text", "Which neighborhood or area would you like to live in, and why?"],
  ["preferences", "close_to", "multi", "What would you like to live close to?", "Choose all that fit.", opt([["work", "Work"], ["school", "My children's school"], ["family", "Family"], ["bus", "A bus line"], ["grocery", "A grocery store"], ["clinic", "A doctor or clinic"], ["worship", "A place of worship"], ["park", "A park"], ["community", "My community"]])],
  ["preferences", "home_matters", "multi", "What matters most in a home?", "Choose all that fit.", opt([["safety", "Feeling safe"], ["quiet", "Quiet"], ["space", "Space for children"], ["no_stairs", "No stairs, or a ground floor"], ["wheelchair", "Room for a wheelchair or walker"], ["own_bathroom", "My own bathroom"], ["laundry", "Laundry in the building"], ["parking", "Parking"], ["pets", "Pets allowed"]])],
  ["preferences", "pet", "yes_no", "Do you have a pet, or want one?"],
  ["preferences", "support_at_home", "choice", "How much support would you like where you live?", "There is no wrong answer. You choose.", opt([["none", "None: I want to live on my own"], ["check_in", "A little: someone to check in now and then"], ["some_tasks", "Regular help with some everyday tasks"], ["not_sure", "Not sure yet"]])],
  ["preferences", "contact", "choice", "How do you like to be contacted?", null, opt([["text", "Text message"], ["call", "Phone call"], ["email", "Email"], ["in_person", "In person"]])],
  ["preferences", "language", "text", "What language would you like us to use with you?"],
  ["preferences", "culture", "long_text", "Is there anything about your culture, faith or way of life you'd like respected?"],
  ["preferences", "choices", "long_text", "What choices matter most to you about how you live?"],

  // 8 CONTRIBUTION: Who can I help, and what can I give back?
  ["contribution", "already", "long_text", "How do you already help others?", "Raising a family, caring for someone, or helping a neighbor all count."],
  ["contribution", "community", "long_text", "How would you like to contribute to your community?"],
  ["contribution", "problems", "long_text", "What problems in the world would you like to help solve?"],
  ["contribution", "help_who", "long_text", "Who would you like to help?"],
  ["contribution", "share", "long_text", "What knowledge could you share?"],
  ["contribution", "teach", "long_text", "What could you teach?"],
  ["contribution", "experiences", "long_text", "How could your experiences help someone else?"],
  ["contribution", "remembered", "long_text", "What would you like people to remember about you?"],
  ["contribution", "legacy", "long_text", "What kind of legacy would you like to leave?"],
];

const lit = (s) => (s == null ? "null" : "'" + String(s).replace(/'/g, "''") + "'");
const counters = {};
const rows = Q.map(([set, key, type, prompt, help = null, options = null, category = "general"]) => {
  counters[set] = (counters[set] || 0) + 1;
  return `  (${lit("reflection_" + set)}, ${lit(key)}, ${lit(prompt)}, ${lit(help)}, ${lit(type)}, ${lit(JSON.stringify(options || []))}::jsonb, ${lit(category)}, ${counters[set] * 10})`;
});

console.log(`-- The Human Mirror T3.3: questions for the 8 reflections (${Q.length} questions). GENERATED by
-- tools/mirror-checks/reflection-questions.mjs (edit there, never by hand). Source: Stephen's Mirror 2 email and the prompt (Parts 2, 5).
-- Every question is optional; private ones carry their category (health, mental_health, financial), so only the person and those
-- they share that topic with see the answers (D-14). Function is a light self-view, never a diagnosis (prompt Part 5).
-- Counts per reflection: ${Object.entries(counters).map(([k, v]) => k + " " + v).join(", ")}.

insert into mirror.reflection_questions (set_id, key, prompt, help, answer_type, options, category, sort)
select s.id, v.key, v.prompt, v.help, v.answer_type, v.options, v.category, v.sort
from (values
${rows.join(",\n")}
) v(set_key, key, prompt, help, answer_type, options, category, sort)
join mirror.question_sets s on s.key = v.set_key
on conflict (set_id, key) do nothing;`);
