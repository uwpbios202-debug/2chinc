// The Human Mirror T7.4: the only door to the private bucket mirror-docs (it has no storage policy for browsers at all).
// Every action first asks the database gate AS THE SIGNED-IN PERSON (their own sign-in token), so who may do what is decided once,
// in mirror.allowed(), exactly as on every other Mirror page. Only then does this function use the service key for the file itself.
//   POST { action: "upload", individual?, type, title?, file_name, mime, size, expires_on?, location_note? }
//        -> { id, path, token }   one-time signed upload for exactly that place; the page calls storage.uploadToSignedUrl(path, token, file)
//   POST { action: "open", id }   -> { url, file_name }   a link that works for 5 minutes (a coordinator's look is in the person's "who looked")
//   POST { action: "delete", id } -> { deleted: true }    the person, or whoever added it; the file goes first, then its details
//   POST with x-cycle-secret (job mirror-docs-sweep) -> { removed, waiting }   removes files whose details are gone
// verify_jwt is off (supabase/config.toml) so the job can call it; signed-in calls are checked by the database gate with the caller's own token.
// See supabase/migrations/20261119414000_mirror_documents.sql.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";

const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const CYCLE_SECRET = Deno.env.get("RENT_CYCLE_SECRET") || "";
const BUCKET = "mirror-docs";
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    // The mirror-docs-sweep job (pg_cron, migration 20261119415000) has no user: it proves itself with x-cycle-secret. It removes files
    // whose details are gone (a person removed, or a stray upload over a day old) through the Storage API. It never reads a file.
    if (CYCLE_SECRET && req.headers.get("x-cycle-secret") === CYCLE_SECRET) {
      const { data: paths, error } = await admin.rpc("mirror_document_sweep_list");
      if (error) throw new Error("sweep list: " + error.message);
      const list = (paths || []) as string[];
      for (let i = 0; i < list.length; i += 100) {
        const { error: e2 } = await admin.storage.from(BUCKET).remove(list.slice(i, i + 100));
        if (e2) throw new Error("sweep remove: " + e2.message);
      }
      const { data: left } = await admin.rpc("mirror_document_sweep_done");
      return json(req, 200, { removed: list.length, waiting: left });
    }
    const auth = req.headers.get("Authorization") || "";
    if (!/^Bearer\s+\S+/i.test(auth)) return json(req, 401, { error: "Please sign in." });
    // The person's own client: auth.email() and the authenticator level in the database come from THEIR token.
    const me = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false }, global: { headers: { Authorization: auth } } });
    const body = await req.json().catch(() => ({}));
    const gate = async (fn: string, args: Record<string, unknown>) => {
      const { data, error } = await me.rpc(fn, args);
      if (error) throw Object.assign(new Error(error.message), { status: error.code === "42501" ? 403 : 400, code: error.code });
      return data;
    };

    if (body.action === "upload") {
      const r = await gate("mirror_document_begin", {
        p_individual: body.individual || null, p_type: String(body.type || ""), p_title: body.title || null,
        p_file_name: String(body.file_name || "document"), p_mime: String(body.mime || ""), p_size: Number(body.size) || 0,
        p_expires_on: body.expires_on || null, p_location_note: body.location_note || null,
      });
      const { data, error } = await admin.storage.from(BUCKET).createSignedUploadUrl(r.path);
      if (error || !data) throw new Error("upload link: " + (error?.message || "none"));
      return json(req, 200, { id: r.id, path: data.path, token: data.token });
    }

    if (body.action === "open") {
      const r = await gate("mirror_document_open", { p_id: String(body.id || "") });
      const { data, error } = await admin.storage.from(BUCKET).createSignedUrl(r.path, 300, body.download ? { download: r.file_name } : undefined);
      if (error || !data) throw new Error("open link: " + (error?.message || "none"));
      return json(req, 200, { url: data.signedUrl, file_name: r.file_name });
    }

    if (body.action === "delete") {
      const id = String(body.id || "");
      const r = await gate("mirror_document_delete_check", { p_id: id });
      const { error } = await admin.storage.from(BUCKET).remove([r.path]);
      if (error) throw new Error("remove: " + error.message);
      await gate("mirror_document_delete", { p_id: id });
      return json(req, 200, { deleted: true });
    }
    return json(req, 400, { error: "Unknown action" });
  } catch (e) {
    const err = e as { status?: number; message?: string; code?: string };
    if (err.status) return json(req, err.status, { error: err.message, code: err.code });   // the gate's own plain words
    console.error("mirror-files", err.message || String(e));
    return json(req, 500, { error: "Couldn't do that right now. Please try again." });
  }
});
