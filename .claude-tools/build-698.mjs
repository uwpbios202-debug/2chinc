// Builds supabase/migrations/20261119698000_mirror_privacy_promises.sql from the live definitions in .claude-tools/fn/ plus new parts.
import fs from "node:fs";
const fn = (n) => fs.readFileSync(`.claude-tools/fn/${n}.sql`, "utf8").replace(/\r\n/g, "\n");
const rep = (s, a, b, name) => { if (!s.includes(a)) throw new Error(`${name}: not found: ${a.slice(0, 90)}`); return s.replace(a, b); };

let settings = fn("mirror_my_settings");
settings = rep(settings, "'safety_sensitive', i.safety_sensitive, 'deletion_requested_at', i.deletion_requested_at,",
  "'safety_sensitive', i.safety_sensitive, 'deletion_requested_at', i.deletion_requested_at, 'hidden_at', i.hidden_at,", "settings");

let people = fn("mirror_people");
people = rep(people, "where oi.organization_id = p_org), '[]'::jsonb);", "where oi.organization_id = p_org and i.hidden_at is null), '[]'::jsonb);   -- hidden: not listed", "people");

let audit = fn("mirror_org_audit");
audit = rep(audit, "'person_id', case when a.individual_id is not null and mirror.known_to_org(a.individual_id, p_org) then a.individual_id end,",
  "'person_id', case when a.individual_id is not null and i.hidden_at is null and mirror.known_to_org(a.individual_id, p_org) then a.individual_id end,", "audit1");
audit = rep(audit, "'person', case when a.individual_id is null then null when mirror.known_to_org(a.individual_id, p_org) then i.preferred_name",
  "'person', case when a.individual_id is null then null when i.hidden_at is null and mirror.known_to_org(a.individual_id, p_org) then i.preferred_name", "audit2");

let who = fn("mirror_whoami");
who = rep(who, "  v_state text;\nbegin", "  v_state text;\n  v_notice jsonb;\nbegin", "who1");
who = rep(who, "  return jsonb_build_object(\n    'signed_in', true,",
  `  -- privacy page promise: a change in how information is used or shared is shown at sign-in before it starts, until read
  begin v_notice := nullif(trim(coalesce((select value from public.portal_settings where key = 'mirror_change_notice'), '')), '')::jsonb;
  exception when others then v_notice := null; end;
  if v_notice is not null and (v_notice ->> 'id') is not null
     and exists (select 1 from mirror.profiles pr where pr.auth_email = v_email and pr.notice_seen = v_notice ->> 'id') then v_notice := null; end if;
  return jsonb_build_object(
    'signed_in', true,
    'change_notice', v_notice,`, "who2");

let del = fn("mirror_my_deletion");
del = rep(del, "jsonb_build_object('deletion_requested_at', deletion_requested_at,", "jsonb_build_object('deletion_requested_at', deletion_requested_at, 'hidden_at', hidden_at,", "del2");

let status = fn("mirror_person_status");
status = rep(status, "  select auth_email into v_email from mirror.individuals where id = p_individual;\n",
  "  select auth_email into v_email from mirror.individuals where id = p_individual;\n  if p_status <> 'ended' and exists (select 1 from mirror.individuals where id = p_individual and hidden_at is not null) then\n    raise exception 'This person cannot be restarted right now.' using errcode = '42501';\n  end if;\n", "status");

let add = fn("mirror_person_add");
add = rep(add, "  if v_id is null then\n    insert into mirror.individuals",
  "  if v_id is not null and exists (select 1 from mirror.individuals where id = v_id and hidden_at is not null) then\n    raise exception 'That email cannot be added. Call 2nd Chance at (262) 236-5443.' using errcode = '42501';\n  end if;\n  if v_id is null then\n    insert into mirror.individuals", "add");

const head = fs.readFileSync(".claude-tools/698-head.sql", "utf8");
const tail = fs.readFileSync(".claude-tools/698-tail.sql", "utf8");
const out = [head, "-- mirror_my_settings: live body; NEW: hidden_at", settings,
  "-- mirror_people: live body; NEW: a hidden person is not listed", people,
  "-- mirror_org_audit: live body; NEW: a hidden person is shown as 'A person not on your list'", audit,
  "-- mirror_whoami: live body; NEW: change_notice", who,
  "-- mirror_my_deletion: live body; NEW: returns hidden_at", del,
  "-- mirror_person_status: live body; NEW: a hidden person cannot be restarted or invited again", status,
  "-- mirror_person_add: live body; NEW: a hidden person's email cannot be added", add, tail].join("\n\n");
fs.writeFileSync("supabase/migrations/20261119698000_mirror_privacy_promises.sql", out.replace(/\n{3,}/g, "\n\n"));
console.log("written", out.length);
