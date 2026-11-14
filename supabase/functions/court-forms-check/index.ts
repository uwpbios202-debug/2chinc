// "Check the court for a newer form" (Stephen, 11/12/2026). The site fills the official Wisconsin court forms itself
// (SC-500 English/Spanish Summons and Complaint, SC-5100V Declaration of Service) from copies kept at /assets/forms/.
// A browser cannot read wicourts.gov directly, so this function does it: for each form it reads the "Revised" date and the
// note on the court's small claims forms list, downloads the current PDF and returns its SHA-256. The page compares that with
// the copy the site fills; any difference means the court changed the form and the site must not fill the old one.
//   POST {} (staff JWT in Authorization) -> { checked_at, forms: [{ code, revised, note, sha256, last_modified, url, error? }] }
// Reads only public court pages; nothing is stored or sent anywhere.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const json = (req: Request, status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

const BASE = "https://www.wicourts.gov";
const LIST = BASE + "/forms1/circuit/ccform.jsp?Category=38";   // small claims forms
const FORMS = [
  { code: "SC-500", file: "SC-500_es.pdf", url: BASE + "/formdisplay/SC-500_es.pdf?formNumber=SC-500&formType=Form&formatId=2&language=es" },
  { code: "SC-5100V", file: "SC-5100V.pdf", url: BASE + "/formdisplay/SC-5100V.pdf?formNumber=SC-5100V&formType=Form&formatId=2&language=en" },
];
const UA = { "User-Agent": "Mozilla/5.0 (court form version check)" };
const text = (h: string) => h.replace(/<[^>]*>/g, " ").replace(/&amp;/g, "&").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();

async function sha256(bytes: ArrayBuffer) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(d, (b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, 405, { error: "POST only" });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(jwt);
    const me = u?.user?.email?.toLowerCase();
    const { data: st } = me ? await admin.from("condo_staff").select("name").ilike("email", me).maybeSingle() : { data: null };
    const { data: ad } = me && !st ? await admin.from("portal_admins").select("email").ilike("email", me).maybeSingle() : { data: null };
    if (!st && !ad) return json(req, 403, { error: "Staff only." });

    let rows: string[] = [];
    let listError = "";
    try {
      const r = await fetch(LIST, { headers: UA });
      if (!r.ok) throw new Error("forms list answered " + r.status);
      rows = (await r.text()).split(/<tr[\s>]/i);
    } catch (e) { listError = String((e as Error).message || e); }

    const forms = await Promise.all(FORMS.map(async (f) => {
      const out: Record<string, unknown> = { code: f.code, url: f.url };
      const row = rows.find((r) => r.includes("/formdisplay/" + f.file));
      if (row) {
        const t = text(row);
        out.revised = (t.match(/\b\d{2}\/\d{2}\/\d{4}\b/) || [])[0] || null;
        // The note the court writes beside the form (e.g. "Correction published on 7/6/26").
        out.note = t.replace(/\b\d{2}\/\d{2}\/\d{4}\b.*$/, "").replace(new RegExp("^" + f.code.replace("-", "\\-") + "\\s*"), "").trim().slice(0, 400);
      } else out.list_error = listError || "The form is no longer on the court's small claims forms list.";
      try {
        const r = await fetch(f.url, { headers: UA });
        if (!r.ok) throw new Error("the court answered " + r.status);
        out.sha256 = await sha256(await r.arrayBuffer());
        out.last_modified = r.headers.get("last-modified");
      } catch (e) { out.error = "Couldn't download the form: " + String((e as Error).message || e); }
      return out;
    }));
    return json(req, 200, { checked_at: new Date().toISOString(), list: LIST, forms });
  } catch (e) {
    return json(req, 500, { error: String((e as Error).message || e) });
  }
});
