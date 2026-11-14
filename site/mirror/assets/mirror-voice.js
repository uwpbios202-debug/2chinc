// @ts-check
// The Human Mirror: speak instead of type, and its privacy rules (D-19, T1.5).
//
// Privacy rules (Stephen, 11/12-11/13/2026):
//  1. Phones and tablets: no button of ours. The keyboard's own microphone works in every plain field (the phone's
//     settings decide where the voice goes; we never see it). The first text field on a page shows a short tip.
//  2. Computers: a Speak button beside every text field. Order of preference:
//     a. ON THIS DEVICE: the browser turns speech into text locally (Chrome's on-device recognition). Nothing leaves
//        the computer, so nothing is asked. A one-time language download is offered first when needed.
//     b. SENT TO THE BROWSER'S COMPANY (Google for Chrome, Microsoft for Edge, Apple for Safari): only after the
//        person says yes ONCE on this device. The choice is remembered on this device and can be changed any time
//        (voiceSettings panel; My Mirror > Settings).
//     c. NO SPEECH IN THE BROWSER (Firefox) or the person said no: the button explains the computer's own dictation
//        (Windows key + H, Mac: press Fn twice) instead.
//  3. Sensitive questions (data-mm-sensitive on the field or any parent: health, safety, legal, immigration, money owed):
//     never sent anywhere without that yes, and even after yes a line under the button says where the voice goes.
//  4. The Human Mirror never records, receives or stores voice. Only the words the person chooses to save are kept.
//
// Use: <input class="mm-input"> / <textarea class="mm-textarea"> get a button automatically.
//      data-mm-no-voice on a field turns it off (passwords, codes).

const KEY = "mm-voice";            // localStorage: {"choice":"yes"|"no","at":"ISO date","v":1}
const VERSION = 1;                 // raise when the wording of the question changes in a way that needs a new answer

/** localStorage that never throws (private windows, blocked storage); falls back to memory for this page. */
const mem = /** @type {Record<string,string>} */ ({});
const store = {
  /** @param {string} k */ get(k) { try { return localStorage.getItem(k) ?? mem[k] ?? null; } catch { return mem[k] ?? null; } },
  /** @param {string} k @param {string} v */ set(k, v) { mem[k] = v; try { localStorage.setItem(k, v); } catch { /* memory only */ } },
  /** @param {string} k */ del(k) { delete mem[k]; try { localStorage.removeItem(k); } catch { /* ignore */ } },
};

/** @param {unknown} s */
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => /** @type {Record<string,string>} */ ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// ------------------------------------------------------------------ what this browser can do

/** @returns {any} the SpeechRecognition constructor, or null */
function recognizer() {
  const w = /** @type {any} */ (window);
  return w.SpeechRecognition || w.webkitSpeechRecognition || null;
}

