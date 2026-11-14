// Emails staff one message per new condo_profile_updates row (an owner save,
// a "Nothing changed" confirmation, or a staff edit) and stamps notified_at.
// Called by condo-notify-update (pinged by the page right after a save) and
// by the daily condo-owner-reminders run, which sweeps up any missed ping.
import { escapeHtml, STAFF_NOTIFY_EMAIL } from "./config.ts";
import { sendEmail } from "./mail.ts";

type Change = { label: string; old: string | null; new: string | null };

function render(u: Record<string, any>) {
  const who = `${escapeHtml(u.owner_name)}${u.unit_label ? " — " + escapeHtml(u.unit_label) : ""}`;
  const via = u.via === "email_link" ? "the reminder email" : u.via === "staff" ? "the staff view" : "the owner portal";
  const changes: Change[] = Array.isArray(u.changes) ? u.changes : [];
  if (u.kind === "nothing_changed") {
    return {
      subject: `Owner confirmed details unchanged — ${u.owner_name}`,
      html: `<p><strong>${who}</strong> confirmed their contact details are still correct (via ${via}).</p>`,
    };
  }
  const rows = changes.map((c) => `<tr>
    <td style="padding:6px 10px;border-bottom:1px solid #ddd"><strong>${escapeHtml(c.label)}</strong></td>
    <td style="padding:6px 10px;border-bottom:1px solid #ddd;color:#888">${escapeHtml(c.old ?? "—")}</td>
    <td style="padding:6px 10px;border-bottom:1px solid #ddd">${escapeHtml(c.new ?? "—")}</td></tr>`).join("");
  return {
    subject: `${u.kind === "staff_edit" ? "Staff edited" : "Owner updated"} contact details — ${u.owner_name}`,
    html: `
      <p><strong>${who}</strong> (${escapeHtml(u.owner_email || "no email")}) via ${via}.</p>
      <table style="border-collapse:collapse;font-size:14px">
        <tr><th style="text-align:left;padding:6px 10px">Field</th><th style="text-align:left;padding:6px 10px">Was</th><th style="text-align:left;padding:6px 10px">Now</th></tr>
        ${rows}
      </table>
      `,
  };
}

// deno-lint-ignore no-explicit-any
export async function sweepProfileUpdates(admin: any) {
  const { data, error } = await admin.from("condo_profile_updates")
    .select("*").is("notified_at", null).order("created_at").limit(50);
  if (error) throw error;
  let sent = 0;
  for (const u of data || []) {
    // Claim the row first so two overlapping sweeps can't both send it.
    const { data: claimed } = await admin.from("condo_profile_updates")
      .update({ notified_at: new Date().toISOString() }).eq("id", u.id).is("notified_at", null).select("id");
    if (!claimed || !claimed.length) continue;
    try {
      const { subject, html } = render(u);
      await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject, html, replyTo: u.owner_email || undefined });
      sent++;
    } catch (err) {
      // Release the claim so the next sweep retries it.
      await admin.from("condo_profile_updates").update({ notified_at: null }).eq("id", u.id);
      console.error("notify: send failed", u.id, err instanceof Error ? err.message : String(err));
    }
  }
  return sent;
}
