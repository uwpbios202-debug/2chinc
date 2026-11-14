// Makes the sequestered copies of the two checks that relied on "2nd Chance org admin = platform admin" (finding E).
import fs from 'node:fs';
const add = (src, anchor, extra, label) => {
  if (src.split(anchor).length !== 2) throw new Error('anchor not unique/found: ' + label);
  return src.replace(anchor, anchor + extra);
};
const out = '.claude-tools/sequestered-E/tools/mirror-checks/';
fs.mkdirSync(out, { recursive: true });

let t25 = fs.readFileSync('tools/mirror-checks/t25-admin-people-check.sql', 'utf8');
t25 = add(t25, "    (owner, 'check.owner.coord@example.invalid', 'CHECK Owner Coordinator', 'coordinator');\n",
  "  -- since migration 20261119269700 (finding E) platform admin is an explicit list, not \"org admin of 2nd Chance\"\n" +
  "  insert into mirror.platform_admins (auth_email, name, added_by) values ('check.padmin@example.invalid', 'CHECK Platform Admin', 'check');\n", 't25');
fs.writeFileSync(out + 't25-admin-people-check.sql', t25);

let f4 = fs.readFileSync('tools/mirror-checks/p2-fix04-platform-admin-visible-check.sql', 'utf8');
f4 = add(f4, "values (owner, 'check.padmin4@example.invalid', 'CHECK Platform Admin', 'org_admin');\n",
  "  -- since migration 20261119269700 (finding E) platform admin is an explicit list, not \"org admin of 2nd Chance\"\n" +
  "  insert into mirror.platform_admins (auth_email, name, added_by) values ('check.padmin4@example.invalid', 'CHECK Platform Admin', 'check');\n", 'fix04');
fs.writeFileSync(out + 'p2-fix04-platform-admin-visible-check.sql', f4);
console.log('ok');
