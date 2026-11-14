// 6-month "please confirm your details" reminder emails for Royal Orleans
// owners. Run once a day (pg_cron in production — see the commented
// cron.schedule at the end of the condo_owner_portal migration; by hand
// locally) with the x-webhook-secret header.
//
// condo_reminders_due() picks who gets one: current owners whose details
// haven't been confirmed in 6 months (first reminder), plus one follow-up
// 14 days later if they still haven't responded. Confirming — by the email's
// "Nothing changed" button or by saving in the portal — resets the cycle.
//
// Each email carries a fresh single-use "Nothing changed" token; only its
// sha-256 hash is stored (condo_reminder_tokens). The run also sweeps any
// staff alerts a page failed to trigger (see _shared/notify.ts).
//
// Secrets: CONDO_REMINDER_SECRET (+ RESEND_API_KEY in production).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { escapeHtml, PORTAL_BASE_URL, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";
import { sweepProfileUpdates } from "../_shared/notify.ts";

const REMINDER_SECRET = Deno.env.get("CONDO_REMINDER_SECRET") || "";

async function sha256Hex(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function newToken() {
  return Array.from(crypto.getRandomValues(new Uint8Array(32))).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function renderEmail(o: { name: string; unit_label: string; is_followup: boolean }, token: string) {
  const confirmUrl = `${PORTAL_BASE_URL}nothing-changed.html?t=${token}`;
  const button = (href: string, label: string, primary: boolean) =>
    `<a href="${href}" style="display:inline-block;margin:0 8px 8px 0;padding:12px 22px;border-radius:4px;text-decoration:none;font-weight:600;${
      primary ? "background:#1f5f99;color:#ffffff;" : "background:#ffffff;color:#1f5f99;border:1px solid #1f5f99;"}">${label}</a>`;
  return {
    subject: o.is_followup ? "Reminder: please confirm your owner contact details" : "Please confirm your owner contact details",
    html: `
      <div style="font-family:Segoe UI,Arial,sans-serif;color:#1b2633;max-width:560px">
        <p style="font-weight:700;color:#1d3a5c;margin:0 0 16px">2nd Chance Housing · Royal Orleans Condominium</p>
        <p>Hi ${escapeHtml(o.name)},</p>
        <p>Every six months we ask owners to confirm the contact details we have on file${o.unit_label ? ` for <strong>${escapeHtml(o.unit_label)}</strong>` : ""}:
           your mailing address, phone numbers and emergency contact. It keeps association notices and urgent calls reaching you.</p>
        <p style="margin:24px 0">${button(confirmUrl, "Nothing changed", true)}${button(PORTAL_BASE_URL, "Review my information", false)}</p>
        <p style="font-size:14px;color:#5c6878">"Nothing changed" confirms your details in one click; it doesn't show or change anything.
           To update something, choose "Review my information" and sign in with the code we email you.</p>
        <p style="font-size:14px;color:#5c6878">Questions? Reply to this email.</p>
      </div>`,
  };
}

Deno.serve(async (req) => {
  if (!REMINDER_SECRET || req.headers.get("x-webhook-secret") !== REMINDER_SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  // Master switch: no owner emails until portal_settings.automation_mode is "live".
  const { data: mode } = await admin.from("portal_settings").select("value").eq("key", "automation_mode").maybeSingle();
  if ((mode?.value || "off") !== "live" && !SUPABASE_URL.includes("127.0.0.1") && !SUPABASE_URL.includes("host.docker.internal")) return new Response(JSON.stringify({ skipped: "automation_mode is off" }), { status: 200 });
  const { data: due, error } = await admin.rpc("condo_reminders_due");
  if (error) {
    console.error("condo-owner-reminders: condo_reminders_due failed", error.message);
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }

  let sent = 0;
  for (const o of due || []) {
    try {
      const token = newToken();
      // Record the token before sending so the email's button always works;
      // a failed send leaves the cycle counter one ahead, which only delays
      // that owner's follow-up.
      const { error: recErr } = await admin.rpc("condo_record_reminder_sent", { p_owner_id: o.owner_id, p_token_hash: await sha256Hex(token) });
      if (recErr) throw recErr;
      await sendEmail({ to: o.email, ...renderEmail(o, token) });
      sent++;
    } catch (err) {
      console.error("condo-owner-reminders: failed for", o.owner_id, err instanceof Error ? err.message : String(err));
    }
  }

  let alerts = 0;
  try { alerts = await sweepProfileUpdates(admin); } catch (err) {
    console.error("condo-owner-reminders: alert sweep failed", err instanceof Error ? err.message : String(err));
  }
  return new Response(JSON.stringify({ due: (due || []).length, sent, staff_alerts: alerts }), { headers: { "Content-Type": "application/json" } });
});
