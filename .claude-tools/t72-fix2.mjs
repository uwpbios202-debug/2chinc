import fs from 'node:fs';
const f = 'tools/mirror-checks/t72-resource-suggestions-check.sql';
let s = fs.readFileSync(f, 'utf8');
const rep = (a, b) => { if (!s.includes(a)) throw new Error('missing: ' + a.slice(0, 70)); s = s.replace(a, b); };
rep(`  ok := not exists (select 1 from jsonb_array_elements(j -> 'matches') m, jsonb_array_elements(m -> 'programs') p
                     where not mirror.place_served(p ->> 'serves', 'outside'))
    and not exists`, `  ok := not exists`);
rep(`  ok := ok and not mirror.place_served('City of West Allis', 'milwaukee_city') and mirror.place_served('City of West Allis', 'milwaukee_county')
     and mirror.place_served('National (listed by City of Wauwatosa)', 'outside') and not mirror.place_served('Milwaukee County', 'wisconsin')
     and not mirror.place_served('Milwaukee County (HCV jurisdiction excludes City of Milwaukee/HACM and West Allis unless ported)', 'milwaukee_city');
`, '');
rep(`  begin truncate mirror.resource_suggestions;`, `  ok := ok and not mirror.place_served('City of West Allis', 'milwaukee_city') and mirror.place_served('City of West Allis', 'milwaukee_county')
     and mirror.place_served('National (listed by City of Wauwatosa)', 'outside') and not mirror.place_served('Milwaukee County', 'wisconsin')
     and not mirror.place_served('Milwaukee County (HCV jurisdiction excludes City of Milwaukee/HACM and West Allis unless ported)', 'milwaukee_city')
     and mirror.place_served('Greater Milwaukee / SE Wisconsin; all faiths', 'nearby_county') and not mirror.place_served('Greater Milwaukee / SE Wisconsin; all faiths', 'wisconsin');
  begin truncate mirror.resource_suggestions;`);
rep(`6 person removes one, enrolled drops the label, download has 2 with history; closed to browsers;`, `6 person removes one, enrolled drops the label, download has 2 with history; closed to browsers; place rules on 7 real area texts;`);
fs.writeFileSync(f, s);
