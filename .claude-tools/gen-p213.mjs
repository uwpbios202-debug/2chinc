// P2-13: build migration 20261119596000 from the LIVE bodies saved in the scratchpad (p213/*.sql), changing only the role checks.
// Every replacement must match exactly once, or the script stops. (one-off; not committed)
import fs from "node:fs";
const dir = process.argv[2];
const out = "supabase/migrations/20261119596000_mirror_one_place_for_rules.sql";
const body = (name, pairs) => {
  let s = fs.readFileSync(`${dir}/${name}.sql`, "utf8").trim();
  for (const [a, b] of pairs) {
    const n = typeof a === "string" ? s.split(a).length - 1 : (s.match(new RegExp(a.source, "g")) || []).length;
    if (n !== 1) { console.error(`${name}: expected 1 match, found ${n}: ${a}`); process.exit(1); }
    s = s.replace(a, b);
  }
  return s + ";\n";
};
const header = `-- The Human Mirror P2-13 (Phase 10 step 29; Stephen 11/13/2026 "go to phase 10"): one place for the access rules.
-- Before: mirror.role_permissions held what each role may see and change per topic, but several functions also decided by naming a role
-- in code ("org_admin", "coordinator"): who may open the workspace, manage members and services, read the organization's audit log,
-- confirm a need or a milestone, use the conversation guide. Changing the table did not change those.
-- Now (D-41): every such decision asks the table. Two capabilities join it: 'workspace' (view: work with the organization's people) and
-- 'confirm' (edit: confirm a need met or a milestone); 'organization' (edit) already meant managing members and services, 'audit'
-- (view) the organization's audit log. Helpers mirror.role_can(role, category, action) and mirror.i_can(org, category, action).
-- Behaviour is unchanged: the rows added give exactly the roles that had these powers (org_admin, coordinator). Role NAMES still appear
-- where they are identities, not permissions: the audit label, role ordering, "keep at least one organization admin", the role list a
-- member may be given, and a Navigator becoming the admin of their own business.
-- The function bodies below are the live ones (11/13/2026) with only the role checks changed.

alter table mirror.role_permissions drop constraint role_permissions_category_check;
alter table mirror.role_permissions add constraint role_permissions_category_check check (category = any (array['general', 'health',
  'mental_health', 'safety', 'safety_flag', 'legal', 'immigration', 'financial', 'documents', 'organization', 'audit', 'workspace', 'confirm']));
insert into mirror.role_permissions (role, category, action) values
  ('org_admin', 'workspace', 'view'), ('coordinator', 'workspace', 'view'),
  ('org_admin', 'confirm', 'edit'), ('coordinator', 'confirm', 'edit')
on conflict do nothing;

-- does this role have this permission? (null role: no)
create or replace function mirror.role_can(p_role text, p_category text, p_action text) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select p_role is not null and exists (select 1 from mirror.role_permissions p where p.role = p_role and p.category = p_category and p.action = p_action);
$$;
-- may I (signed in, authenticator, active member of this active organization) do this here?
create or replace function mirror.i_can(p_org uuid, p_category text, p_action text) returns boolean
language sql stable security definer set search_path = mirror, public as $$
  select coalesce(mirror.role_can(mirror.my_role(p_org), p_category, p_action), false);
$$;
revoke all on function mirror.role_can(text, text, text), mirror.i_can(uuid, text, text) from public, anon, authenticated;
grant execute on function mirror.role_can(text, text, text), mirror.i_can(uuid, text, text) to service_role;

`;
const parts = [
  body("mirror.coordinates", [["coalesce(mirror.my_role(p_org) in ('org_admin', 'coordinator'), false)", "mirror.i_can(p_org, 'workspace', 'view')"]]),
  body("mirror.can_manage_members", [["coalesce(mirror.my_role(p_org) = 'org_admin', false)", "mirror.i_can(p_org, 'organization', 'edit')"]]),
  body("mirror.platform_outside", [["coalesce(mirror.my_role(p_org) = 'org_admin', false)", "mirror.i_can(p_org, 'organization', 'edit')"]]),
  body("mirror.authenticator_reset_refusal", [["coalesce(mirror.my_role(p_org) = 'org_admin', false)", "mirror.i_can(p_org, 'organization', 'edit')"]]),
  body("mirror.conv_member", [["om.role in ('coordinator', 'org_admin')", "mirror.role_can(om.role, 'workspace', 'view')"]]),
  body("public.mirror_admin_orgs", [["m.role = 'org_admin')", "mirror.role_can(m.role, 'organization', 'edit'))"],
                                    ["mirror.my_role(o.id) = 'org_admin'", "mirror.i_can(o.id, 'organization', 'edit')"]]),
  body("public.mirror_need_status", [["(g ->> 'role') not in ('coordinator', 'org_admin')", "not mirror.role_can(g ->> 'role', 'confirm', 'edit')"]]),
  body("public.mirror_milestone_confirm", [["(gate ->> 'role') not in ('coordinator', 'org_admin')", "not mirror.role_can(gate ->> 'role', 'confirm', 'edit')"]]),
  body("public.mirror_org_audit", [[/if coalesce\(mirror\.my_role\(p_org\), ''\) <> 'org_admin'\s+or not exists \(select 1 from mirror\.role_permissions p where p\.role = 'org_admin' and p\.category = 'audit' and p\.action = 'view'\) then/,
                                    "if not mirror.i_can(p_org, 'audit', 'view') then"]]),
  body("public.mirror_services", [["v_admin := coalesce(mirror.my_role(p_org), '') = 'org_admin';", "v_admin := mirror.i_can(p_org, 'organization', 'edit');"]]),
  body("public.mirror_admin_authenticator_reset", [["coalesce(mirror.is_platform_admin(), false) and coalesce(mirror.my_role(p_org), '') <> 'org_admin'", "mirror.platform_outside(p_org)"]]),
  body("public.mirror_service_save", [["or coalesce(mirror.my_role(v_org), '') <> 'org_admin' then", "or not mirror.i_can(v_org, 'organization', 'edit') then"]]),
];
fs.writeFileSync(out, header + parts.join("\n"));
console.log("wrote " + out + " (" + parts.length + " functions)");
