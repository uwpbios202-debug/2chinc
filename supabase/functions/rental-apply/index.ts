// "Say Yes" rental application backend (2ndchinc.org/apply). Public endpoint:
// verify_jwt is off; every action except start/verify requires the session
// token issued after the applicant proves their email address.
//
// POST { action: "start",  email }                          -> emails a 6-digit code
// POST { action: "verify", email, code }                    -> { token }
// POST { action: "upload", token, kind, scene, mime, bytes } -> { path, uploadToken }
//        (client then calls storage.uploadToSignedUrl(path, uploadToken, file))
// POST { action: "save_draft", token, step, state }          -> saves progress (never the SSN)
//        verify returns { token, draft } when the same email has a saved draft
// POST { action: "submit", token, applicant, household, answers, media, scene_version }
// POST { action: "purge" } with header x-purge-secret        -> retention cleanup
//
// Protection: media lives in the PRIVATE `applications` bucket under the
// session's own folder; uploads are one-time signed URLs; anon has no table
// or storage access; staff read through two-step sign-in with every view
// logged (see the rental_applications migration). Nothing personal is logged.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml, PORTAL_BASE_URL, SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";
import { turnstileOk } from "../_shared/turnstile.ts";

const PURGE_SECRET = Deno.env.get("APPLY_PURGE_SECRET") || "";

const BUCKET = "applications";
const MAX_BYTES = 100 * 1024 * 1024;
const MAX_FILES_PER_SESSION = 40;
const MAX_CODES_PER_HOUR = 4;
const MAX_CODES_ALL_PER_HOUR = 30;   // LOCAL ONLY, NEVER COMMIT OR PUSH (Stephen 10/7/2026); deployed from this machine. Cap across every address.
const MAX_CODE_ATTEMPTS = 5;
const MIME_EXT: Record<string, string> = {
  "video/webm": "webm", "video/mp4": "mp4", "video/quicktime": "mov", "video/x-matroska": "mkv",
  "audio/webm": "weba", "audio/mp4": "m4a", "audio/mpeg": "mp3", "audio/ogg": "ogg",
  "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/3gpp": "3gp", "video/3gpp": "3gp",   // common phone recordings
  "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic", "image/heif": "heif",
};
// Clips the applicant must record (scene ids match SCENES in site/apply/index.html).
const REQUIRED_VIDEO = ["pledge", "rent", "guests", "pets", "sublet", "noise", "conduct"];
// Identity photos (kept only until staff verify, then moved offline and deleted).
const REQUIRED_PHOTOS = ["id_front", "id_back"];   // no Social Security or tax-ID number is collected (Stephen 10/6/2026)
const SSN_KEY_B64 = Deno.env.get("APPLY_SSN_KEY") || "";

