// Cloudflare Turnstile (CAPTCHA) for the public forms and the sign-in page.
// The site key is public by design. The secret key lives only in Supabase (function secret
// TURNSTILE_SECRET_KEY and the Auth CAPTCHA setting), never in this repo.
// turnstileToken() resolves with a one-time token. The check is invisible unless Cloudflare wants
// the visitor to prove they are human, then a small box appears at the bottom of the screen.
export const TURNSTILE_SITE_KEY = "0x4AAAAAAFaN04DyRe6LIXiF";

let loading;
function load() {
  return (loading ||= new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
    s.async = true;
    s.onload = () => resolve(window.turnstile);
    s.onerror = () => { loading = null; reject(new Error("The security check could not load. Turn off any ad blocker for this site and try again.")); };
    document.head.appendChild(s);
  }));
}

export async function turnstileToken() {
  const ts = await load();
  const box = document.createElement("div");
  box.style.cssText = "position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:99999";
  document.body.appendChild(box);
  return new Promise((resolve, reject) => {
    let id, timer;
    const finish = (fn, v) => { clearTimeout(timer); try { ts.remove(id); } catch (e) { /* already gone */ } box.remove(); fn(v); };
    const fail = () => finish(reject, new Error("The security check did not finish. Reload the page and try again."));
    timer = setTimeout(fail, 90000);
    id = ts.render(box, { sitekey: TURNSTILE_SITE_KEY, appearance: "interaction-only", callback: (t) => finish(resolve, t), "error-callback": fail, "expired-callback": fail });
  });
}
