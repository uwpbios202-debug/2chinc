// "Report a problem" button for every tenant-facing page. Add one line before </body>:
//   <script src="/assets/report.js" defer></script>
// It sends what is on screen to staff: the page (without its private query string), the phone and browser, any
// script error that just happened, a message, an optional photo, and who the person is if they are signed in.
(function () {
  if (window.__reportLoaded) return;
  window.__reportLoaded = true;
  var LOCAL = ["localhost", "127.0.0.1"].indexOf(location.hostname) !== -1;
  var BASE = LOCAL ? "http://127.0.0.1:54321" : "https://hvnsgwfcjpakvhhkfsuy.supabase.co";
  var errors = [];
  function note(e) { errors.push(String(e).slice(0, 280)); if (errors.length > 8) errors.shift(); }
  window.addEventListener("error", function (ev) { note((ev.message || "error") + " (" + String(ev.filename || "").split("/").pop() + ":" + (ev.lineno || 0) + ")"); });
  window.addEventListener("unhandledrejection", function (ev) { note("promise: " + (ev.reason && ev.reason.message ? ev.reason.message : ev.reason)); });

  var css = document.createElement("style");
  css.textContent =
    "#rp-btn{position:fixed;right:max(12px,env(safe-area-inset-right,0px));bottom:max(12px,env(safe-area-inset-bottom,0px));z-index:2147483000;font:600 14px/1 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;" +
    "background:#1d3a5c;color:#fff;border:2px solid #fff;border-radius:999px;padding:11px 16px;box-shadow:0 2px 10px rgba(0,0,0,.35);cursor:pointer;min-height:44px}" +
    "#rp-btn:focus-visible{outline:3px solid #ffbf47;outline-offset:2px}" +
    "#rp-ov{position:fixed;inset:0;z-index:2147483001;background:rgba(10,18,28,.6);display:none;align-items:flex-end;justify-content:center;font:16px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}" +
    "#rp-ov.on{display:flex}" +
    "#rp-card{background:#fff;color:#16202c;width:100%;max-width:520px;max-height:92vh;overflow:auto;border-radius:16px 16px 0 0;padding:18px 18px calc(18px + env(safe-area-inset-bottom,0px));box-sizing:border-box}" +
    "@media(min-width:600px){#rp-ov{align-items:center}#rp-card{border-radius:14px}}" +
    "#rp-card h2{margin:0 0 4px;font-size:1.25rem}#rp-card p{margin:0 0 12px;color:#4a5668;font-size:.95rem}" +
    "#rp-card label{display:block;font-weight:600;font-size:.9rem;margin:10px 0 4px}" +
    "#rp-card textarea,#rp-card input[type=text],#rp-card input[type=email],#rp-card input[type=tel]{width:100%;box-sizing:border-box;font:inherit;padding:10px;border:1px solid #9aa6b6;border-radius:8px;background:#fff;color:#16202c}" +
    "#rp-card textarea{min-height:110px;resize:vertical}" +
    "#rp-row{display:flex;gap:10px}#rp-row>div{flex:1;min-width:0}" +
    "#rp-card .rp-b{font:600 16px/1 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;border-radius:10px;padding:13px 18px;border:1px solid #1d3a5c;cursor:pointer;min-height:48px}" +
    "#rp-go{background:#1d3a5c;color:#fff}#rp-x{background:#fff;color:#1d3a5c}" +
    "#rp-act{display:flex;gap:10px;margin-top:14px}#rp-act .rp-b{flex:1}" +
    "#rp-msg{margin-top:10px;font-weight:600}#rp-msg.err{color:#a3262a}#rp-msg.ok{color:#17663a}" +
    "#rp-prev{max-width:120px;max-height:120px;border-radius:8px;margin-top:6px;display:none}" +
    ".rp-small{font-size:.82rem;color:#5b6573;margin-top:10px}" +
    "#rp-web{position:absolute;left:-9999px;height:0;width:0;opacity:0}";
  document.head.appendChild(css);

  var btn = document.createElement("button");
  btn.id = "rp-btn"; btn.type = "button"; btn.textContent = "Report a problem";
  btn.setAttribute("aria-haspopup", "dialog");

  var ov = document.createElement("div");
  ov.id = "rp-ov"; ov.setAttribute("role", "dialog"); ov.setAttribute("aria-modal", "true"); ov.setAttribute("aria-labelledby", "rp-h");
  ov.innerHTML =
    '<div id="rp-card"><h2 id="rp-h">Report a problem</h2>' +
    '<p>Something not working? Tell us what happened. We will fix it and write back.</p>' +
    '<form id="rp-f" novalidate>' +
    '<label for="rp-m">What went wrong?</label><textarea id="rp-m" placeholder="For example: I typed my code and nothing happened."></textarea>' +
    '<div id="rp-row"><div><label for="rp-e">Your email (optional)</label><input id="rp-e" type="email" autocomplete="email" inputmode="email"></div>' +
    '<div><label for="rp-p">Your phone (optional)</label><input id="rp-p" type="tel" autocomplete="tel" inputmode="tel"></div></div>' +
    '<label for="rp-n">Your name (optional)</label><input id="rp-n" type="text" autocomplete="name">' +
    '<label for="rp-i">Add a screenshot or photo (optional)</label><input id="rp-i" type="file" accept="image/*"><img id="rp-prev" alt="Photo you added">' +
    '<input id="rp-web" type="text" tabindex="-1" autocomplete="off" aria-hidden="true">' +
    '<div id="rp-msg" role="status" aria-live="polite"></div>' +
    '<div id="rp-act"><button type="button" class="rp-b" id="rp-x">Cancel</button><button type="submit" class="rp-b" id="rp-go">Send report</button></div>' +
    '<p class="rp-small">We also send the page you are on and the type of phone you have, so we can find the problem. Urgent? Call or text (262) 236-5443.</p>' +
    '</form></div>';

  var photo = "";
  function $(id) { return document.getElementById(id); }
  function msg(t, cls) { var m = $("rp-msg"); m.className = cls || ""; m.textContent = t; }
  function sessionToken() {
    try {
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (/^sb-.*-auth-token$/.test(k)) { var v = JSON.parse(localStorage.getItem(k)); if (v && v.access_token) return v.access_token; }
      }
    } catch (e) { /* storage blocked: fine */ }
    return "";
  }
  function open() {
    ov.classList.add("on"); msg("");
    try { var r = localStorage.getItem("sch-owner-portal-email"); if (r && !$("rp-e").value) $("rp-e").value = r; } catch (e) { /* fine */ }
    $("rp-m").focus();
  }
  function close() { ov.classList.remove("on"); btn.focus(); }

  function shrink(file, cb) {
    var rd = new FileReader();
    rd.onload = function () {
      var im = new Image();
      im.onload = function () {
        var max = 1280, s = Math.min(1, max / Math.max(im.width, im.height)), c = document.createElement("canvas");
        c.width = Math.round(im.width * s); c.height = Math.round(im.height * s);
        c.getContext("2d").drawImage(im, 0, 0, c.width, c.height);
        cb(c.toDataURL("image/jpeg", 0.7));
      };
      im.onerror = function () { cb(""); };
      im.src = rd.result;
    };
    rd.onerror = function () { cb(""); };
    rd.readAsDataURL(file);
  }

  function init() {
    document.body.appendChild(btn); document.body.appendChild(ov);
    btn.addEventListener("click", open);
    $("rp-x").addEventListener("click", close);
    ov.addEventListener("click", function (e) { if (e.target === ov) close(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && ov.classList.contains("on")) close(); });
    $("rp-i").addEventListener("change", function () {
      var f = this.files && this.files[0]; photo = ""; $("rp-prev").style.display = "none";
      if (!f) return;
      shrink(f, function (d) { photo = d; if (d) { $("rp-prev").src = d; $("rp-prev").style.display = "block"; } });
    });
    $("rp-f").addEventListener("submit", function (e) {
      e.preventDefault();
      var text = $("rp-m").value.trim();
      if (text.length < 3) { msg("Tell us what went wrong, even a few words.", "err"); return; }
      var go = $("rp-go"); go.disabled = true; msg("Sending…");
      var body = {
        message: text, contact_name: $("rp-n").value.trim(), contact_email: $("rp-e").value.trim(), contact_phone: $("rp-p").value.trim(),
        page_url: location.href, page_title: document.title, user_agent: navigator.userAgent,
        viewport: window.innerWidth + "x" + window.innerHeight + " @" + (window.devicePixelRatio || 1), errors: errors.slice(),
        photo: photo, access_token: sessionToken(), website: $("rp-web").value
      };
      fetch(BASE + "/functions/v1/issue-report", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })
        .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (res) {
          go.disabled = false;
          if (!res.ok) { msg(res.j.error || "We couldn't send that. Please call or text (262) 236-5443.", "err"); return; }
          $("rp-m").value = ""; photo = ""; $("rp-i").value = ""; $("rp-prev").style.display = "none";
          msg("Thank you. We got it. Reference " + res.j.ref + ".", "ok");
          setTimeout(close, 2500);
        })
        .catch(function () { go.disabled = false; msg("We couldn't send that. Please call or text (262) 236-5443.", "err"); });
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
