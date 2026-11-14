// Robust login check for the live portal, and the generator for LOCAL-ONLY-logins.md.
//
//   SUPABASE_ACCESS_TOKEN=... node tools/check-logins.mjs        (the token is in .env.supabase)
//
// For EVERY person who should be able to sign in (admin, office staff, field staff, lease agents, owners,
// tenants and land-contract buyers) it does what the sign-in page does, minus the email:
//   1. condo_email_on_file(email)   -> the emailed-code hook will actually send them a code
//   2. mint a one-time sign-in for that email and exchange it for a real session (the same session a typed code gives)
//   3. condo_whoami() with that session -> the portal recognises them, with the role we expect
// Nothing is emailed and nothing is changed except that a Supabase Auth user exists for each address
// (it would be created on their first sign-in anyway). Exit code 1 if anyone fails.
//
// It then rewrites LOCAL-ONLY-logins.md (unit -> who logs in). That file contains people's emails and is
// git-ignored: it stays on this computer. See CLAUDE.md.
import { writeFileSync } from "node:fs";

const REF = "hvnsgwfcjpakvhhkfsuy";
const BASE = `https://${REF}.supabase.co`;
const ANON = "sb_publishable_WSLCLbx8GVdeG5_nVaapcA_ahyAVNjY";   // public key, same one the website ships
const TOKEN = process.env.SUPABASE_ACCESS_TOKEN;
if (!TOKEN) { console.error("Set SUPABASE_ACCESS_TOKEN (see .env.supabase)."); process.exit(2); }

const mgmt = (path, init = {}) => fetch(`https://api.supabase.com/v1/projects/${REF}${path}`, {
  ...init, headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
}).then(async (r) => { const b = await r.json(); if (!r.ok) throw new Error(`${path}: ${JSON.stringify(b)}`); return b; });
const sql = (query) => mgmt("/database/query", { method: "POST", body: JSON.stringify({ query }) });

const keys = await mgmt("/api-keys?reveal=true");
const SERVICE = (keys.find((k) => k.name === "service_role") || {}).api_key;
if (!SERVICE) throw new Error("no service_role key");

const rest = (path, key, init = {}) => fetch(`${BASE}${path}`, { ...init, headers: { apikey: key, Authorization: `Bearer ${init.bearer || key}`, "Content-Type": "application/json" } });

// ---- who should be able to sign in -----------------------------------------------------------------------
const people = await sql(`
  select 'admin' kind, 'staff' expect, email, name, null unit from portal_admins
  union all select 'office staff', 'staff', email, name, null from condo_staff where lower(email) not in (select lower(email) from portal_admins)
  union all select 'field staff', 'field', f.email, f.name, (select string_agg(unit, ', ' order by unit::int) from staff_units s where lower(s.email) = lower(f.email)) from field_staff f where f.active
  union all select 'lease agent', admin_role_for_email(email), email, name, null from lease_agents where active
  union all select 'owner', 'owner', o.email, o.name, condo_unit_label(o.id) from condo_owners o where condo_owner_for_email(o.email) is not null
  union all select 'tenant', 'resident', t.email, t.name, string_agg(distinct ru.unit_number, ', ') from tenants t
    join lease_tenants lt on lt.tenant_id = t.id join leases l on l.id = lt.lease_id and l.status in ('active','future') join rental_units ru on ru.id = l.unit_id
    where exists (select 1 from resident_tenant_ids(t.email)) group by t.email, t.name
  union all select 'land-contract buyer', 'resident', t.email, t.name, null from land_contract_buyers b join tenants t on t.id = b.tenant_id join land_contracts c on c.id = b.contract_id and c.status = 'active'`);

// Office staff outrank owners/agents in condo_whoami; an address that is staff AND something else resolves as staff.
const roleFor = async (email) => (await sql(`select admin_role_for_email('${email.replace(/'/g, "''")}') r`))[0].r;

