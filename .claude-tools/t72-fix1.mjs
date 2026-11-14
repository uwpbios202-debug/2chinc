import fs from 'node:fs';
const f = 'supabase/migrations/20261119410000_mirror_resource_suggestions.sql';
let s = fs.readFileSync(f, 'utf8');
const rep = (a, b) => { if (!s.includes(a)) throw new Error('missing: ' + a.slice(0, 70)); s = s.replace(a, b); };
rep(`--     The place and the groups belong to the person alone: only the person sees or changes them, and they are used only when the person
--     looks (a coordinator's list is matched on needs and household only, so nothing private shows through the order).`,
`--     The place, the groups and the household groups are used only when the person looks: a coordinator's list is matched on needs
--     and areas only, so nothing private shows through what is left out or the order. Only the person sees or changes place and groups.`);
rep(`    select unnest(case when p_self then coalesce((select rp.groups from mirror.resource_profiles rp where rp.individual_id = p_individual), '{}') else '{}' end) g
    union all
    select 'Families with children' where exists (select 1 from mirror.household_members h
      where h.individual_id = p_individual and h.relationship = 'child' and h.lives_with)
    union all
    select 'Seniors' where exists (select 1 from mirror.individuals i
      where i.id = p_individual and i.birth_year is not null and extract(year from now())::int - i.birth_year >= 62)) x);`,
`    select unnest(coalesce((select rp.groups from mirror.resource_profiles rp where rp.individual_id = p_individual), '{}')) g where p_self
    union all
    select 'Families with children' where p_self and exists (select 1 from mirror.household_members h
      where h.individual_id = p_individual and h.relationship = 'child' and h.lives_with)
    union all
    select 'Seniors' where p_self and exists (select 1 from mirror.individuals i
      where i.id = p_individual and i.birth_year is not null and extract(year from now())::int - i.birth_year >= 62)) x);`);
rep(`    'household_groups', to_jsonb(mirror.resource_groups(v_id, false)),`,
`    'household_groups', case when v_self then to_jsonb(array(select x from unnest(mirror.resource_groups(v_id, true)) x
                          where x not in (select unnest(coalesce((select rp.groups from mirror.resource_profiles rp where rp.individual_id = v_id), '{}'))))) end,`);
rep(`  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if coalesce(p_status, '') not in`, `  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_from text;
begin
  if coalesce(p_status, '') not in`);
rep(`  if p_status = s.status then return mirror.resource_suggestion_json(s); end if;`,
`  if p_status = s.status then return mirror.resource_suggestion_json(s); end if;
  v_from := s.status;`);
rep(`  values (s.id, (select e.to_status from mirror.resource_suggestion_events e where e.suggestion_id = s.id order by e.at desc, e.id desc limit 1),
          p_status, v_note, lower(auth.email()), g ->> 'role');`, `  values (s.id, v_from, p_status, v_note, lower(auth.email()), g ->> 'role');`);
fs.writeFileSync(f, s);
