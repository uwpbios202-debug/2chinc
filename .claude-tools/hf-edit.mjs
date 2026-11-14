// One-off edit: adds hands-free mode to site/mirror/assets/assessment-engine.js (Stephen 11/13/2026).
import fs from "node:fs";
const f = "site/mirror/assets/assessment-engine.js";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (!s.includes(a)) throw new Error("miss " + a.slice(0, 70)); s = s.split(a).join(b); };

rep(`  const answered = () => qs.filter((q) => q.answer).length;`,
`  const answered = () => qs.filter((q) => q.answer).length;

  // hands-free state (see the top of this file). Browsers only allow the first speech after a tap, so a remembered "on"
  // waits for one tap ("Start hands-free") on each page load; after that every question is read and listened to by itself.
  let handsFree = canRecognize() && hfStored();
  let hfArmed = false;
  /** @type {"local"|"cloud"|null} */ let voiceMode = null;
  let hfToken = 0;
  /** @type {{ stop: () => void }|null} */ let listener = null;
  const hfCancel = () => { hfToken++; if (listener) listener.stop(); listener = null; stopSpeaking(); };`);

rep(`  function ask() {
    const q = qs[at];`, `  function ask() {
    hfCancel();
    const q = qs[at];`);
rep("  function list() {\n    el.innerHTML = `", "  function list() {\n    hfCancel();\n    el.innerHTML = `");
rep(`  function done() {
    const n = answered();`, `  function done() {
    hfCancel();
    const n = answered();`);

rep(`      \${countBar(answered(), qs.length, "answered")}
      <form class="mm-card mm-ask" id="mmAsk" novalidate`, `      \${countBar(answered(), qs.length, "answered")}
      \${canRecognize() ? \`<div class="mm-row mm-hf"><button type="button" class="mm-btn\${handsFree ? "" : " mm-btn-secondary"}" id="mmHf" aria-pressed="\${handsFree}">\${handsFree && !hfArmed ? "Start hands-free" : "Hands-free: " + (handsFree ? "on" : "off")}</button>
        <button type="button" class="mm-btn mm-btn-quiet" id="mmHfAgain" hidden>Listen again</button>
        <span class="mm-small mm-muted" id="mmHfStatus" role="status" aria-live="polite">\${handsFree ? "" : "Turn on to have each question read to you and answer by speaking, without pressing anything."}</span></div>\` : ""}
      <form class="mm-card mm-ask" id="mmAsk" novalidate`);

rep(`    (first || form).focus({ preventScroll: false });
    el.scrollIntoView({ block: "start" });
  }`, `    (first || form).focus({ preventScroll: false });
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
    say("Reading the question…");
    await speak(q.prompt + ". " + choicesToSay(q));
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
        const m = text.replace(/,/g, "").match(/\\d+(\\.\\d+)?/);
        if (m && field) { field.value = m[0]; field.dispatchEvent(new Event("input")); return autoSave(form, say, my); }
      } else if (q.answer_type === "date") { say("Please enter the date on the screen."); return; }
      else if (field) { field.value = base + text; field.dispatchEvent(new Event("input")); return autoSave(form, say, my); }
      if (pick.length) {
        form.querySelectorAll('input[name="' + name + '"]').forEach((i) => {
          const box = /** @type {HTMLInputElement} */ (i);
          if (pick.includes(box.value)) { box.checked = true; box.dispatchEvent(new Event("change")); }
        });
        return autoSave(form, say, my);
      }
      say("I heard “" + text + "”, but couldn't match it to a choice.");
      await speak("Sorry, I didn't catch that. Please say one of the choices.");
      if (!alive()) return;
    }
    say("Hands-free is waiting. Answer on screen, or press Listen again.");
    if (again) again.hidden = false;
  }

  /** @param {HTMLFormElement} form @param {(t: string) => void} say @param {number} my */
  function autoSave(form, say, my) {
    say("Got it. Saving in 2 seconds. Tap or type to change it first.");
    let cancelled = false;
    const cancel = () => { if (cancelled) return; cancelled = true; say("Waiting for you. Press Save and continue when you're ready."); };
    form.addEventListener("pointerdown", cancel, { once: true });
    form.addEventListener("keydown", cancel, { once: true });
    setTimeout(() => { if (!cancelled && my === hfToken && handsFree) form.requestSubmit(); }, 2000);
  }`);

fs.writeFileSync(f, s);
console.log("ok");