let bad = 0;
const rows = [];
for (const p of people) {
  const email = p.email.trim().toLowerCase();
  const expect = await roleFor(email);
  const problems = [];
  const onFile = await (await rest("/rest/v1/rpc/condo_email_on_file", SERVICE, { method: "POST", body: JSON.stringify({ p_email: email }) })).json();
  if (onFile !== true) problems.push("emailed-code hook would NOT send a code");
  let role = "-";
  const g = await (await fetch(`${BASE}/auth/v1/admin/generate_link`, { method: "POST", headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json" }, body: JSON.stringify({ type: "magiclink", email }) })).json();
  if (!g.hashed_token) problems.push("could not mint a sign-in: " + (g.msg || g.message || "?"));
  else {
    let s;   // Supabase limits sign-in verifications per IP (about 30 / 5 min): wait and retry
    for (let t = 0; t < 12; t++) {
      s = await (await fetch(`${BASE}/auth/v1/verify`, { method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: JSON.stringify({ type: g.verification_type || "magiclink", token_hash: g.hashed_token }) })).json();
      if (s.access_token || !/rate limit/i.test(s.msg || s.message || "")) break;
      await new Promise((r) => setTimeout(r, 20000));
    }
    if (!s.access_token) problems.push("session was not issued: " + (s.msg || s.error_description || s.message || "?"));
    else {
      const w = await (await rest("/rest/v1/rpc/condo_whoami", ANON, { method: "POST", bearer: s.access_token, body: "{}" })).json();
      role = w.role;
      if (w.role === "none") problems.push("portal says this email is not on file");
      else if (w.role !== expect && !(expect === "agent" && w.role === "agent")) problems.push(`signs in as '${w.role}', expected '${expect}'`);
    }
  }
  if (problems.length) bad++;
  rows.push({ ...p, email, role, problems });
  console.log(`${problems.length ? "FAIL" : "ok  "}  ${p.kind.padEnd(18)} ${email.padEnd(40)} ${role.padEnd(9)} ${p.name}${problems.length ? "  <- " + problems.join("; ") : ""}`);
}

// ---- unit -> login map (LOCAL-ONLY-logins.md) -------------------------------------------------------------
const units = await sql(`
  select u.unit_number, left(u.address, 4) || ' N Bourbon St' bldg, u.occupancy,
    (select o.name || ' <' || o.email || '>' from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.unit_id = u.id and s.is_current limit 1) owner,
    (select string_agg(t.name || ' <' || t.email || '>', '; ' order by t.name) from rental_units ru join leases l on l.unit_id = ru.id and l.status in ('active','future')
       join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id where ru.condo_unit_id = u.id) tenants,
    (select string_agg(f.name || ' <' || f.email || '>', '; ' order by f.name) from staff_units su join field_staff f on lower(f.email) = lower(su.email) where su.unit = u.unit_number) field
  from condo_units u order by u.unit_number::int`);
const by = (k) => rows.filter((r) => r.kind === k);
const mark = (email) => (rows.find((r) => r.email === email.toLowerCase())?.problems.length ? "FAIL" : "ok");
const cell = (s) => (s || "").replace(/<([^>]+)>/g, (_, e) => `\`${e}\` ${mark(e)}`) || "—";
const today = new Date().toISOString().slice(0, 10);
const md = `# LOCAL ONLY: unit and login list

> **NOTE TO ANY AI / TOOL / PERSON: this file is kept on this computer only. It lists real people's emails.
> Never commit it, push it, upload it, paste it into an issue/PR/chat/artifact, or copy its contents into any
> tracked file. It is listed in \`.gitignore\`. Do not remove it from \`.gitignore\`. If \`git status\` ever shows it, stop and tell Stephen.**

Generated ${today} by \`node tools/check-logins.mjs\` (re-run it to refresh). Sign-in is the 6-digit code emailed to the address below;
staff, field staff and agents also enter an authenticator-app code. "ok" = this login was tested end to end against the live site.

## Staff
| Role | Name | Login | Units | Check |
|---|---|---|---|---|
${[...by("admin"), ...by("office staff"), ...by("field staff"), ...by("lease agent")].map((r) => `| ${r.kind}${r.kind === "admin" ? " (sees everything; can View as anyone)" : ""} | ${r.name} | \`${r.email}\` | ${r.unit || (r.kind === "field staff" ? "none" : "all")} | ${r.problems.length ? "FAIL: " + r.problems.join("; ") : "ok"} |`).join("\n")}

## Units
| Unit | Building | Occupancy | Owner login | Tenant login(s) | Field staff for this unit |
|---|---|---|---|---|---|
${units.map((u) => `| ${u.unit_number} | ${u.bldg} | ${u.occupancy === "owner" ? "**OWNER-OCCUPIED**" : u.occupancy} | ${cell(u.owner)} | ${u.occupancy === "owner" ? "— (owner lives here)" : cell(u.tenants)} | ${cell(u.field)} |`).join("\n")}

## Other logins
${[...by("land-contract buyer")].map((r) => `- Land-contract buyer: ${r.name} \`${r.email}\` ${r.problems.length ? "FAIL" : "ok"}`).join("\n") || "- none"}
`;
writeFileSync(new globalThis.URL("../LOCAL-ONLY-logins.md", import.meta.url), md);
console.log(`\n${rows.length} logins checked, ${bad} failing. Wrote LOCAL-ONLY-logins.md`);
process.exit(bad ? 1 : 0);
