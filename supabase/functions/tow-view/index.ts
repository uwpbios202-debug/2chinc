// Always Towing's private vehicle page (https://2ndchinc.org/towing/#k=<key>, Stephen 11/8/2026). No sign-in: the key in the link is the
// pass. Only its SHA-256 is stored (portal_settings.tow_link_hash, set by staff with tow_link_new() on https://2ndchinc.org/parking/).
//   POST { key } -> today's lot from tow_lot_view() (stalls, allowed vehicles with plates, VIN and photos, switches, holds, approved guests),
//   with 1-hour signed photo links. Each successful view is logged in tow_link_views. No resident names, emails or phones.
//   POST { key, action: "towed", alert_id?, stall, plate?, state?, vehicle?, note? } -> logs the tow (tow_record), closes the alert, emails the office.
//   Open tow requests come with their photos (bucket parking-alerts), signed for 1 hour.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { flushOutbox } from "../_shared/mail.ts";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json", "Cache-Control": "no-store" } });

async function sha256Hex(s: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function sameText(a: string, b: string) {
  if (a.length !== b.length) return false;
  let x = 0; for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const b = await req.json().catch(() => ({}));
    const key = String(b.key || "").trim();
    if (!/^[A-Za-z0-9_-]{24,64}$/.test(key)) return json(req, 403, { error: "This link is not valid. Ask 2nd Chance Housing for a new one." });
    const { data: row } = await admin.from("portal_settings").select("value").eq("key", "tow_link_hash").maybeSingle();
    const want = String(row?.value || "");
    if (!want || !sameText(await sha256Hex(key), want)) return json(req, 403, { error: "This link is not valid or was replaced. Ask 2nd Chance Housing for a new one." });

    if (b.action === "towed") {
      const uuid = /^[0-9a-f-]{36}$/i;
      const { data: t, error: te } = await admin.rpc("tow_record", {
        p_alert: typeof b.alert_id === "string" && uuid.test(b.alert_id) ? b.alert_id : null,
        p_stall: String(b.stall || "").slice(0, 10), p_plate: String(b.plate || "").slice(0, 12), p_state: String(b.state || "").slice(0, 2),
        p_vehicle: String(b.vehicle || "").slice(0, 80), p_note: String(b.note || "").slice(0, 300) });
      if (te) return json(req, 400, { error: te.message || "Could not record the tow." });
      await flushOutbox(admin, 5).catch(() => {});   // the office email goes out now
      return json(req, 200, { ok: true, tow: { stall: t.stall_label, plate: t.plate } });
    }
    const { data: lot, error } = await admin.rpc("tow_lot_view");
    if (error) throw error;
    const paths: string[] = [];
    for (const s of lot.stalls || []) for (const v of s.vehicles || []) for (const p of [v.front_path, v.back_path]) if (p) paths.push(p);
    const urls: Record<string, string> = {};
    if (paths.length) {
      const { data: signed } = await admin.storage.from("vehicles").createSignedUrls(paths, 3600);
      for (const x of signed || []) if (x.path && x.signedUrl) urls[x.path] = x.signedUrl;
    }
    for (const s of lot.stalls || []) for (const v of s.vehicles || []) {
      v.front_url = v.front_path ? urls[v.front_path] || null : null; v.back_url = v.back_path ? urls[v.back_path] || null : null;
      delete v.front_path; delete v.back_path;
    }
    const apaths: string[] = []; for (const t of lot.tow_requests || []) for (const p of t.photos || []) apaths.push(p);
    const aurls: Record<string, string> = {};
    if (apaths.length) { const { data: sg } = await admin.storage.from("parking-alerts").createSignedUrls(apaths, 3600); for (const x of sg || []) if (x.path && x.signedUrl) aurls[x.path] = x.signedUrl; }
    for (const t of lot.tow_requests || []) t.photos = (t.photos || []).map((p: string) => aurls[p]).filter(Boolean);
    await admin.from("tow_link_views").insert({
      ip: (req.headers.get("cf-connecting-ip") || (req.headers.get("x-forwarded-for") || "").split(",")[0] || "").trim().slice(0, 64) || null,
      user_agent: (req.headers.get("user-agent") || "").slice(0, 200) || null,
    });
    return json(req, 200, lot);
  } catch (e) {
    console.error("tow-view", e);
    return json(req, 500, { error: "Something went wrong. Call 2nd Chance Housing." });
  }
});
