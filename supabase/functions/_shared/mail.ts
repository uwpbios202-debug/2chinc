// Sends email through Resend. Locally, with no RESEND_API_KEY set, it prints
// the email to the `supabase functions serve` log instead, so the whole
// sign-in and reminder flow can be tested without sending anything.
import { IS_LOCAL, MAIL_FROM, MAIL_REPLY_TO } from "./config.ts";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") || "";

// Send queued emails (email_outbox rows written by database triggers, e.g.
// receipts and "keys can be released"). Called after anything that may queue mail.
export async function flushOutbox(admin: any, limit = 50) {
  // Fewest tries first, so an email that keeps failing never blocks newer ones; after 5 tries it is left with its error.
  const { data } = await admin.from("email_outbox").select("*").is("sent_at", null).lt("attempts", 5).order("attempts").order("id").limit(limit);
  let n = 0;
  for (const m of data || []) {
    // Claim the row first (the attempt count only moves if nobody else got there): two flushes at once never send the same email twice.
    const { data: claimed } = await admin.from("email_outbox").update({ attempts: (m.attempts || 0) + 1 }).eq("id", m.id).is("sent_at", null).eq("attempts", m.attempts || 0).select("id");
    if (!claimed?.length) continue;
    try { await sendEmail({ to: m.to_email, subject: m.subject, html: m.html, ...(Array.isArray(m.attachments) && m.attachments.length ? { attachments: m.attachments } : {}) }); await admin.from("email_outbox").update({ sent_at: new Date().toISOString(), error: null }).eq("id", m.id); n++; }
    catch (e) { await admin.from("email_outbox").update({ error: e instanceof Error ? e.message : String(e) }).eq("id", m.id); }
  }
  return n;
}

export type Attachment = { filename: string; content: string }; // content: base64

export async function sendEmail(msg: { to: string | string[]; subject: string; html: string; replyTo?: string; attachments?: Attachment[] }) {
  if (!RESEND_API_KEY) {
    if (!IS_LOCAL) throw new Error("RESEND_API_KEY is not set");
    const text = msg.html.replace(/<style[\s\S]*?<\/style>/g, "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
    const att = (msg.attachments || []).map((a) => `${a.filename} (${Math.round(a.content.length * 0.75 / 1024)} KB)`).join(", ");
    console.log(`\n=== DEV EMAIL (not sent) ===\nTo: ${[msg.to].flat().join(", ")}\nSubject: ${msg.subject}\n${text}${att ? `\nAttachments: ${att}` : ""}\n============================\n`);
    return;
  }
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: MAIL_FROM, to: [msg.to].flat(), reply_to: msg.replyTo || MAIL_REPLY_TO, subject: msg.subject, html: msg.html,
      ...(msg.attachments?.length ? { attachments: msg.attachments } : {}),
    }),
  });
  if (!res.ok) throw new Error(`Resend rejected the email (${res.status}): ${await res.text()}`);
}
