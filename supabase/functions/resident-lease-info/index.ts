// "Lease information form" for a tenant who already lives in a unit (https://2ndchinc.org/resident/lease-info/).
// The tenant is already signed in (emailed code), so no new identity step is needed; the form collects what the lease needs and a
// photo of their ID for staff to verify (the ID photo is for verification only). The result is a rental_applications row with
// source 'resident' tied to the lease they hold (existing_lease_id), so staff review it on the Applications screen and build the
// new lease from it. The ID photos live in the private `applications` bucket under the form's own folder.
//
// POST { action: "start" }                         -> { lease, prefill, already }
// POST { action: "upload", scene, mime, bytes }    -> { path, uploadToken }   (scene: id_front | id_back)
// POST { action: "submit", ... }                   -> { ok: true }
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, escapeHtml, PORTAL_BASE_URL, SERVICE_ROLE_KEY, STAFF_NOTIFY_EMAIL, SUPABASE_URL } from "../_shared/config.ts";
import { sendEmail } from "../_shared/mail.ts";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const BUCKET = "applications";
const MIME_EXT: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic", "image/heif": "heif" };
const json = (req: Request, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const str = (v: unknown, max: number) => String(v ?? "").trim().slice(0, max);
const phone = (v: unknown) => str(v, 30).replace(/[^\d+()\-. x]/g, "");
const sha256 = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))).map((b) => b.toString(16).padStart(2, "0")).join("");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(jwt);
    const email = (u?.user?.email || "").toLowerCase();
    if (!email) return json(req, 401, { error: "Sign in first." });

    // Who is this? A tenant with an active or upcoming lease (never Unit 6: it has no tenant).
    const { data: t } = await admin.from("tenants").select("id, name, phone, emergency_name, emergency_phone, emergency_relation").ilike("email", email).limit(1).maybeSingle();
    if (!t) return json(req, 403, { error: "This form is for tenants. Your sign-in is not on a lease." });
    const { data: lts } = await admin.from("lease_tenants").select("lease_id, leases!inner(id, status, rent, lease_type, start_date, unit_id, rental_units(unit_number, address))").eq("tenant_id", t.id);
    const lease = (lts || []).map((x: any) => x.leases).filter((l: any) => ["active", "future"].includes(l.status)).sort((a: any, b: any) => (a.status === "active" ? -1 : 1) - (b.status === "active" ? -1 : 1))[0];
    if (!lease) return json(req, 403, { error: "You do not have a current lease on file. Call (262) 236-5443." });
    const unit = lease.rental_units?.unit_number || "";

    const body = await req.json().catch(() => ({}));
    const action = body.action;

    const { data: existing } = await admin.from("rental_applications").select("id, status, created_at").eq("existing_lease_id", lease.id).eq("source", "resident")
      .in("status", ["new", "reviewing"]).order("created_at", { ascending: false }).limit(1).maybeSingle();

    if (action === "start") {
      return json(req, 200, {
        lease: { unit, address: lease.rental_units?.address || "", rent: lease.rent, lease_type: lease.lease_type, start_date: lease.start_date },
        prefill: { name: t.name || "", phone: t.phone || "", emergency_name: t.emergency_name || "", emergency_phone: t.emergency_phone || "", emergency_relation: t.emergency_relation || "" },
        already: existing ? { received_at: existing.created_at } : null,
      });
    }
    if (existing) return json(req, 409, { error: "We already received your form and staff are reviewing it." });

    // One open folder per tenant for the ID photos.
    async function sessionId(): Promise<string> {
      const { data: s } = await admin.from("apply_sessions").select("id").eq("email", email).is("submitted_at", null).gt("expires_at", new Date().toISOString()).order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (s) return s.id;
      const { data: n, error } = await admin.from("apply_sessions").insert({ token_hash: await sha256(crypto.randomUUID()), email, expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString() }).select("id").single();
      if (error) throw error;
      return n.id;
    }

    if (action === "upload") {
      const scene = body.scene === "id_front" || body.scene === "id_back" ? body.scene : null;
      const mime = String(body.mime || "").split(";")[0].toLowerCase();
      const ext = MIME_EXT[mime];
      if (!scene) return json(req, 400, { error: "Bad upload request." });
      if (!ext) return json(req, 415, { error: "Use a photo (JPG, PNG, WEBP or HEIC)." });
      if (!(Number(body.bytes) > 0 && Number(body.bytes) <= 15 * 1024 * 1024)) return json(req, 413, { error: "That photo is too large (15 MB max)." });
      const sid = await sessionId();
      const path = `${sid}/photo-${scene}-${Date.now()}.${ext}`;
      const { data, error } = await admin.storage.from(BUCKET).createSignedUploadUrl(path);
      if (error) throw error;
      return json(req, 200, { path, uploadToken: data.token });
    }

    if (action === "submit") {
      const sid = await sessionId();
      const { data: files } = await admin.storage.from(BUCKET).list(sid, { limit: 100 });
      const present = new Set((files || []).map((f: { name: string }) => `${sid}/${f.name}`));
      const media = (Array.isArray(body.media) ? body.media : []).slice(0, 6).map((m: Record<string, unknown>) => ({
        kind: "photo", scene: m.scene === "id_back" ? "id_back" : "id_front", path: str(m.path, 200), mime: str(m.mime, 60), bytes: Number(m.bytes) || 0, seconds: 0,
      })).filter((m: { path: string }) => m.path.startsWith(sid + "/") && present.has(m.path));
      if (!media.some((m: { scene: string }) => m.scene === "id_front") || !media.some((m: { scene: string }) => m.scene === "id_back"))
        return json(req, 400, { error: "Please add a photo of the front and the back of your ID." });

      const idf = body.identity || {};
      const identity = {
        first: str(idf.first, 60), middle: str(idf.middle, 1).toUpperCase(), last: str(idf.last, 60), dob: str(idf.dob, 10),
        id_number_last4: str(idf.id_number, 40).slice(-4), id_state: str(idf.id_state, 4).toUpperCase(), id_expires: str(idf.id_expires, 10), from_barcode: false,
      };
      if (!identity.first || !identity.last || !/^\d{4}-\d{2}-\d{2}$/.test(identity.dob)) return json(req, 400, { error: "Please enter your name and date of birth as they appear on your ID." });
      if (!identity.id_state || !identity.id_number_last4) return json(req, 400, { error: "Please enter your ID's state and number." });
      const ph = phone(body.phone);
      if (ph.replace(/\D/g, "").length < 10) return json(req, 400, { error: "Please enter a phone number." });
      if (body.confirm !== true) return json(req, 400, { error: "Please confirm that the information is correct." });

      const household = (Array.isArray(body.household) ? body.household : []).slice(0, 12).map((p: Record<string, unknown>) => ({
        name: str(p.name, 120), relation: str(p.relation, 40), dob: str(p.dob, 20), minor: !!p.minor })).filter((p: { name: string }) => p.name);
      const animal = body.animal === "assistance" ? "assistance" : "none";
      const aa = animal === "assistance" ? { kind: str(body.assistance_animal?.kind, 40), species: str(body.assistance_animal?.species, 60), service_dog_task: str(body.assistance_animal?.task, 500), support_letter: false } : null;
      const name = [identity.first, identity.middle, identity.last].filter(Boolean).join(" ");
      const applicant = {
        name, email, phone: ph, units: [unit], move_in: lease.start_date || "", heard: "Current tenant (lease information form)", accommodation: str(body.accommodation, 1000),
        lease_term: "mtm", agency: str(body.agency, 120), cw_name: str(body.cw_name, 120), cw_phone: phone(body.cw_phone),
        emergency_contact: { name: str(body.emergency_name, 120), phone: phone(body.emergency_phone), relation: str(body.emergency_relation, 40) },
      };
      const { data: row, error } = await admin.from("rental_applications").insert({
        session_id: sid, applicant, household, answers: {}, media, id_fields: identity, date_of_birth: identity.dob, animal, assistance_animal: aa,
        pet_caution_ack: true, source: "resident", existing_lease_id: lease.id,
      }).select("id").single();
      if (error) throw error;
      await admin.from("apply_sessions").update({ submitted_at: new Date().toISOString() }).eq("id", sid);
      try {
        await sendEmail({ to: STAFF_NOTIFY_EMAIL, subject: `Lease information form received (Unit ${unit})`,
          html: `<p>${escapeHtml(identity.first)} (Unit ${escapeHtml(unit)}) filled in the lease information form and uploaded an ID for verification.</p><p><a href="${new URL("/leasing/applications/", "https://2ndchinc.org").toString()}">Review it</a> (staff two-step sign-in required). Check the ID, approve it, then build the new lease from it.</p>` });
      } catch (e) { console.error("resident-lease-info: staff alert failed", e instanceof Error ? e.message : String(e)); }
      return json(req, 200, { ok: true, id: row.id });
    }
    return json(req, 400, { error: "Unknown action." });
  } catch (e) {
    console.error("resident-lease-info:", e instanceof Error ? e.stack || e.message : String(e));
    return json(req, 500, { error: "Something went wrong. Please try again, or call (262) 236-5443." });
  }
});
