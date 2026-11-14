// Staff actions on applications that need server-side secrets (staff two-step
// signed in; JWT in Authorization). Every use is logged.
//   POST { action: "reveal_ssn", id }    -> { ssn }  to compare with the SSN card
//   POST { action: "docs_offline", id }  -> deletes the ID / SSN card images from
//        storage after staff have saved them to the secure offline drive
//   POST { action: "recordings_offline", id } -> the same for the audio and video answers
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const SSN_KEY_B64 = Deno.env.get("APPLY_SSN_KEY") || "";
const OFFLINE_SCENES = ["id_front", "id_back", "ssn_card"];
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

async function decryptSsn(cipher: string) {
  const all = Uint8Array.from(atob(cipher.replace(/^v1:/, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("raw", Uint8Array.from(atob(SSN_KEY_B64), (c) => c.charCodeAt(0)), "AES-GCM", false, ["decrypt"]);
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: all.slice(0, 12) }, key, all.slice(12)));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const uc = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } }, auth: { persistSession: false } });
    const { data: ok } = await uc.rpc("staff_session_ok");
    const { data: u } = await admin.auth.getUser(jwt);
    const email = u?.user?.email;
    if (ok !== true || !email) return json(req, 403, { error: "Staff two-step sign-in required." });
    const body = await req.json().catch(() => ({}));
    const { data: app } = await admin.from("rental_applications").select("id, ssn_cipher, media, docs_offline_at").eq("id", String(body.id || "")).maybeSingle();
    if (!app) return json(req, 404, { error: "Application not found." });

    if (body.action === "reveal_ssn") {
      if (!app.ssn_cipher) return json(req, 404, { error: "No SSN on this application." });
      await admin.from("apply_access_log").insert({ staff_email: email, action: "media", application_id: app.id, detail: "revealed SSN" });
      const ssn = await decryptSsn(app.ssn_cipher);
      return json(req, 200, { ssn: /^\d{9}$/.test(ssn) ? `${ssn.slice(0, 3)}-${ssn.slice(3, 5)}-${ssn.slice(5)}` : ssn });
    }

    if (body.action === "docs_offline") {
      const docs = (app.media || []).filter((m: { scene: string }) => OFFLINE_SCENES.includes(m.scene));
      if (docs.length) {
        const { error } = await admin.storage.from("applications").remove(docs.map((m: { path: string }) => m.path));
        if (error) throw error;
      }
      const media = (app.media || []).filter((m: { scene: string }) => !OFFLINE_SCENES.includes(m.scene));
      await admin.from("rental_applications").update({ media, docs_offline_at: new Date().toISOString(), docs_offline_by: email }).eq("id", app.id);
      await admin.from("apply_access_log").insert({ staff_email: email, action: "status", application_id: app.id,
        detail: `ID and SSN card images moved offline and deleted from storage (${docs.length} file(s))` });
      return json(req, 200, { deleted: docs.length });
    }
    if (body.action === "recordings_offline") {
      const isRec = (m: { kind: string }) => m.kind === "audio" || m.kind === "video";
      const recs = (app.media || []).filter(isRec);
      if (recs.length) {
        const { error } = await admin.storage.from("applications").remove(recs.map((m: { path: string }) => m.path));
        if (error) throw error;
      }
      const media = (app.media || []).filter((m: { kind: string }) => !isRec(m));
      await admin.from("rental_applications").update({ media, recordings_offline_at: new Date().toISOString(), recordings_offline_by: email }).eq("id", app.id);
      await admin.from("apply_access_log").insert({ staff_email: email, action: "status", application_id: app.id,
        detail: `Audio and video answers moved offline and deleted from storage (${recs.length} file(s))` });
      return json(req, 200, { deleted: recs.length });
    }
    return json(req, 400, { error: "Unknown action" });
  } catch (err) {
    console.error("apply-staff: error", err instanceof Error ? err.message : String(err));
    return json(req, 500, { error: "Something went wrong. Try again." });
  }
});
