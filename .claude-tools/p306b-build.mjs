// Builds 20261119286000 from the LIVE mirror_set_get body: the answer object gains version + reworded, the question gains version.
import fs from "node:fs";
const [live, out] = process.argv.slice(2);
let b = JSON.parse(fs.readFileSync(live, "utf8"))[0].d;
const a1 = "select jsonb_build_object('value', ca.value, 'state', ca.state, 'note', ca.note, 'by', ca.answered_by_role, 'at', ca.answered_at)";
const a2 = "'category', q.category, 'private', q.category <> 'general',";
if (!b.includes(a1) || !b.includes(a2)) throw new Error("anchors not found");
b = b.replace(a1, "select jsonb_build_object('value', ca.value, 'state', ca.state, 'note', ca.note, 'by', ca.answered_by_role, 'at', ca.answered_at,\n              'version', ca.question_version, 'reworded', ca.question_version <> q.version)");
b = b.replace(a2, "'category', q.category, 'private', q.category <> 'general', 'version', q.version,");
b = b.split("$function$").join("$setget$") + ";\n";
const head = `-- The Human Mirror, P3-06b (Stephen 11/13/2026: "go ahead"): the answering screen can say when an answer was given to an
-- earlier wording of the question (follow-up to fix 6, migration 20261119282000).
--  1. mirror.current_answers gains question_version as its LAST column (existing columns and their order unchanged, so every
--     user of the view keeps working).
--  2. mirror_set_get (live body of 11/13, migration 20261119190000) adds to each question 'version', and to each answer 'version'
--     (the wording it was given to) and 'reworded' (true when the question has been reworded since). Nothing else changes.
-- No table is created, so no new grants are needed (CLAUDE.md, 10/30/2026 rule); the view keeps its grants.

create or replace view mirror.current_answers as
  select a.individual_id, s.key as set_key, s.kind, q.key as question_key, q.category, r.value, r.state, r.note, r.answered_by_role, r.answered_at,
         r.question_version
  from mirror.assessment_responses r
  join mirror.assessments a on a.id = r.assessment_id
  join mirror.question_sets s on s.id = a.set_id
  join mirror.reflection_questions q on q.id = r.question_id
  where r.superseded_at is null;

`;
fs.writeFileSync(out, head + b);
console.log("built");
