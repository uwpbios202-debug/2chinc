// Phone alerts (web push). Sends push_outbox rows to every phone the person turned alerts on for (push_subscriptions).
// Keys: Supabase secrets VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_SUBJECT (the public key is also the setting vapid_public_key).
// Free: the browser makers (Apple, Google) deliver the message. Migration: 20261118160000_phone_alerts_push.sql.
import webpush from "npm:web-push@3.6.7";

const PUB = Deno.env.get("VAPID_PUBLIC_KEY") || "", PRIV = Deno.env.get("VAPID_PRIVATE_KEY") || "";
let ready = false;
function setup() {
  if (ready || !PUB || !PRIV) return ready;
  webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") || "mailto:info@2ndchinc.org", PUB, PRIV);
  return (ready = true);
}

export async function flushPush(admin: any, limit = 200) {
  if (!setup()) return 0;   // keys not set yet: leave the rows queued
  const { data } = await admin.from("push_outbox").select("*").is("sent_at", null).lt("attempts", 3)
    .gt("created_at", new Date(Date.now() - 3600e3).toISOString()).order("id").limit(limit);   // an alert older than an hour is no use
  let n = 0;
  for (const m of data || []) {
    const { data: claimed } = await admin.from("push_outbox").update({ attempts: (m.attempts || 0) + 1 }).eq("id", m.id).is("sent_at", null).eq("attempts", m.attempts || 0).select("id");
    if (!claimed?.length) continue;
    const { data: subs } = await admin.from("push_subscriptions").select("*").ilike("email", m.to_email);
    let ok = 0; const errs: string[] = [];
    for (const s of subs || []) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          JSON.stringify({ title: m.title, body: m.body, url: m.url, tag: m.tag || m.kind }), { TTL: 3600, urgency: "high" });
        ok++; await admin.from("push_subscriptions").update({ last_ok_at: new Date().toISOString(), last_error: null }).eq("id", s.id);
      } catch (e: any) {
        const code = e?.statusCode;
        if (code === 404 || code === 410) await admin.from("push_subscriptions").delete().eq("id", s.id);   // the phone turned alerts off or the app was removed
        else { errs.push(String(code || e?.message || e)); await admin.from("push_subscriptions").update({ last_error: String(code || e?.message || e).slice(0, 200) }).eq("id", s.id); }
      }
    }
    await admin.from("push_outbox").update({ sent_at: new Date().toISOString(), delivered: ok, error: errs.length ? errs.join("; ").slice(0, 300) : null }).eq("id", m.id);
    n += ok;
  }
  return n;
}