// AES-256-GCM with a key that never touches the database: "v1:" + base64(iv || ciphertext).
async function encryptSsn(ssn: string) {
  if (!SSN_KEY_B64) throw new Error("APPLY_SSN_KEY is not set");
  const key = await crypto.subtle.importKey("raw", Uint8Array.from(atob(SSN_KEY_B64), (c) => c.charCodeAt(0)), "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(ssn)));
  const all = new Uint8Array(iv.length + ct.length); all.set(iv); all.set(ct, iv.length);
  return "v1:" + btoa(String.fromCharCode(...all));
}

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

async function sha256(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function randomToken() {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sessionFor(token: unknown) {
  if (typeof token !== "string" || token.length < 30) return null;
  const { data } = await admin.from("apply_sessions").select("*").eq("token_hash", await sha256(token)).maybeSingle();
  if (!data || data.submitted_at || new Date(data.expires_at) < new Date()) return null;
  return data as { id: string; email: string | null; phone: string | null };
}

async function filesIn(folder: string) {
  const { data, error } = await admin.storage.from(BUCKET).list(folder, { limit: 1000 });
  if (error) throw error;
  return new Set((data || []).map((f) => `${folder}/${f.name}`));
}

const str = (v: unknown, max = 200) => String(v ?? "").trim().slice(0, max);
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const cleanPhone = (v: unknown) => { const d = String(v || "").replace(/\D/g, "").replace(/^1(?=\d{10}$)/, ""); return d.length === 10 ? `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` : ""; };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });

  try {
    const body = await req.json().catch(() => ({}));
    const action = body.action;

    if (action === "pet_stop") {   // counts only, no personal data
      await admin.from("apply_pet_stops").insert({});
      return json(req, 200, { ok: true });
    }

    if (action === "start") {
      const email = str(body.email, 200).toLowerCase();
      if (!EMAIL_RE.test(email)) return json(req, 400, { error: "Enter a full email address." });
      if (!(await turnstileOk(body.turnstile, req))) return json(req, 400, { error: "The security check did not pass. Reload the page and try again." });
      const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
      const [{ count }, { count: all }] = await Promise.all([
        admin.from("apply_email_codes").select("id", { count: "exact", head: true }).eq("email", email).gte("created_at", since),
        admin.from("apply_email_codes").select("id", { count: "exact", head: true }).gte("created_at", since)]);
      if ((count || 0) >= MAX_CODES_PER_HOUR) return json(req, 429, { error: "Too many codes requested. Wait an hour and try again." });
      if ((all || 0) >= MAX_CODES_ALL_PER_HOUR) return json(req, 429, { error: "We're getting a lot of requests right now. Please try again in an hour or call (262) 236-5443." });
      const code = String(100000 + (crypto.getRandomValues(new Uint32Array(1))[0] % 900000));
      const { error } = await admin.from("apply_email_codes").insert({ email, code_hash: await sha256(email + ":" + code) });
      if (error) throw error;
      await sendEmail({
        to: email, subject: `${code} is your 2nd Chance Housing application code`,
        html: `<div style="font-family:Arial,sans-serif;max-width:520px;color:#1b2430"><p>Your code to start your application is:</p>
          <p style="font-size:30px;letter-spacing:6px;font-weight:700;margin:12px 0">${code}</p>
          <p>Enter it on the application page. It expires in 10 minutes and works once.</p>
          <p style="color:#5b6573;font-size:13px">If you didn't ask for this, you can ignore this email.</p></div>`,
      }).catch((e) => { console.error("rental-apply: code email failed", e instanceof Error ? e.message : String(e)); throw new Error("send"); });
      return json(req, 200, { sent: true });
    }

    if (action === "verify") {
      const email = str(body.email, 200).toLowerCase();
      const code = String(body.code || "").replace(/\D/g, "");
      if (!EMAIL_RE.test(email) || code.length !== 6) return json(req, 400, { error: "Enter the 6-digit code from the email." });
      const { data: row } = await admin.from("apply_email_codes").select("*").eq("email", email).is("used_at", null)
        .gt("expires_at", new Date().toISOString()).order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (!row) return json(req, 400, { error: "That code expired. Send a new one." });
      if (row.attempts >= MAX_CODE_ATTEMPTS) return json(req, 400, { error: "Too many wrong tries. Send a new code." });
      if (row.code_hash !== await sha256(email + ":" + code)) {
        await admin.from("apply_email_codes").update({ attempts: row.attempts + 1 }).eq("id", row.id);
        return json(req, 400, { error: "That code didn't match." });
      }
      await admin.from("apply_email_codes").update({ used_at: new Date().toISOString() }).eq("id", row.id);
      const token = randomToken();

      // Resume: the same verified email gets its saved draft back, in the same private folder.
      const { data: saved } = await admin.from("apply_drafts").select("session_id, step, state, updated_at, apply_sessions!inner(submitted_at)")
        .eq("email", email).is("apply_sessions.submitted_at", null).order("updated_at", { ascending: false }).limit(1).maybeSingle();
      if (saved) {
        const { error: upErr } = await admin.from("apply_sessions")
          .update({ token_hash: await sha256(token), expires_at: new Date(Date.now() + 12 * 60 * 60 * 1000).toISOString() }).eq("id", saved.session_id);
        if (upErr) throw upErr;
        const present = await filesIn(saved.session_id);
        const keep = (m: unknown) => !!m && typeof m === "object" && present.has(String((m as { path?: unknown }).path));
        const pick = (o: unknown) => Object.fromEntries(Object.entries((o && typeof o === "object" ? o : {}) as Record<string, unknown>).filter(([, m]) => keep(m)));
        const st = (saved.state || {}) as Record<string, unknown>;
        return json(req, 200, { token, draft: { step: saved.step, saved_at: saved.updated_at, state: { ...st, media: pick(st.media), photos: pick(st.photos), docs: pick(st.docs) } } });
      }

      const { error } = await admin.from("apply_sessions").insert({ token_hash: await sha256(token), email });
      if (error) throw error;
      return json(req, 200, { token });
    }

    if (action === "save_draft") {
      const s = await sessionFor(body.token);
      if (!s) return json(req, 401, { error: "Your session expired. Verify your email again to continue." });
      const raw = body.state && typeof body.state === "object" ? body.state : null;
      if (!raw) return json(req, 400, { error: "Nothing to save." });
      const { ssn: _a, ssn_last4: _b, token: _c, ...state } = raw as Record<string, unknown>;   // never keep an SSN or a token
      const text = JSON.stringify(state);
      if (text.length > 200_000) return json(req, 413, { error: "That is too much to save." });
      const { error } = await admin.from("apply_drafts").upsert({ session_id: s.id, email: s.email || "", step: str(body.step, 30), state, updated_at: new Date().toISOString() });
      if (error) throw error;
      return json(req, 200, { ok: true });
    }

    if (action === "upload") {
      const s = await sessionFor(body.token);
      if (!s) return json(req, 401, { error: "Your session expired. Reload the page and verify your email again." });
      const mime = String(body.mime || "").split(";")[0].toLowerCase();
      const ext = MIME_EXT[mime];
      if (!ext) return json(req, 415, { error: "That file type isn't supported." });
      if (!(Number(body.bytes) > 0 && Number(body.bytes) <= MAX_BYTES)) return json(req, 413, { error: "That file is too large (100 MB max)." });
      const kind = /^(video|photo|audio)$/.test(body.kind) ? body.kind : null;
      const scene = /^[a-z0-9_-]{1,30}$/.test(body.scene || "") ? body.scene : null;
      if (!kind || !scene) return json(req, 400, { error: "Bad upload request." });
      if ((await filesIn(s.id)).size >= MAX_FILES_PER_SESSION) return json(req, 429, { error: "Upload limit reached for this application." });
      const path = `${s.id}/${kind}-${scene}-${Date.now()}.${ext}`;
      const { data, error } = await admin.storage.from(BUCKET).createSignedUploadUrl(path);
      if (error) throw error;
      return json(req, 200, { path, uploadToken: data.token });
    }

    if (action === "submit") {
      const s = await sessionFor(body.token);
      if (!s) return json(req, 401, { error: "Your session expired. Reload the page and verify your email again." });

      const a = body.applicant || {};
      const applicant = {
        name: str(a.name, 120), email: s.email || str(a.email, 200).toLowerCase(), phone: cleanPhone(a.phone),
        units: Array.isArray(a.units) ? a.units.map((u: unknown) => str(u, 10)).slice(0, 10) : [],
        move_in: str(a.move_in, 20), heard: str(a.heard, 200), accommodation: str(a.accommodation, 1000),
        // Month-to-month unless the applicant's agency needs an annual or CVI lease (the lease builder preselects it).
        lease_term: ["mtm", "annual", "cvi"].includes(a.lease_term) ? a.lease_term : "mtm", agency: str(a.agency, 120),
        cw_name: str(a.cw_name, 120), cw_phone: cleanPhone(a.cw_phone),
        cw_email: /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(str(a.cw_email, 200).toLowerCase()) ? str(a.cw_email, 200).toLowerCase() : "",
      };
      if (applicant.name.length < 2) return json(req, 400, { error: "Please enter your full name." });
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(applicant.email)) return json(req, 400, { error: "Please enter a valid email." });

      const household = (Array.isArray(body.household) ? body.household : []).slice(0, 12).map((p: Record<string, unknown>) => ({
        name: str(p.name, 120), relation: str(p.relation, 40), dob: str(p.dob, 20), minor: !!p.minor,
      })).filter((p: { name: string }) => p.name);

      const answers: Record<string, string> = {};
      for (const [k, v] of Object.entries(body.answers || {})) if (/^[a-z0-9-]{1,30}$/.test(k)) answers[k] = str(v, 2000);

      // Every media path must be in this session's folder and actually uploaded.
      const present = await filesIn(s.id);
      const media = (Array.isArray(body.media) ? body.media : []).slice(0, MAX_FILES_PER_SESSION).map((m: Record<string, unknown>) => ({
        kind: str(m.kind, 10), scene: str(m.scene, 30), path: str(m.path, 200), mime: str(m.mime, 60),
        bytes: Number(m.bytes) || 0, seconds: Math.round(Number(m.seconds) || 0),
      })).filter((m: { path: string }) => m.path.startsWith(s.id + "/") && present.has(m.path));

      const haveVideo = new Set(media.filter((m: { kind: string }) => m.kind === "video" || m.kind === "audio").map((m: { scene: string }) => m.scene));
      // A written answer of a couple of sentences counts as much as a recording (for people who cannot or would rather not record).
      const written = new Set(Object.entries(answers).filter(([, v]) => String(v).length >= 25).map(([k]) => k));
      const missing = REQUIRED_VIDEO.filter((sc) => !haveVideo.has(sc) && !written.has(sc));
      if (missing.length) return json(req, 400, { error: "Some recordings are missing. Go back and record each one (audio or video).", missing });
      const havePhoto = new Set(media.filter((m: { kind: string }) => m.kind === "photo").map((m: { scene: string }) => m.scene));
      const missingDocs = REQUIRED_PHOTOS.filter((sc) => !havePhoto.has(sc));
      if (missingDocs.length) return json(req, 400, { error: "Please add photos of the front and back of your ID.", missing: missingDocs });

      // Animals: a pet can't go forward; assistance animals are welcome.
      const animal = body.animal === "assistance" ? "assistance" : body.animal === "none" ? "none" : null;
      if (!animal) return json(req, 400, { error: "Please answer the animal question." });
      // Required question, recorded for staff only (no automatic action): "Are you required to register as a sex offender?"
      if (body.offender !== "yes" && body.offender !== "no") return json(req, 400, { error: "Please answer the sex offender question." });
      if (body.pet_caution_ack !== true) return json(req, 400, { error: "Please confirm the pet caution." });
      const aa = animal === "assistance" ? {
        kind: str(body.assistance_animal?.kind, 40), species: str(body.assistance_animal?.species, 60),
        service_dog_task: str(body.assistance_animal?.service_dog_task, 500), support_letter: !!body.assistance_animal?.support_letter,
      } : null;

      // Identity (from the ID barcode, confirmed by the applicant) and SSN.
      const idf = body.identity || {};
      const identity = {
        first: str(idf.first, 60), middle: str(idf.middle, 1).toUpperCase(), last: str(idf.last, 60), dob: str(idf.dob, 10),
        id_number_last4: str(idf.id_number, 40).slice(-4), id_state: str(idf.id_state, 4),
        id_expires: str(idf.id_expires, 10), from_barcode: !!idf.from_barcode,
      };
      if (!identity.first || !identity.last || !/^\d{4}-\d{2}-\d{2}$/.test(identity.dob))
        return json(req, 400, { error: "Please confirm your name and date of birth from your ID." });

      const { data: row, error } = await admin.from("rental_applications").insert({
        session_id: s.id, applicant: { ...applicant, registered_sex_offender: body.offender }, household, answers, media, scene_version: str(body.scene_version, 20),
        id_fields: identity, date_of_birth: identity.dob,
         animal, assistance_animal: aa, pet_caution_ack: true,
      }).select("id").single();
      if (error) throw error;
      await admin.from("apply_sessions").update({ submitted_at: new Date().toISOString() }).eq("id", s.id);
      await admin.from("apply_drafts").delete().eq("session_id", s.id);

      // Staff alert: first name and a link only — the application itself stays behind sign-in.
      const reviewUrl = new URL("applications.html", PORTAL_BASE_URL).toString();
      const first = escapeHtml(applicant.name.split(/\s+/)[0]);
      try {
        await sendEmail({
          to: STAFF_NOTIFY_EMAIL,
          subject: `New rental application (${applicant.units.length ? "Unit " + applicant.units.join(", ") : "any unit"})`,
          html: `<p>${first} just submitted a video application.</p><p><a href="${reviewUrl}">Review it</a> (staff two-step sign-in required).</p>`,
        });
      } catch (e) {
        console.error("rental-apply: staff email failed", e instanceof Error ? e.message : String(e));
      }
      // "We got your application and need to verify…" — what's on the ID (spelling check only).
      try {
        const name = [identity.first, identity.middle ? identity.middle + "." : "", identity.last].filter(Boolean).join(" ");
        const dob = new Date(identity.dob + "T12:00:00Z").toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric", timeZone: "UTC" });
        await sendEmail({ to: applicant.email, subject: "We got your application and need to verify a few details",
          html: `<p>Hi ${escapeHtml(identity.first)},</p><p>Thank you for applying to 2nd Chance Housing. We received your application (reference ${String(row.id).slice(0, 8).toUpperCase()}).</p>
            <p>We're checking that everything matches your ID. This is only a spelling check:</p>
            <ul><li><b>Name:</b> ${escapeHtml(name)}</li><li><b>Date of birth:</b> ${escapeHtml(dob)}</li>${identity.id_number_last4 ? `<li><b>ID number ending in:</b> ${escapeHtml(identity.id_number_last4)}</li>` : ""}</ul>
            <p>If anything is misspelled or wrong, reply to this email. Once it's verified, your ID images are removed from our website.</p><p>2nd Chance Housing · (262) 236-5443</p>` });
      } catch (e) { console.error("rental-apply: verification email failed", e instanceof Error ? e.message : String(e)); }
      return json(req, 200, { ok: true, ref: String(row.id).slice(0, 8).toUpperCase() });
    }

    if (action === "purge") {
      if (!PURGE_SECRET || req.headers.get("x-purge-secret") !== PURGE_SECRET) return json(req, 401, { error: "Unauthorized" });
      const { data: due, error } = await admin.rpc("apply_purge_due");
      if (error) throw error;
      let files = 0;
      for (const d of due || []) {
        const paths = [...(await filesIn(d.session_id))];
        if (paths.length) { await admin.storage.from(BUCKET).remove(paths); files += paths.length; }
        if (d.application_id) await admin.from("rental_applications").delete().eq("id", d.application_id);
        await admin.from("apply_sessions").delete().eq("id", d.session_id);
      }
      return json(req, 200, { purged: (due || []).length, files });
    }

    return json(req, 400, { error: "Unknown action" });
  } catch (err) {
    console.error("rental-apply: error", err instanceof Error ? err.message : String(err));
    if (err instanceof Error && err.message === "send") return json(req, 502, { error: "We couldn't send that email. Check the address and try again." });
    return json(req, 500, { error: "Something went wrong. Try again." });
  }
});
