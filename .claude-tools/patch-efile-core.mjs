// One-off: adapts the extracted efile_core function for notices that say "within N days from service" (no fixed pay-by date).
import fs from 'node:fs';
const f = process.argv[2];
let c = fs.readFileSync(f, 'utf8');
const rep = (a, b) => { if (!c.includes(a)) throw new Error('missing: ' + a.slice(0, 70)); c = c.replace(a, b); };
rep("    if v_payby is null then\n",
  "    if v_payby is null and txt ~* ('within ' || v_days || ' days from service') then\n"
  + "      checks := checks || jsonb_build_object('level', 'ok', 'title', 'Notice gives ' || v_days || ' days from service', 'detail', 'No fixed pay-by date: the wording Milwaukee County has accepted for years. With the stamp date ' || to_char(n.served_on, 'FMMonth FMDD') || ' as day 1, the ' || v_days || ' days end ' || to_char(v_min, 'FMDay, FMMonth FMDD, YYYY') || '.');\n"
  + "    elsif v_payby is null then\n");
const mustPay = "  if m is null then m := regexp_match(txt, 'You must pay \\$([0-9,]+\\.[0-9]{2})', 'i'); end if;";
rep(mustPay, mustPay + "\n  if m is null then m := regexp_match(txt, 'unless you pay the total unpaid rent of \\$([0-9,]+\\.[0-9]{2})', 'i'); end if;");
rep("|| ' on or before ' || coalesce(to_char(v_payby, 'FMMonth FMDD, YYYY'), '?')", "|| ' within ' || coalesce(v_days::text, '?') || ' days from service'");
fs.writeFileSync(f, c);
console.log('patched');
