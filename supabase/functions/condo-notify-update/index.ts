// Pinged by the owner portal pages right after an owner saves, confirms
// "Nothing changed", or staff edit a record. It emails staff every
// condo_profile_updates row not yet notified (see _shared/notify.ts).
//
// Safe to call without credentials: it takes no input and can only send
// alerts for changes that really happened, each exactly once.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cors, SERVICE_ROLE_KEY, SUPABASE_URL } from "../_shared/config.ts";
import { sweepProfileUpdates } from "../_shared/notify.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  try {
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const sent = await sweepProfileUpdates(admin);
    return new Response(JSON.stringify({ sent }), { headers: { ...cors(req), "Content-Type": "application/json" } });
  } catch (err) {
    console.error("condo-notify-update: error", err instanceof Error ? err.message : String(err));
    return new Response(JSON.stringify({ error: "Notification failed" }), { status: 500, headers: { ...cors(req), "Content-Type": "application/json" } });
  }
});
