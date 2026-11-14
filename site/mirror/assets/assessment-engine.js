// @ts-check
// The Human Mirror T3.2: one engine that shows ANY question set (reflections now; life areas, functional and modules later).
// Questions are data (mirror_set_get); answers go through mirror_answer_save, which checks permission and keeps old answers.
//
//   runSet(el, setKey, { individual, onDone, nextLink })
//
// Phone first: one question per screen, big tap targets, Speak on every text box (mirror-voice.js), Read aloud on every question.
// Save and return: each answer saves when the person moves on; opening the set again starts at the first unanswered question.
// Every question can be skipped or answered "I don't know", "Doesn't apply", "Prefer not to say" or "I'd like help with this".
// Offline-tolerant: a save that fails for lack of connection is retried when the device is back online (kept in this tab only;
// answers are never written to the device's storage).

import { rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice, countBar, toast } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { voiceAll, readAll, canRecognize, voicePermission, hear, speak, stopSpeaking } from "/mirror/assets/mirror-voice.js?v=20261113c";

// ---------------------------------------------------------------- hands-free: spoken words -> an answer
const HF_KEY = "mm-handsfree";   // per-device convenience only
const hfStored = () => { try { return localStorage.getItem(HF_KEY) === "on"; } catch { return false; } };
const hfStore = (/** @type {boolean} */ on) => { try { localStorage.setItem(HF_KEY, on ? "on" : "off"); } catch { /* blocked */ } };
const norm = (/** @type {string} */ s) => s.toLowerCase().replace(/[’']/g, "'").replace(/[^a-z0-9' ]+/g, " ").replace(/\s+/g, " ").trim();
const STOP = new Set(["the", "and", "for", "with", "a", "an", "or", "of", "to", "my", "i", "it", "in", "on", "at", "me", "do", "this", "that", "is", "be"]);

/** A spoken command (short utterances only). @param {string} t @returns {string} */
function spokenCommand(t) {
  const n = norm(t), words = n.split(" ").length;
  if (/^(skip|next|next question|pass|skip (this|it|that)( one)?)$/.test(n)) return "skip";
  if (/^(go back|back|previous( question)?)$/.test(n)) return "back";
  if (/^(stop|pause|stop listening|hands free off)$/.test(n)) return "stop";
  if (words <= 6) {
    if (/\b(i don't know|not sure|no idea|don't know)\b/.test(n)) return "state:unknown";
    if (/\b(doesn't apply|does not apply|not applicable)\b/.test(n)) return "state:not_applicable";
    if (/\b(prefer not|rather not|don't want to say)\b/.test(n)) return "state:prefer_not";
    if (/\b(need help|like help|help me|want help)\b/.test(n)) return "state:needs_help";
  }
  return "";
}

/** Which options were said. @param {string} t @param {{value:string,label:string}[]} options @param {boolean} many */
function matchOptions(t, options, many) {
  const said = " " + norm(t) + " ";
  const scored = options.map((o) => {
    const ws = norm(o.label).split(" ").filter((w) => w.length > 2 && !STOP.has(w));
    const hits = ws.filter((w) => said.includes(" " + w + " ") || said.includes(" " + w.replace(/s$/, "") + " ")).length;
    return { o, score: ws.length ? hits / ws.length : 0, hits };
  }).filter((x) => x.hits > 0);
  if (many) return scored.filter((x) => x.score >= 0.5 || x.hits >= 2).map((x) => x.o.value);
  scored.sort((a, b) => b.score - a.score || b.hits - a.hits);
  return scored.length ? [scored[0].o.value] : [];
}

/** @param {string} t @returns {number|null} */
function spokenRating(t) {
  const n = norm(t);
  const num = { one: 1, two: 2, three: 3, four: 4, five: 5, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5 };
  const m = n.match(/\b(one|two|three|four|five|[1-5])\b/);
  if (m) return num[/** @type {keyof typeof num} */ (m[1])];
  if (/very hard|really hard|terrible|awful/.test(n)) return 1;
  if (/very good|great|excellent/.test(n)) return 5;
  if (/\bhard\b|bad|not good/.test(n)) return 2;
  if (/\bgood\b/.test(n)) return 4;
  if (/okay|ok|alright|fine|so so/.test(n)) return 3;
  return null;
}

/** @param {string} t @returns {boolean|null} */
function spokenYesNo(t) {
  const n = norm(t);
  if (/^(yes|yeah|yep|yup|sure|i do|correct|right)\b/.test(n)) return true;
  if (/^(no|nope|not really|i don't|nah)\b/.test(n)) return false;
  return null;
}

/** What to say after the question for choice-type questions. @param {any} q */
function choicesToSay(q) {
  if (q.answer_type === "yes_no") return "Say yes or no.";
  if (q.answer_type === "rating") return "Say a number from 1 to 5. 1 is very hard, 5 is very good.";
  if (!["choice", "multi"].includes(q.answer_type)) return "";
  const intro = q.answer_type === "multi" ? "You can name more than one." : "";
  return q.options.length <= 6 ? `${intro} Choices: ${q.options.map((/** @type {any} */ o) => o.label).join("; ")}.` : `${intro} Choose from the list on the screen, or say one.`;
}

/** @typedef {{ id: string, key: string, prompt: string, help: string|null, answer_type: string, options: {value: string, label: string}[],
 *   category: string, private: boolean, hidden: boolean, can_edit: boolean, version?: number,
 *   answer: { value: any, state: string, note: string|null, by: string, at: string, version?: number, reworded?: boolean } | null }} Question */

/** P3-06b: an answer given to an earlier wording of its question says so (the wording itself is in "Earlier answers"). */
const REWORDED_NOTE = "This question was worded differently when you answered it. Your earlier answers show the wording you saw. Check that your answer still fits.";

const STATES = [
  ["unknown", "I don't know"],
  ["not_applicable", "Doesn't apply to me"],
  ["prefer_not", "Prefer not to say"],
  ["needs_help", "I'd like help with this"],
];
const STATE_LABEL = Object.fromEntries(STATES);
const RATING = ["1 Very hard", "2 Hard", "3 Okay", "4 Good", "5 Very good"];
/** Shown on every "how you feel inside" question (category mental_health). Saving an answer alerts nobody, so help is named here. */
const CRISIS_LINE = `<p class="mm-small" style="margin:var(--mm-space-2) 0">Having a hard time, or thinking about hurting yourself?
  Call or text <a href="tel:988">988</a> (Suicide and Crisis Lifeline), any time, free. In danger now: call <a href="tel:911">911</a>.
  Your answers here are not watched by anyone, so please reach out directly.</p>`;

/** Saves waiting for a connection (this tab only). @type {Map<string, () => Promise<void>>} */
const pending = new Map();
let retrying = false;
async function flushPending() {
  if (retrying || !pending.size) return;
  retrying = true;
  for (const [k, fn] of [...pending]) {
    try { await fn(); pending.delete(k); } catch { break; }
  }
  retrying = false;
  if (!pending.size) toast("Your answers are saved.");
}
addEventListener("online", flushPending);
addEventListener("beforeunload", (e) => { if (pending.size) { e.preventDefault(); e.returnValue = ""; } });

const offline = (/** @type {unknown} */ e) => !navigator.onLine || /fetch|network|Failed to fetch|did not answer/i.test(String(e instanceof Error ? e.message : e));

/** Text shown for a saved answer (list view and history). @param {Question} q @param {{value:any,state:string}} a */
function answerText(q, a) {
  if (!a) return "";
  if (a.state !== "answered") return STATE_LABEL[a.state] || a.state;
  const label = (/** @type {string} */ v) => (q.options.find((o) => o.value === v) || { label: v }).label;
  switch (q.answer_type) {
    case "choice": return label(a.value);
    case "multi": return (a.value || []).map(label).join(", ");
    case "yes_no": return a.value ? "Yes" : "No";
    case "money": return Number(a.value).toLocaleString("en-US", { style: "currency", currency: "USD" });
    case "rating": return RATING[Number(a.value) - 1] || String(a.value);
    case "date": return new Date(a.value + "T12:00:00").toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" });
    default: return String(a.value);
  }
}

/**
 * @param {HTMLElement} el
 * @param {string} setKey
 * @param {{ individual?: string|null, onDone?: () => void, nextLink?: {href: string, label: string}|null }} [opts]
 */
export async function runSet(el, setKey, opts = {}) {
  const individual = opts.individual || null;
  /** @type {any} */ let data;
  try { data = await rpc("mirror_set_get", { p_set_key: setKey, p_individual: individual }); }
  catch (e) { el.innerHTML = notice("urgent", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); return; }
  /** @type {Question[]} */
  const qs = data.questions.filter((/** @type {Question} */ q) => !q.hidden);
  const hiddenCount = data.questions.length - qs.length;
  if (!qs.length) { el.innerHTML = notice("info", "<p>There are no questions here yet.</p>"); return; }

  const answered = () => qs.filter((q) => q.answer).length;

  // Safety mode (the person's own Mirror only): private questions are never spoken out loud, by Read aloud or by hands-free.
  // mirror_my_settings is read-only and is not logged as a look. If it fails, behave as if safety mode is off.
  let safe = false;
  if (!individual) { try { safe = !!(await rpc("mirror_my_settings")).person.safety_sensitive; } catch { /* not a Mirror person */ } }
  const hush = (/** @type {Question} */ q) => safe && q.private;

  // hands-free state (see the top of this file). Browsers only allow the first speech after a tap, so a remembered "on"
  // waits for one tap ("Start hands-free") on each page load; after that every question is read and listened to by itself.
  let handsFree = canRecognize() && hfStored();
  let hfArmed = false;
  /** @type {"local"|"cloud"|null} */ let voiceMode = null;
  let hfToken = 0;
  /** @type {{ stop: () => void }|null} */ let listener = null;
  const hfCancel = () => { hfToken++; if (listener) listener.stop(); listener = null; stopSpeaking(); };
  let at = qs.findIndex((q) => !q.answer);
  if (at < 0) return list();   // everything answered: show the overview, any answer can be changed

  // ---------------------------------------------------------------- one question per screen
  function ask() {
    hfCancel();
    const q = qs[at];
    const a = q.answer;
    const st = a ? a.state : "";
    const v = a && a.state === "answered" ? a.value : null;
    const name = "q-" + q.key;
    /** @type {string} */
    let input = "";
    const choice = (/** @type {string} */ type, /** @type {string} */ value, /** @type {string} */ label, /** @type {boolean} */ on) =>
      `<label class="mm-choice"><input type="${type}" name="${name}" value="${esc(value)}"${on ? " checked" : ""}> ${esc(label)}</label>`;
    switch (q.answer_type) {
      case "text": input = `<input class="mm-input" id="mmAns" value="${esc(v ?? "")}" maxlength="500" aria-describedby="mmHelp">`; break;
      case "long_text": input = `<textarea class="mm-textarea" id="mmAns" rows="5" maxlength="5000" aria-describedby="mmHelp">${esc(v ?? "")}</textarea>`; break;
      case "number": input = `<input class="mm-input" id="mmAns" inputmode="decimal" value="${esc(v ?? "")}" data-mm-no-voice style="max-width:12rem" aria-describedby="mmHelp">`; break;
      case "money": input = `<div class="mm-row" style="gap:var(--mm-space-2)"><span aria-hidden="true" style="font-size:1.3em">$</span><input class="mm-input" id="mmAns" inputmode="decimal" value="${esc(v ?? "")}" data-mm-no-voice style="max-width:12rem" aria-label="Amount in dollars" aria-describedby="mmHelp"></div>`; break;
      case "date": input = `<input class="mm-input" type="date" id="mmAns" value="${esc(v ?? "")}" style="max-width:14rem" aria-describedby="mmHelp">`; break;
      case "choice": input = q.options.map((o) => choice("radio", o.value, o.label, v === o.value)).join(""); break;
      case "multi": input = q.options.map((o) => choice("checkbox", o.value, o.label, Array.isArray(v) && v.includes(o.value))).join(""); break;
      case "yes_no": input = choice("radio", "true", "Yes", v === true) + choice("radio", "false", "No", v === false); break;
      case "rating": input = `<div class="mm-rating">${RATING.map((r, i) => choice("radio", String(i + 1), r, Number(v) === i + 1)).join("")}</div>`; break;
    }
    const grouped = ["choice", "multi", "yes_no", "rating"].includes(q.answer_type);
    el.innerHTML = `
      ${countBar(answered(), qs.length, "answered")}
      ${canRecognize() ? `<div class="mm-row mm-hf"><button type="button" class="mm-btn${handsFree ? "" : " mm-btn-secondary"}" id="mmHf" aria-pressed="${handsFree}">${handsFree && !hfArmed ? "Start hands-free" : "Hands-free: " + (handsFree ? "on" : "off")}</button>
        <button type="button" class="mm-btn mm-btn-quiet" id="mmHfAgain" hidden>Listen again</button>
        <span class="mm-small mm-muted" id="mmHfStatus" role="status" aria-live="polite">${handsFree ? "" : "Turn on to have each question read to you and answer by speaking, without pressing anything."}</span></div>` : ""}
      <form class="mm-card mm-ask" id="mmAsk" novalidate ${q.private ? "data-mm-sensitive" : ""}>
        <p class="mm-muted mm-small" style="margin:0 0 var(--mm-space-2)">Question ${at + 1} of ${qs.length}${q.private ? ' · <span class="mm-tag mm-tag-info">Private</span>' : ""}</p>
        ${grouped
          ? `<fieldset class="mm-choices"><legend class="mm-legend mm-q"${hush(q) ? "" : " data-mm-read"}>${esc(q.prompt)}</legend>
               <span class="mm-hint" id="mmHelp">${esc(q.help || (q.answer_type === "multi" ? "Choose all that fit." : "Choose one."))}</span>${input}</fieldset>`
          : `<div class="mm-field"><label class="mm-q" for="mmAns"${hush(q) ? "" : " data-mm-read"}>${esc(q.prompt)}</label>
               <span class="mm-hint" id="mmHelp">${esc(q.help || "In your own words. Speak or type.")}</span>${input}</div>`}
        <fieldset class="mm-choices" style="margin-bottom:var(--mm-space-4)"><legend class="mm-sr">Or</legend>
          <div class="mm-choices-other">${STATES.map(([s, l]) => `<label class="mm-choice"><input type="radio" name="mmState" value="${s}"${st === s ? " checked" : ""}> ${esc(l)}</label>`).join("")}</div>
        </fieldset>
        <div class="mm-field" id="mmNoteWrap" ${st === "needs_help" ? "" : "hidden"}><label for="mmNote">What kind of help? <span class="mm-muted">(optional)</span></label>
          <input class="mm-input" id="mmNote" value="${esc(a && a.note ? a.note : "")}" maxlength="2000">
          <span class="mm-hint">${individual ? "" : "Nobody is told yet. It goes on your list of things you asked for help with, on your My Mirror page. When you work with an organization, they will see it if you share this topic."}</span></div>
        ${q.private ? `<p class="mm-muted mm-small">Private: only you, and organizations you choose to share this topic with, can see this answer.</p>` : ""}
        ${q.category === "mental_health" ? CRISIS_LINE : ""}
        ${!q.can_edit ? notice("caution", "<p>You can see this answer but not change it.</p>") : ""}
        <div id="mmErr" aria-live="assertive"></div>
        <div class="mm-row">
          <button class="mm-btn" type="submit">${at === qs.length - 1 ? "Save and finish" : "Save and continue"}</button>
          ${at > 0 ? '<button class="mm-btn mm-btn-secondary" type="button" id="mmBack">Back</button>' : ""}
          <button class="mm-btn mm-btn-quiet" type="button" id="mmSkip">Skip for now</button>
          <button class="mm-btn mm-btn-quiet" type="button" id="mmList">See all questions</button>
        </div>
        ${a && a.reworded ? `<p class="mm-small" style="margin-top:var(--mm-space-3)"><strong>Note:</strong> ${esc(REWORDED_NOTE)}</p>` : ""}
        ${a ? `<p class="mm-muted mm-small" style="margin-top:var(--mm-space-3)">Saved ${esc(new Date(a.at).toLocaleDateString("en-US", { month: "short", day: "numeric" }))}${a.by && a.by !== "self" ? " by your coordinator" : ""}. <button class="mm-btn mm-btn-quiet mm-small" type="button" id="mmHist" style="min-height:auto;padding:0">Earlier answers</button>${!individual && q.can_edit ? ` · <button class="mm-btn mm-btn-quiet mm-small" type="button" id="mmClear" style="min-height:auto;padding:0">Clear this answer</button>` : ""}</p><div id="mmHistBox"></div>` : ""}
      </form>
      ${hiddenCount ? `<p class="mm-muted mm-small">${hiddenCount} private ${hiddenCount === 1 ? "question is" : "questions are"} not shared with you.</p>` : ""}`;

    const form = /** @type {HTMLFormElement} */ (el.querySelector("#mmAsk"));
    voiceAll(form); readAll(form);
    const stateBoxes = /** @type {NodeListOf<HTMLInputElement>} */ (form.querySelectorAll('input[name="mmState"]'));
    const valueInputs = /** @type {NodeListOf<HTMLInputElement>} */ (form.querySelectorAll(`#mmAns, input[name="${name}"]`));
    // Picking a state clears the answer; typing or choosing an answer clears the state.
    stateBoxes.forEach((s) => s.addEventListener("change", () => {
      valueInputs.forEach((i) => { if (i.type === "radio" || i.type === "checkbox") i.checked = false; else i.value = ""; });
      /** @type {HTMLElement} */ (form.querySelector("#mmNoteWrap")).hidden = s.value !== "needs_help";
    }));
    valueInputs.forEach((i) => i.addEventListener(i.type === "radio" || i.type === "checkbox" ? "change" : "input", () => {
      stateBoxes.forEach((s) => { s.checked = false; });
      /** @type {HTMLElement} */ (form.querySelector("#mmNoteWrap")).hidden = true;
    }));
    if (!q.can_edit) form.querySelectorAll("input, textarea, select, button[type=submit]").forEach((x) => { /** @type {HTMLInputElement} */ (x).disabled = true; });

    form.addEventListener("submit", async (e) => { e.preventDefault(); if (await save(q, form, name)) next(); });
    el.querySelector("#mmSkip")?.addEventListener("click", next);
    el.querySelector("#mmBack")?.addEventListener("click", () => { at--; ask(); });
    el.querySelector("#mmList")?.addEventListener("click", list);
    el.querySelector("#mmHist")?.addEventListener("click", () => history(q));
    el.querySelector("#mmClear")?.addEventListener("click", async (e) => {
      const b = /** @type {HTMLButtonElement} */ (e.currentTarget);
      if (!b.dataset.sure) {   // two presses instead of a pop-up
        b.dataset.sure = "1"; b.textContent = "Press again to clear it";
        setTimeout(() => { if (b.isConnected) { delete b.dataset.sure; b.textContent = "Clear this answer"; } }, 6000);
        return;
      }
      b.disabled = true;
      try {
        await rpc("mirror_answer_clear", { p_set_key: setKey, p_question_key: q.key });
        q.answer = null;
        toast("Cleared. This question is back to not answered. Your earlier answers stay in your own history.");
        ask();
      } catch (err) { b.disabled = false; toast(err instanceof Error ? err.message : String(err)); }
    });
    const first = /** @type {HTMLElement|null} */ (form.querySelector("#mmAns, input[name='" + name + "']"));
    (first || form).focus({ preventScroll: false });
    el.scrollIntoView({ block: "start" });

    el.querySelector("#mmHf")?.addEventListener("click", async () => {
      if (handsFree && hfArmed) { handsFree = false; hfStore(false); ask(); return; }
      voiceMode = voiceMode || await voicePermission(q.private);
      if (!voiceMode) { const st = el.querySelector("#mmHfStatus"); if (st) st.textContent = "Hands-free needs your OK to use your voice. You can still type or tap."; return; }
      handsFree = true; hfArmed = true; hfStore(true); ask();
    });
    el.querySelector("#mmHfAgain")?.addEventListener("click", () => { hfArmed = true; runHandsFree(q, form, name); });
    if (handsFree && hfArmed && voiceMode) runHandsFree(q, form, name);
  }

  /** Reads the question, listens, fills in the answer, saves after a 2-second pause (a tap or key stops it). */
  async function runHandsFree(/** @type {Question} */ q, /** @type {HTMLFormElement} */ form, /** @type {string} */ name) {
    const my = ++hfToken;
    const alive = () => my === hfToken && handsFree;
    const statusEl = /** @type {HTMLElement|null} */ (el.querySelector("#mmHfStatus"));
    const again = /** @type {HTMLElement|null} */ (el.querySelector("#mmHfAgain"));
    const say = (/** @type {string} */ t) => { if (statusEl) statusEl.textContent = t; };
    if (again) again.hidden = true;
    if (!q.can_edit) { say("This answer can't be changed here."); return; }
    if (hush(q)) say("Safety mode: this private question is not read out loud. Read it on the screen.");
    else { say("Reading the question…"); await speak(q.prompt + ". " + choicesToSay(q)); }
    if (!alive()) return;
    const field = /** @type {HTMLInputElement|null} */ (form.querySelector("#mmAns"));
    const base = field && field.value.trim() ? field.value.trim() + " " : "";
    const isText = q.answer_type === "text" || q.answer_type === "long_text";
    let empty = 0;
    for (let tries = 0; tries < 4; tries++) {
      say("Listening… speak your answer. Say “skip” to move on, or “stop”.");
      listener = hear({ local: voiceMode === "local", silenceMs: q.answer_type === "long_text" ? 2600 : 1500,
        onText: (t) => { say("“" + t + "”"); if (isText && field && !spokenCommand(t)) field.value = base + t; } });
      const { text, error } = await listener.done;
      listener = null;
      if (!alive()) return;
      if (error === "not-allowed" || error === "service-not-allowed") {
        handsFree = false; hfStore(false); ask();
        const st = el.querySelector("#mmHfStatus"); if (st) st.textContent = "The microphone is blocked. Allow it in the browser's address bar to use hands-free.";
        return;
      }
      if (error === "network") { say("Couldn't reach the voice service. Answer on screen, or press Listen again."); if (again) again.hidden = false; return; }
      if (!text) { if (++empty >= 2) break; continue; }
      const cmd = spokenCommand(text);
      if (cmd === "skip") { if (field) field.value = base.trim(); next(); return; }
      if (cmd === "back") { if (at > 0) at--; ask(); return; }
      if (cmd === "stop") { handsFree = false; hfStore(false); if (field) field.value = base.trim(); ask(); return; }
      if (cmd.startsWith("state:")) {
        const box = /** @type {HTMLInputElement|null} */ (form.querySelector('input[name="mmState"][value="' + cmd.slice(6) + '"]'));
        if (box) { box.checked = true; box.dispatchEvent(new Event("change")); }
        return autoSave(form, say, my);
      }
      /** @type {string[]} */ let pick = [];
      if (q.answer_type === "choice" || q.answer_type === "multi") pick = matchOptions(text, q.options, q.answer_type === "multi");
      else if (q.answer_type === "yes_no") { const yn = spokenYesNo(text); if (yn !== null) pick = [String(yn)]; }
      else if (q.answer_type === "rating") { const rt = spokenRating(text); if (rt) pick = [String(rt)]; }
      else if (q.answer_type === "number" || q.answer_type === "money") {
        const m = text.replace(/,/g, "").match(/\d+(\.\d+)?/);
        if (m && field) { field.value = m[0]; field.dispatchEvent(new Event("input")); return autoSave(form, say, my, q.private); }
      } else if (q.answer_type === "date") { say("Please enter the date on the screen."); return; }
      else if (field) { field.value = base + text; field.dispatchEvent(new Event("input")); return autoSave(form, say, my, q.private); }
      if (pick.length) {
        form.querySelectorAll('input[name="' + name + '"]').forEach((i) => {
          const box = /** @type {HTMLInputElement} */ (i);
          if (pick.includes(box.value)) { box.checked = true; box.dispatchEvent(new Event("change")); }
        });
        return autoSave(form, say, my, q.private);
      }
      say("I heard “" + text + "”, but couldn't match it to a choice.");
      if (!hush(q)) await speak("Sorry, I didn't catch that. Please say one of the choices.");
      if (!alive()) return;
    }
    say("Hands-free is waiting. Answer on screen, or press Listen again.");
    if (again) again.hidden = false;
  }

  /**
   * Saves after a 2-second pause. On a PRIVATE question (confirm = true) it never saves by itself: a misheard private answer would
   * be kept for good (answers are append-only), so it asks for a spoken "save" and does not read the answer out loud.
   * @param {HTMLFormElement} form @param {(t: string) => void} say @param {number} my @param {boolean} [confirm]
   */
  async function autoSave(form, say, my, confirm = false) {
    if (confirm) {
      const again = /** @type {HTMLElement|null} */ (el.querySelector("#mmHfAgain"));
      const alive = () => my === hfToken && handsFree;
      let touched = false;
      const stopIt = () => { if (touched) return; touched = true; hfCancel(); say("Waiting for you. Press Save and continue when it's right."); };
      form.addEventListener("pointerdown", stopIt, { once: true });
      form.addEventListener("keydown", stopIt, { once: true });
      say("Not saved yet. This one is private: check your answer on the screen, then say “save”, or say “change” to answer again.");
      if (!safe) await speak("This question is private, so I won't read your answer out loud. Check it on the screen. Say save to keep it, or say change to answer again.");
      if (!alive() || touched) return;
      say("Listening for “save” or “change”…");
      listener = hear({ local: voiceMode === "local", silenceMs: 1500, onText: () => {} });
      const { text } = await listener.done;
      listener = null;
      if (!alive() || touched) return;
      const n = norm(text || "");
      if (/^(save|save it|yes|yes save|yes save it|keep it|ok|okay|that's right|correct)$/.test(n)) { form.requestSubmit(); return; }
      if (/^(change|change it|again|no|redo|try again|say it again)$/.test(n)) { ask(); return; }   // back to the saved answer, asks again
      const cmd = spokenCommand(n);
      if (cmd === "skip") { next(); return; }
      if (cmd === "back") { if (at > 0) at--; ask(); return; }
      if (cmd === "stop") { handsFree = false; hfStore(false); say("Hands-free is off. Your answer is not saved yet: press Save and continue when it's right."); return; }
      say("Not saved yet. Press Save and continue when it's right, or press Listen again.");
      if (again) again.hidden = false;
      return;
    }
    say("Got it. Saving in 2 seconds. Tap or type to change it first.");
    let cancelled = false;
    const cancel = () => { if (cancelled) return; cancelled = true; say("Waiting for you. Press Save and continue when you're ready."); };
    form.addEventListener("pointerdown", cancel, { once: true });
    form.addEventListener("keydown", cancel, { once: true });
    setTimeout(() => { if (!cancelled && my === hfToken && handsFree) form.requestSubmit(); }, 2000);
  }

  function next() {
    if (at < qs.length - 1) { at++; ask(); } else done();
  }

  /** Reads the screen and saves. Returns true when the person may move on. @param {Question} q @param {HTMLFormElement} form @param {string} name */
  async function save(q, form, name) {
    const err = /** @type {HTMLElement} */ (form.querySelector("#mmErr"));
    const stateEl = /** @type {HTMLInputElement|null} */ (form.querySelector('input[name="mmState"]:checked'));
    let state = stateEl ? stateEl.value : "answered";
    /** @type {any} */ let value = null;
    if (state === "answered") {
      const one = /** @type {HTMLInputElement|null} */ (form.querySelector("#mmAns"));
      const picked = [.../** @type {NodeListOf<HTMLInputElement>} */ (form.querySelectorAll(`input[name="${name}"]:checked`))].map((i) => i.value);
      switch (q.answer_type) {
        case "multi": value = picked.length ? picked : null; break;
        case "choice": case "rating": value = picked[0] ?? null; if (q.answer_type === "rating" && value) value = Number(value); break;
        case "yes_no": value = picked[0] ? picked[0] === "true" : null; break;
        default: value = one && one.value.trim() ? one.value.trim().replace(/[$,]/g, (c) => (q.answer_type === "money" ? "" : c)) : null;
      }
      if (value === null) return true;   // nothing chosen: same as skipping, nothing saved
    }
    const note = state === "needs_help" ? /** @type {HTMLInputElement} */ (form.querySelector("#mmNote")).value.trim() : "";
    const prev = q.answer;
    if (prev && prev.state === state && JSON.stringify(prev.value) === JSON.stringify(state === "answered" ? value : null) && (prev.note || "") === note) return true;

    const call = () => rpc("mirror_answer_save", { p_set_key: setKey, p_question_key: q.key, p_value: value, p_state: state, p_note: note || null, p_individual: individual });
    /** @type {HTMLButtonElement} */ (form.querySelector("button[type=submit]")).disabled = true;
    try {
      await call();
      q.answer = { value: state === "answered" ? value : null, state, note: note || null, by: "self", at: new Date().toISOString() };
      return true;
    } catch (e) {
      /** @type {HTMLButtonElement} */ (form.querySelector("button[type=submit]")).disabled = false;
      if (offline(e)) {
        pending.set(q.key, async () => { await call(); });
        q.answer = { value: state === "answered" ? value : null, state, note: note || null, by: "self", at: new Date().toISOString() };
        toast("No connection. Your answer will be saved when you're back online. Keep this page open.");
        return true;
      }
      err.innerHTML = notice("urgent", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`);
      return false;
    }
  }

  /** @param {Question} q */
  async function history(q) {
    const box = /** @type {HTMLElement} */ (el.querySelector("#mmHistBox"));
    try {
      const h = await rpc("mirror_answers_history", { p_set_key: setKey, p_question_key: q.key, p_individual: individual });
      // Each answer is shown with the answer type and choices of the wording it was given to (fix 6), and that wording when it differs.
      box.innerHTML = `<ul class="mm-small">${h.map((/** @type {any} */ x) => {
        const asked = { ...q, answer_type: x.answer_type || q.answer_type, options: x.options || q.options };
        return `<li>${esc(new Date(x.at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }))}: ${esc(answerText(asked, x))}${x.current ? " (now)" : ""}${x.reworded && x.question ? `<br><span class="mm-muted">The question then: “${esc(x.question)}”</span>` : ""}</li>`;
      }).join("")}</ul>
        ${individual
          ? `<p class="mm-muted mm-small">Only the current answer is shown. Earlier answers are for the person only.</p>`
          : `<p class="mm-muted mm-small">Earlier answers are for you only. Organizations you work with see only your current answer${q.private ? ", and only if you shared this topic" : ""}. Earlier answers are kept until you delete your whole Mirror. "Clear this answer" means nobody sees an answer now; the earlier ones stay here, for you.</p>`}`;
    } catch (e) { box.innerHTML = notice("caution", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); }
  }

  // ---------------------------------------------------------------- overview: every question and its answer
  function list() {
    hfCancel();
    el.innerHTML = `
      ${countBar(answered(), qs.length, "answered")}
      <p>Press any question to answer or change it.</p>
      <ol class="mm-qlist">${qs.map((q, i) => `<li><button type="button" class="mm-qlist-btn" data-i="${i}">
        <span class="mm-qlist-q">${esc(q.prompt)}${q.private ? ' <span class="mm-tag mm-tag-info">Private</span>' : ""}</span>
        <span class="mm-qlist-a${q.answer ? "" : " mm-muted"}">${q.answer ? esc(answerText(q, q.answer)) + (q.answer.reworded ? " (answered to an earlier wording)" : "") : "Not answered yet"}</span></button></li>`).join("")}</ol>
      <div class="mm-row">${qs.some((q) => !q.answer) ? '<button class="mm-btn" type="button" id="mmResume">Answer the next one</button>' : ""}${doneLinks()}</div>`;
    el.querySelectorAll("[data-i]").forEach((b) => b.addEventListener("click", () => { at = Number(/** @type {HTMLElement} */ (b).dataset.i); ask(); }));
    el.querySelector("#mmResume")?.addEventListener("click", () => { at = qs.findIndex((q) => !q.answer); ask(); });
  }

  function doneLinks() {
    return `${opts.nextLink ? `<a class="mm-btn mm-btn-secondary" href="${esc(opts.nextLink.href)}">${esc(opts.nextLink.label)}</a>` : ""}
      <a class="mm-btn mm-btn-quiet" href="/mirror/my-mirror/">Back to My Mirror</a>`;
  }

  function done() {
    hfCancel();
    const n = answered();
    el.innerHTML = `${countBar(n, qs.length, "answered")}
      <div class="mm-card">
        <h2 style="margin-top:0">${n === qs.length ? "Thank you" : "Saved"}</h2>
        <p>${n === qs.length ? "You answered every question here." : `You answered ${n} of ${qs.length}. The rest are here whenever you want them.`}
          You can come back and change any answer; your earlier answers are kept so you can see how things change.</p>
        ${pending.size ? notice("caution", "<p>Some answers are still waiting for a connection. Keep this page open until they're saved.</p>") : ""}
        <div class="mm-row"><button class="mm-btn mm-btn-secondary" type="button" id="mmList2">See my answers</button>${doneLinks()}</div>
      </div>`;
    el.querySelector("#mmList2")?.addEventListener("click", list);
    el.scrollIntoView({ block: "start" });
    if (opts.onDone) opts.onDone();
  }

  ask();
}