/** Which company the browser sends voice to when it is not on the device. */
export function provider() {
  const ua = navigator.userAgent;
  if (/Edg\//.test(ua)) return "Microsoft";
  if (/Safari\//.test(ua) && !/Chrome\/|Chromium\/|CriOS\//.test(ua)) return "Apple";
  return "Google";
}

/** Phones and tablets: touch only, no mouse. They use the keyboard microphone instead of our button. */
export function isTouchOnly() {
  try { return matchMedia("(hover: none) and (pointer: coarse)").matches; } catch { return false; }
}

const lang = () => document.documentElement.lang && document.documentElement.lang.length > 2
  ? document.documentElement.lang : (navigator.language || "en-US");

/**
 * Can this browser turn speech into text on the device itself?
 * @returns {Promise<"available"|"downloadable"|"unavailable">}
 */
export async function onDevice() {
  const SR = recognizer();
  if (!SR) return "unavailable";
  try {
    if (typeof SR.available === "function") {                       // current Chrome shape
      const r = await SR.available({ langs: [lang()], processLocally: true });
      if (r === "available") return "available";
      if (r === "downloadable" || r === "downloading") return "downloadable";
      return "unavailable";
    }
    if (typeof SR.availableOnDevice === "function") {               // earlier Chrome shape
      const r = await SR.availableOnDevice(lang());
      if (r === "available") return "available";
      if (r === "downloadable" || r === "downloading") return "downloadable";
    }
  } catch { /* treat as not offered */ }
  return "unavailable";
}

/** Downloads the on-device language pack (needs a click). @returns {Promise<boolean>} */
async function installOnDevice() {
  const SR = recognizer();
  try {
    if (typeof SR.install === "function") return !!(await SR.install({ langs: [lang()], processLocally: true }));
    if (typeof SR.installOnDevice === "function") return !!(await SR.installOnDevice(lang()));
  } catch { /* fall through */ }
  return false;
}

// ------------------------------------------------------------------ the person's choice

/** @returns {"yes"|"no"|null} the remembered answer on this device to "send my voice to <company>?" */
export function consent() {
  try {
    const v = JSON.parse(store.get(KEY) || "null");
    if (v && v.v === VERSION && (v.choice === "yes" || v.choice === "no")) return v.choice;
  } catch { /* unreadable = not asked */ }
  return null;
}

/** @param {"yes"|"no"|null} choice null = forget, ask again next time */
export function setConsent(choice) {
  if (choice === null) store.del(KEY);
  else store.set(KEY, JSON.stringify({ choice, at: new Date().toISOString(), v: VERSION }));
  document.dispatchEvent(new CustomEvent("mm-voice-change"));
}

/** @param {Element} field */
const isSensitive = (field) => !!field.closest("[data-mm-sensitive]");

// ------------------------------------------------------------------ dialogs

/**
 * A plain modal question. Resolves with the value of the button pressed, or "cancel" (Esc).
 * @param {string} title @param {string} html trusted HTML @param {{value:string,label:string,kind?:string}[]} buttons
 * @returns {Promise<string>}
 */
function ask(title, html, buttons) {
  return new Promise((resolve) => {
    const d = document.createElement("dialog");
    d.className = "mm-dialog";
    d.setAttribute("aria-labelledby", "mm-dialog-title");
    d.innerHTML = `<h2 id="mm-dialog-title">${esc(title)}</h2><div class="mm-dialog-body">${html}</div>
      <div class="mm-row mm-dialog-actions">${buttons.map((b) =>
        `<button type="button" class="mm-btn${b.kind ? " mm-btn-" + b.kind : ""}" value="${esc(b.value)}">${esc(b.label)}</button>`).join("")}</div>`;
    document.body.append(d);
    let answer = "cancel";
    d.addEventListener("click", (e) => {
      const b = /** @type {HTMLElement} */ (e.target).closest("button[value]");
      if (b) { answer = /** @type {HTMLButtonElement} */ (b).value; d.close(); }
    });
    d.addEventListener("close", () => { d.remove(); resolve(answer); });
    d.showModal();
  });
}

/** Explains the computer's own dictation (no browser speech, or the person said no). @param {string} why */
function explainSystemDictation(why) {
  const mac = /Mac/.test(navigator.platform || navigator.userAgent);
  return ask("Speak with your computer's dictation", `
    <p>${esc(why)}</p>
    <p>Click in the box first, then:</p>
    <ul>
      ${mac ? "<li><strong>Mac:</strong> press the <kbd>Fn</kbd> key twice (or <kbd>Control</kbd> twice), then speak.</li>"
            : "<li><strong>Windows:</strong> hold the <kbd>Windows</kbd> key and press <kbd>H</kbd>, then speak.</li>"}
      ${mac ? "<li><strong>Windows:</strong> hold the <kbd>Windows</kbd> key and press <kbd>H</kbd>.</li>"
            : "<li><strong>Mac:</strong> press the <kbd>Fn</kbd> key twice.</li>"}
    </ul>
    <p class="mm-muted">Your computer's dictation follows your computer's own privacy settings. The Human Mirror never hears or keeps your voice.</p>`,
    [{ value: "ok", label: "OK" }]);
}

/**
 * The once-per-device question. Returns true when the voice may be sent.
 * @param {boolean} sensitive
 */
async function askConsent(sensitive) {
  const co = provider();
  const a = await ask("Speak your answer?", `
    <p>To turn your voice into words, this browser sends what you say to <strong>${esc(co)}</strong>.
       ${esc(co)} types it and sends the words back into the box. ${esc(co)}'s own privacy rules apply to it.</p>
    <p>The Human Mirror never records or keeps your voice. Only the words you choose to save are kept, and you can change them first.</p>
    ${sensitive ? `<p class="mm-notice mm-notice-caution">This question is private. You may prefer to type this one.</p>` : ""}
    <p class="mm-muted">We will remember your answer on this device. You can change it any time in Settings.</p>`,
    [{ value: "yes", label: "Yes, use my voice" }, { value: "no", label: "No, I'll type", kind: "secondary" }]);
  if (a === "yes") { setConsent("yes"); return true; }
  if (a === "no") setConsent("no");
  return false;
}

// ------------------------------------------------------------------ listening

/** @type {{ stop: () => void } | null} */
let active = null;

/**
 * Listens once and writes the words into the field (added after what is already there).
 * @param {HTMLInputElement|HTMLTextAreaElement} field @param {HTMLButtonElement} btn @param {HTMLElement} status
 * @param {boolean} local true = must stay on the device
 */
function listen(field, btn, status, local) {
  const SR = recognizer();
  const r = new SR();
  r.lang = lang();
  r.interimResults = true;
  r.continuous = field instanceof HTMLTextAreaElement;
  r.maxAlternatives = 1;
  if (local) { try { r.processLocally = true; } catch { /* older shape */ } try { r.mode = "ondevice-only"; } catch { /* ignore */ } }

  const before = field.value;
  const sep = before && !/\s$/.test(before) ? " " : "";
  let finalText = "";
  let failed = "";

  const setBusy = (/** @type {boolean} */ on) => {
    btn.setAttribute("aria-pressed", String(on));
    btn.querySelector(".mm-voice-label").textContent = on ? "Stop" : "Speak";
    status.textContent = on ? (local ? "Listening on this device. Speak now." : "Listening. Speak now.") : "";
  };

  r.onresult = (/** @type {any} */ e) => {
    let interim = "";
    for (let i = e.resultIndex; i < e.results.length; i++) {
      const t = e.results[i][0].transcript;
      if (e.results[i].isFinal) finalText += t; else interim += t;
    }
    field.value = before + sep + (finalText + interim).trim();
    field.dispatchEvent(new Event("input", { bubbles: true }));
  };
  r.onerror = (/** @type {any} */ e) => {
    failed = e.error === "not-allowed" || e.error === "service-not-allowed"
      ? "The microphone is blocked. Allow it in the browser's address bar, or type instead."
      : e.error === "no-speech" ? "I didn't hear anything. Press Speak and try again."
      : e.error === "network" ? `Could not reach ${provider()} to type your words. Try again, or type instead.`
      : e.error === "language-not-supported" ? "This language can't be typed on this device."
      : e.error === "aborted" ? "" : "Speaking didn't work this time. You can type instead.";
  };
  r.onend = () => {
    active = null;
    setBusy(false);
    if (failed) status.textContent = failed;
    else if (finalText.trim()) status.textContent = "Done. Check the words, then save when ready.";
    field.focus();
  };

  active = { stop: () => r.stop() };
  setBusy(true);
  try { r.start(); } catch { active = null; setBusy(false); status.textContent = "Speaking didn't work this time. You can type instead."; }
}

/** What happens when Speak is pressed. @param {HTMLInputElement|HTMLTextAreaElement} field @param {HTMLButtonElement} btn @param {HTMLElement} status */
async function onSpeak(field, btn, status) {
  if (active) { active.stop(); return; }
  if (!recognizer()) { await explainSystemDictation("This browser can't turn speech into words by itself."); return; }

  let local = await onDevice();
  if (local === "downloadable") {
    const a = await ask("Keep your voice on this computer?", `
      <p>This browser can turn your voice into words <strong>on this computer</strong>, so your voice is never sent anywhere.</p>
      <p>It needs a one-time download first. It may take a minute.</p>`,
      [{ value: "get", label: "Download it" }, { value: "skip", label: "Not now", kind: "secondary" }]);
    if (a === "get") {
      status.textContent = "Downloading. You can keep typing meanwhile.";
      local = (await installOnDevice()) && (await onDevice()) === "available" ? "available" : "unavailable";
      status.textContent = local === "available" ? "Ready. Press Speak." : "The download didn't finish.";
      if (local === "available") return;
    }
  }
  if (local === "available") { listen(field, btn, status, true); return; }

  // Leaving the device: needs the person's yes.
  let c = consent();
  if (c === null) c = (await askConsent(isSensitive(field))) ? "yes" : consent();
  if (c === "yes") { listen(field, btn, status, false); return; }
  if (c === "no") await explainSystemDictation(`You chose not to send your voice to ${provider()}. You can change that in Settings.`);
}

// ------------------------------------------------------------------ attaching to fields

const MIC = `<svg aria-hidden="true" focusable="false" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5M8 22h8"/></svg>`;

let tipShown = false;
let uid = 0;

/** Adds the Speak button (computers) or the keyboard-mic tip (phones) to one field. @param {HTMLInputElement|HTMLTextAreaElement} field */
export function voiceInput(field) {
  if (field.dataset.mmVoice || field.hasAttribute("data-mm-no-voice")) return;
  if (field instanceof HTMLInputElement && !/^(text|search|)$/.test(field.type)) return;   // not email/number/password/date
  field.dataset.mmVoice = "1";

  if (isTouchOnly()) {
    if (tipShown) return;
    tipShown = true;
    const tip = document.createElement("span");
    tip.className = "mm-hint mm-voice-tip";
    tip.textContent = "Tip: to speak instead of type, tap the microphone on your keyboard.";
    field.insertAdjacentElement("afterend", tip);
    return;
  }

  const id = field.id || (field.id = "mm-voice-f" + ++uid);
  const wrap = document.createElement("div");
  wrap.className = "mm-voice";
  const label = document.querySelector(`label[for="${CSS.escape(id)}"]`);
  const name = label ? label.textContent.trim().replace(/\s+/g, " ") : "this answer";
  wrap.innerHTML = `<button type="button" class="mm-btn mm-btn-secondary mm-voice-btn" aria-pressed="false" aria-label="Speak your answer: ${esc(name)}">${MIC}<span class="mm-voice-label">Speak</span></button>
    <span class="mm-voice-status mm-small" role="status" aria-live="polite"></span>
    <span class="mm-voice-note mm-small" hidden></span>`;
  field.insertAdjacentElement("afterend", wrap);

  const btn = /** @type {HTMLButtonElement} */ (wrap.querySelector("button"));
  const status = /** @type {HTMLElement} */ (wrap.querySelector(".mm-voice-status"));
  const note = /** @type {HTMLElement} */ (wrap.querySelector(".mm-voice-note"));
  btn.addEventListener("click", () => { onSpeak(field, btn, status); });

  // Sensitive questions: say where the voice goes, before the person presses Speak.
  if (isSensitive(field)) {
    const sync = async () => {
      const where = recognizer() ? await onDevice() : "unavailable";
      const sends = recognizer() && where !== "available" && consent() === "yes";
      note.hidden = !sends;
      note.textContent = sends ? `Private question: if you speak, your voice goes to ${provider()} to be typed. You can type instead.` : "";
    };
    sync();
    document.addEventListener("mm-voice-change", sync);
  }
}

/** Adds speech to every text field inside `root`. @param {ParentNode} [root] */
export function voiceAll(root = document) {
  root.querySelectorAll("input.mm-input, textarea.mm-textarea").forEach((f) => voiceInput(/** @type {any} */ (f)));
}

// ------------------------------------------------------------------ the settings panel (My Mirror > Settings, styleguide)

/** Renders the "Speaking instead of typing" setting into `box`. @param {HTMLElement} box */
export async function voiceSettings(box) {
  const co = provider();
  const draw = async () => {
    const touch = isTouchOnly();
    const has = !!recognizer();
    const local = has ? await onDevice() : "unavailable";
    const c = consent();
    let state;
    if (touch) state = "This phone or tablet uses the microphone on its own keyboard. Its own settings decide where your voice goes. The Human Mirror never hears it.";
    else if (!has) state = "This browser can't turn speech into words. Use your computer's dictation instead (Windows key + H, or Fn twice on a Mac).";
    else if (local === "available") state = "This computer turns your voice into words by itself. Your voice is not sent anywhere.";
    else if (c === "yes") state = `You chose to speak your answers. Your voice is sent to ${co} to be typed.`;
    else if (c === "no") state = `You chose not to send your voice to ${co}. Speak shows your computer's own dictation instead.`;
    else state = `Not chosen yet. The first time you press Speak, we will ask before anything is sent to ${co}.`;

    const canChoose = !touch && has && local !== "available";
    box.innerHTML = `<div class="mm-card mm-voice-settings">
      <h3>Speaking instead of typing</h3>
      <p>${esc(state)}</p>
      ${canChoose ? `<fieldset class="mm-choices">
        <legend class="mm-legend">Send my voice to ${esc(co)} to be typed?</legend>
        <label class="mm-choice"><input type="radio" name="mm-voice-choice" value="yes"${c === "yes" ? " checked" : ""}> Yes, use my voice</label>
        <label class="mm-choice"><input type="radio" name="mm-voice-choice" value="no"${c === "no" ? " checked" : ""}> No, I'll type</label>
        <label class="mm-choice"><input type="radio" name="mm-voice-choice" value="ask"${c === null ? " checked" : ""}> Ask me the next time I press Speak</label>
      </fieldset>` : ""}
      <p class="mm-muted mm-small">The Human Mirror never records or keeps your voice. This choice is kept on this device only; on another device you will be asked again.</p>
    </div>`;
    box.querySelectorAll('input[name="mm-voice-choice"]').forEach((i) => i.addEventListener("change", (e) => {
      const v = /** @type {HTMLInputElement} */ (e.target).value;
      setConsent(v === "ask" ? null : /** @type {"yes"|"no"} */ (v));
    }));
  };
  await draw();
  document.addEventListener("mm-voice-change", () => {
    const focused = box.contains(document.activeElement) ? /** @type {HTMLInputElement} */ (document.activeElement).value : null;
    draw().then(() => {
      if (focused) /** @type {HTMLInputElement|null} */ (box.querySelector(`input[value="${focused}"]`))?.focus();
    });
  });
}

// ------------------------------------------------------------------ read aloud (D-19 point 4)
// The browser's own speech. A voice that runs on the device is preferred; the words read are the page's or the
// question's, never what the person typed. Long text is read one paragraph at a time (some browsers stop after ~15 s).

const SPK = `<svg aria-hidden="true" focusable="false" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/></svg>`;

/** @type {HTMLButtonElement|null} */
let reading = null;

function pickVoice() {
  const all = speechSynthesis.getVoices();
  const l = lang().toLowerCase(), base = l.split("-")[0];
  return all.find((v) => v.localService && v.lang.toLowerCase() === l) || all.find((v) => v.localService && v.lang.toLowerCase().startsWith(base))
    || all.find((v) => v.lang.toLowerCase() === l) || null;
}

/** @param {HTMLButtonElement} btn @param {boolean} on */
function readState(btn, on) {
  btn.setAttribute("aria-pressed", String(on));
  const label = btn.querySelector(".mm-read-label");
  if (label) label.textContent = on ? "Stop reading" : (btn.dataset.label || "Read aloud");
}

/** Reads the text pieces aloud; pressing the same button again stops. @param {HTMLButtonElement} btn @param {string[]} pieces */
export function readAloud(btn, pieces) {
  if (!("speechSynthesis" in window)) return;
  const wasMe = reading === btn;
  speechSynthesis.cancel();
  if (reading) readState(reading, false);
  reading = null;
  if (wasMe) return;
  const voice = pickVoice();
  const list = pieces.map((t) => t.replace(/\s+/g, " ").trim()).filter(Boolean);
  if (!list.length) return;
  reading = btn; readState(btn, true);
  list.forEach((t, i) => {
    const u = new SpeechSynthesisUtterance(t);
    u.lang = lang(); if (voice) u.voice = voice; u.rate = 0.95;
    if (i === list.length - 1) u.onend = u.onerror = () => { if (reading === btn) { readState(btn, false); reading = null; } };
    speechSynthesis.speak(u);
  });
}

/** Readable pieces of an element: its paragraphs, headings and list items, skipping buttons and hidden parts. @param {Element} el */
function piecesOf(el) {
  const blocks = el.querySelectorAll("h1, h2, h3, h4, p, li, dt, dd, legend, label, td, th");
  const out = [];
  if (!blocks.length) return [/** @type {HTMLElement} */ (el).innerText];
  blocks.forEach((b) => {
    if (b.closest("button, .mm-read-btn, [hidden], [aria-hidden='true'], .mm-voice, nav, header, footer")) return;
    if (b.querySelector("p, li, h1, h2, h3, h4")) return;   // a parent of other blocks: its children are read instead
    out.push(/** @type {HTMLElement} */ (b).innerText);
  });
  return out;
}

/** A Read aloud button. @param {string} label @param {() => string[]} text */
export function readButton(label, text) {
  const b = document.createElement("button");
  b.type = "button"; b.className = "mm-btn mm-btn-quiet mm-read-btn"; b.dataset.label = label;
  b.setAttribute("aria-pressed", "false");
  b.innerHTML = `${SPK}<span class="mm-read-label">${esc(label)}</span>`;
  b.addEventListener("click", () => readAloud(b, text()));
  return b;
}

/** Adds "Read aloud" to every [data-mm-read] (a question) and "Listen to this page" to <main data-mm-listen>. @param {ParentNode} [root] */
export function readAll(root = document) {
  if (!("speechSynthesis" in window)) return;
  root.querySelectorAll("[data-mm-read]:not([data-mm-read-on])").forEach((el) => {
    el.setAttribute("data-mm-read-on", "1");
    el.insertAdjacentElement("afterend", readButton("Read aloud", () => piecesOf(el)));
  });
  const main = /** @type {HTMLElement|null} */ (document.querySelector("main[data-mm-listen]:not([data-mm-read-on])"));
  if (main) {
    main.setAttribute("data-mm-read-on", "1");
    const b = readButton("Listen to this page", () => piecesOf(main));
    b.classList.add("mm-listen-page");
    main.prepend(b);
  }
}
addEventListener("pagehide", () => { try { speechSynthesis.cancel(); } catch { /* ignore */ } });

// Attach automatically to fields already on the page; settings panels marked data-mm-voice-settings fill themselves.
function boot() {
  voiceAll();
  readAll();
  document.querySelectorAll("[data-mm-voice-settings]").forEach((b) => voiceSettings(/** @type {HTMLElement} */ (b)));
}
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
else boot();

// ------------------------------------------------------------------ hands-free (Stephen 11/13/2026: answer without pressing Speak each time)
// Used by assessment-engine.js. Same privacy rules as the Speak button: on-device first, otherwise the one-time yes (D-19).

/** True when this browser can turn speech into words by itself (Chrome, Edge, Safari, incl. Android and iPhone). */
export const canRecognize = () => !!recognizer();

/**
 * Whether hands-free may listen, asking once when needed. @param {boolean} sensitive
 * @returns {Promise<"local"|"cloud"|null>}
 */
export async function voicePermission(sensitive = false) {
  if (!recognizer()) return null;
  let local = await onDevice();
  if (local === "downloadable") {
    const a = await ask("Keep your voice on this device?", `
      <p>This browser can turn your voice into words <strong>on this device</strong>, so your voice is never sent anywhere.</p>
      <p>It needs a one-time download first. It may take a minute.</p>`,
      [{ value: "get", label: "Download it" }, { value: "skip", label: "Not now", kind: "secondary" }]);
    if (a === "get" && (await installOnDevice()) && (await onDevice()) === "available") local = "available";
  }
  if (local === "available") return "local";
  let c = consent();
  if (c === null) c = (await askConsent(sensitive)) ? "yes" : consent();
  return c === "yes" ? "cloud" : null;
}

/**
 * Listens until the person stops talking. Resolves with the words ("" when nothing was heard) and an error code if any.
 * @param {{ local: boolean, silenceMs?: number, maxMs?: number, onText?: (t: string) => void }} o
 * @returns {{ done: Promise<{ text: string, error: string }>, stop: () => void }}
 */
export function hear(o) {
  const SR = recognizer();
  const r = new SR();
  r.lang = lang(); r.interimResults = true; r.continuous = true; r.maxAlternatives = 1;
  if (o.local) { try { r.processLocally = true; } catch { /* older shape */ } try { r.mode = "ondevice-only"; } catch { /* ignore */ } }
  let finalText = "", interim = "", error = "", timer = 0, ended = false;
  const silence = o.silenceMs || 2200;
  /** @type {(v: {text: string, error: string}) => void} */ let resolve = () => {};
  const done = new Promise((res) => { resolve = res; });
  const finish = () => { if (ended) return; ended = true; clearTimeout(timer); try { r.stop(); } catch { /* already stopped */ } };
  const quietSoon = () => { clearTimeout(timer); timer = window.setTimeout(finish, silence); };
  r.onresult = (/** @type {any} */ e) => {
    interim = "";
    for (let i = e.resultIndex; i < e.results.length; i++) {
      if (e.results[i].isFinal) finalText += e.results[i][0].transcript + " "; else interim += e.results[i][0].transcript;
    }
    if (o.onText) o.onText((finalText + interim).trim());
    quietSoon();
  };
  r.onerror = (/** @type {any} */ e) => { if (e.error !== "aborted" && e.error !== "no-speech") error = e.error; };
  r.onend = () => { ended = true; clearTimeout(timer); resolve({ text: (finalText + interim).replace(/\s+/g, " ").trim(), error }); };
  try { r.start(); } catch { resolve({ text: "", error: "start" }); }
  timer = window.setTimeout(finish, o.maxMs || 9000);   // nothing said at all: stop after a while
  return { done, stop: finish };
}

/** Reads text aloud and resolves when finished (or at once when speech is not available). @param {string} text */
export function speak(text) {
  return new Promise((resolve) => {
    if (!("speechSynthesis" in window) || !text) return resolve(undefined);
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.lang = lang(); const v = pickVoice(); if (v) u.voice = v; u.rate = 0.95;
    u.onend = u.onerror = () => resolve(undefined);
    speechSynthesis.speak(u);
  });
}

export const stopSpeaking = () => { try { speechSynthesis.cancel(); } catch { /* ignore */ } };
