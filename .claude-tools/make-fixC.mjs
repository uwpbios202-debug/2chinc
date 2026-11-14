import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
const def = (f) => JSON.parse(execFileSync('sh', ['./.claude-tools/supa-query.sh', `select pg_get_functiondef('${f}'::regproc) d`]).toString())[0].d;
const rep = (src, from, to, label, times = 1) => {
  const n = src.split(from).length - 1;
  if (n !== times) throw new Error(`${label}: expected ${times} of [${from}], found ${n}`);
  return src.split(from).join(to);
};
const EXP = "Your sign-in on this device has expired. Please sign in again.";
const FRESH = "coalesce(public.session_fresh(), false)";

let me = def('mirror.me');
me = rep(me, `if not ${FRESH} then raise exception '${EXP}' using`, `if not mirror.session_ok() then raise exception '%', mirror.session_message() using`, 'me');
let sim = def('mirror.signed_in_member_ok');
sim = rep(sim, FRESH, 'mirror.session_ok()', 'sim');
let al = def('mirror.allowed');
al = rep(al, `if not ${FRESH} then\n    return jsonb_build_object('ok', false, 'reason', '${EXP}');`,
  `if not mirror.session_ok() then\n    return jsonb_build_object('ok', false, 'reason', mirror.session_message());`, 'allowed');
let wl = def('public.mirror_who_looked');
wl = rep(wl, `if not ${FRESH} then raise exception '${EXP}' using`, `if not mirror.session_ok() then raise exception '%', mirror.session_message() using`, 'who_looked');
let wa = def('public.mirror_whoami');
wa = rep(wa, "  v_invites int := 0;\n", "  v_invites int := 0;\n  v_state text;\n", 'whoami decl');
wa = rep(wa, `  -- a remembered device past its idle or maximum days counts as signed out: the page asks for a new code\n  if not ${FRESH} then return jsonb_build_object('signed_in', false, 'expired', true); end if;\n`,
  `  -- a device past its Mirror limits (or signed out everywhere) counts as signed out: the page asks for a new code.\n  -- A coordinator's screen lock is not signed out: the page asks for the authenticator code only.\n  v_state := mirror.session_state();\n  if v_state <> 'ok' and v_state <> 'locked' then return jsonb_build_object('signed_in', false, 'expired', true); end if;\n`, 'whoami gate');
wa = rep(wa, "    'signed_in', true,\n", "    'signed_in', true,\n    'locked', v_state = 'locked',\n    'session', jsonb_build_object('device', mirror.session_device(), 'limits', mirror.session_limits()),\n", 'whoami out');

const head = fs.readFileSync('.claude-tools/fixC-head.sql', 'utf8');
const tail = fs.readFileSync('.claude-tools/fixC-tail.sql', 'utf8');
fs.writeFileSync('supabase/migrations/20261119269500_mirror_session_limits.sql',
  head + '\n-- ---------------------------------------------------------------- the gates (LIVE bodies of 11/13/2026; only the session lines changed)\n\n'
  + [me, sim, al, wl, wa].map((d) => d.trim() + ';\n').join('\n') + '\n' + tail);
console.log('written');
