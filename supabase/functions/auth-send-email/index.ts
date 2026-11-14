// Supabase Auth "Send Email" hook for 2nd Chance Housing's project.
// GoTrue calls this for every auth email; the only one the system uses is
// the portal's 6-digit sign-in code (staff, field staff and agents also enter
// an authenticator-app code; see 20261105150000_mfa_authenticator.sql).
//
// It only mails addresses on file (a current owner or staff). For anyone
// else it reports success without sending, so the sign-in page can't be
// used to find out which emails belong to owners.
//
// Enabled locally in supabase/config.toml ([auth.hook.send_email]); in
// production under Authentication -> Auth Hooks -> Send Email.
// Secrets: SEND_EMAIL_HOOK_SECRET (+ RESEND_API_KEY in production).
import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { escapeHtml, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const HOOK_SECRET = (Deno.env.get("SEND_EMAIL_HOOK_SECRET") || "").replace("v1,whsec_", "");

type Payload = { user: { email: string }; email_data: { token: string; token_hash?: string; email_action_type: string } };

// The "Sign in" button (Stephen, 11/11/2026): opens https://2ndchinc.org/sign-in/ with the one-time token in the address
// fragment (#..., never sent to any server). That page asks for one tap before using it, so an email scanner that
// opens links can't use up the sign-in. The button and the code are the same one-time sign-in: either one works, once.
const SIGN_IN_PAGE = "https://2ndchinc.org/sign-in/";
const LINK_TYPES = new Set(["magiclink", "signup", "email"]);

function codeEmail(token: string, tokenHash: string, actionType: string) {
  const type = LINK_TYPES.has(actionType) ? actionType : "email";
  const link = tokenHash ? `${SIGN_IN_PAGE}#t=${encodeURIComponent(tokenHash)}&y=${type}` : "";
  const button = link
    ? `<p style="margin:8px 0 20px"><a href="${escapeHtml(link)}" style="display:inline-block;background:#1d3a5c;color:#ffffff;text-decoration:none;font-weight:700;padding:12px 28px;border-radius:8px">Click here to sign in</a></p>
        <p>or use the code below:</p>`
    : `<p>Your sign-in code is:</p>`;
  return {
    // Plain subject: it names neither the Mirror nor housing (Human Mirror privacy page; Stephen 11/14/2026, for every sign-in)
    subject: `${token} is your sign-in code`,
    html: `
      <div style="font-family:Segoe UI,Arial,sans-serif;color:#1b2633;max-width:520px">
        <p style="font-weight:700;color:#1d3a5c;margin:0 0 16px">2nd Chance Housing</p>
        ${button}
        <p style="font-size:30px;font-weight:700;letter-spacing:6px;margin:8px 0 16px">${escapeHtml(token)}</p>
        <p>The button and the code expire in 10 minutes and work once. The button signs you in on the device where you open this email. Staff and agents also enter a code from their authenticator app.</p>
        <p style="font-size:14px;color:#5c6878">If you didn't try to sign in, you can ignore this email; nobody can get in without it. Never forward this email.</p>
      </div>`,
  };
}

const ok = () => new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
const fail = (status: number, message: string) =>
  new Response(JSON.stringify({ error: { http_code: status, message } }), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  let payload: Payload;
  try {
    payload = new Webhook(HOOK_SECRET).verify(await req.text(), Object.fromEntries(req.headers)) as Payload;
  } catch (err) {
    console.error("auth-send-email: bad signature", err instanceof Error ? err.message : String(err));
    return fail(401, "Invalid webhook signature");
  }

  try {
    const { user, email_data } = payload;
    // Informational notices (password changed, etc.) aren't used by this system.
    if (!email_data?.token) return ok();

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    // signin_email_on_file = condo_email_on_file + Mirror people/coordinators (only while mirror_signin_enabled is on).
    // If it ever fails, fall back to the original list so codes keep going out to everyone already on file.
    let { data: onFile, error } = await admin.rpc("signin_email_on_file", { p_email: user.email });
    if (error) {
      console.error("auth-send-email: signin_email_on_file failed, using condo_email_on_file", error.message);
      ({ data: onFile, error } = await admin.rpc("condo_email_on_file", { p_email: user.email }));
    }
    if (error) throw error;
    if (onFile !== true) return ok();

    await sendEmail({ to: user.email, ...codeEmail(email_data.token, email_data.token_hash || "", email_data.email_action_type) });
    return ok();
  } catch (err) {
    console.error("auth-send-email: error", err instanceof Error ? err.stack || err.message : String(err));
    return fail(500, "Email send failed");
  }
});
