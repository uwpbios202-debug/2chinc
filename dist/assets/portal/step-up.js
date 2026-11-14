// Quick re-check before a sensitive action. Its own file (not inside portal.js) so a browser still holding an older cached portal.js keeps working.
import { client, errorText } from "/assets/portal/portal.js";

// Quick re-check before a sensitive action (changing an email or phone number). `run` makes the call; when the server answers
// STEP_UP_REQUIRED we email a 6-digit code, ask for it in a small box, and then run the call once more.
//   const { error } = await withStepUp(() => client.rpc("condo_update_my_profile", { p_changes }));
export async function withStepUp(run) {
  let res = await run();
  if (!res || !res.error || !String(res.error.message || "").includes("STEP_UP_REQUIRED")) return res;
  const ok = await new Promise((resolve) => {
    const ov = document.createElement("div");
    ov.style.cssText = "position:fixed;inset:0;z-index:10000;background:rgba(0,0,0,.6);display:flex;align-items:center;justify-content:center;padding:14px";
    ov.innerHTML = `<div role="dialog" aria-modal="true" aria-label="Confirm it is you" style="background:#fff;color:#1b2430;border-radius:12px;max-width:420px;width:100%;padding:20px;font-family:inherit">
      <h2 style="margin:0 0 8px;font-size:1.2rem">Quick check before we change that</h2>
      <p id="suMsg" style="margin:0 0 12px;line-height:1.45">We are emailing a 6-digit code to the address you signed in with.</p>
      <input id="suCode" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="6-digit code" style="font-size:1.4rem;letter-spacing:4px;width:100%;padding:10px;box-sizing:border-box;border:2px solid #90a994;border-radius:8px">
      <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px"><button type="button" id="suOk" style="flex:1;padding:12px;border:0;border-radius:8px;background:#2e7d1f;color:#fff;font-weight:700;font-size:1rem;cursor:pointer">Confirm</button>
        <button type="button" id="suResend" style="padding:12px;border:1px solid #ccd3dc;border-radius:8px;background:#fff;cursor:pointer">Send a new code</button>
        <button type="button" id="suNo" style="padding:12px;border:1px solid #ccd3dc;border-radius:8px;background:#fff;cursor:pointer">Cancel</button></div></div>`;
    document.body.appendChild(ov);
    const $s = (id) => ov.querySelector("#" + id), say = (t, bad) => { $s("suMsg").textContent = t; $s("suMsg").style.color = bad ? "#9b1c1c" : "#1b2430"; };
    const send = async () => {
      say("Sending your code…");
      const { error } = await client.functions.invoke("step-up", { body: { action: "send" } });
      say(error ? await errorText(error) : "We emailed you a 6-digit code. It works for 10 minutes. Check Spam or Junk if you do not see it.", !!error);
    };
    const done = (v) => { ov.remove(); resolve(v); };
    $s("suNo").onclick = () => done(false);
    $s("suResend").onclick = send;
    $s("suOk").onclick = async () => {
      $s("suOk").disabled = true;
      const { error } = await client.functions.invoke("step-up", { body: { action: "verify", code: $s("suCode").value } });
      $s("suOk").disabled = false;
      if (error) { say(await errorText(error), true); return; }
      done(true);
    };
    send(); $s("suCode").focus();
  });
  return ok ? run() : { data: null, error: { message: "Not changed. We needed to confirm it was you first." } };
}

