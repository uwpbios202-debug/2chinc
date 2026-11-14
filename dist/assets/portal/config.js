// Which Supabase project the owner portal talks to. Opened from this PC
// (python serve.py -> http://localhost:8000/association-owners/roca1/) it uses the local
// Supabase started with `npx supabase start`; on 2ndchinc.org it uses the
// live project. Both keys are public "anon" keys by design — access is
// enforced by the database functions, not by hiding these.
const LOCAL = ["localhost", "127.0.0.1"].includes(location.hostname);

export const SUPABASE_URL = LOCAL
  ? "http://127.0.0.1:54321"
  : "https://hvnsgwfcjpakvhhkfsuy.supabase.co";

// Local: the Supabase CLI's standard local anon key. If `npx supabase status`
// prints a different "anon key", paste that here.
export const SUPABASE_ANON_KEY = LOCAL
  ? "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
  : "sb_publishable_WSLCLbx8GVdeG5_nVaapcA_ahyAVNjY";
