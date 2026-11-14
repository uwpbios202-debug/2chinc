import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
const def = (f) => JSON.parse(execFileSync('sh', ['./.claude-tools/supa-query.sh', `select pg_get_functiondef('${f}'::regproc) d`]).toString())[0].d;
const ins = (src, anchor, add, label) => { if (src.split(anchor).length !== 2) throw new Error('anchor not unique/found: ' + label); return src.replace(anchor, anchor + add); };
const EXP = "Your sign-in on this device has expired. Please sign in again.";
let me = def('mirror.me');
me = ins(me, "if auth.email() is null then raise exception 'Please sign in.' using errcode = '42501'; end if;\n",
  `  if not coalesce(public.session_fresh(), false) then raise exception '${EXP}' using errcode = '42501'; end if;\n`, 'me');
let sim = def('mirror.signed_in_member_ok');
sim = ins(sim, "and not coalesce(public.autopay_view_as_session(), true)", "\n    and coalesce(public.session_fresh(), false)", 'sim');
let al = def('mirror.allowed');
al = ins(al, "    return jsonb_build_object('ok', false, 'reason', 'Sign-in required.');\n  end if;\n",
  `  if not coalesce(public.session_fresh(), false) then\n    return jsonb_build_object('ok', false, 'reason', '${EXP}');\n  end if;\n`, 'allowed');
let wl = def('public.mirror_who_looked');
wl = ins(wl, "if public.autopay_view_as_session() then raise exception 'Not available while viewing as someone else.' using errcode = '42501'; end if;\n",
  `  if not coalesce(public.session_fresh(), false) then raise exception '${EXP}' using errcode = '42501'; end if;\n`, 'who_looked');
let wa = def('public.mirror_whoami');
wa = ins(wa, "if v_email is null then return jsonb_build_object('signed_in', false); end if;\n",
  `  -- a remembered device past its idle or maximum days counts as signed out: the page asks for a new code\n  if not coalesce(public.session_fresh(), false) then return jsonb_build_object('signed_in', false, 'expired', true); end if;\n`, 'whoami');
const head = `-- The Human Mirror, Phase 2 fix 5 of 15 (Stephen, 11/13/2026): the Mirror ignored session_fresh().
-- The rest of the site treats a remembered device past its idle or maximum days (session_idle_days_<role> / session_max_days_<role>,
-- or signed out everywhere) as signed out. The Mirror's own gates only checked that an email was present, so an expired device kept
-- working there. Now every Mirror identity gate also requires public.session_fresh():
--   mirror.me() (the person), mirror.signed_in_member_ok() (coordinators and admins; also used by my_role and is_platform_admin),
--   mirror.allowed() (the data gate, which reads the email itself), public.mirror_who_looked(), and public.mirror_whoami(), which now
--   answers signed_in = false, expired = true, so the existing pages send the person to the sign-in page for a new code.
-- Bodies below are the LIVE definitions of 11/13/2026 with only the session lines added. Shared session functions are not changed (D-22).
-- No table is created (no new grants); create or replace keeps each function's grants.

`;
fs.writeFileSync('supabase/migrations/20261119269000_mirror_session_fresh.sql', head + [me, sim, al, wl, wa].map((d) => d.trim() + ';\n').join('\n'));
console.log('written');
