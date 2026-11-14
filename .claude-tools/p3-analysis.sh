#!/bin/sh
# Read-only Phase 3 (Individual Mirror) analysis checks
B=https://2ndchinc.org/mirror
for p in /my-mirror/ /my-mirror/today/ /my-mirror/history/ /my-mirror/vision/ /my-mirror/strengths/ /my-mirror/needs/ /my-mirror/abilities/ /my-mirror/preferences/ /my-mirror/contribution/ /my-mirror/life/ /my-mirror/life/housing/ /my-mirror/life/physical-health/ /my-mirror/life/mental-health/ /my-mirror/life/identity-legal/ /my-mirror/life/food/ /my-mirror/life/transportation/ /my-mirror/life/technology/ /my-mirror/life/work/ /my-mirror/life/finances/ /my-mirror/life/self-care/ /my-mirror/life/relationships/ /my-mirror/life/life-skills/ /my-mirror/life/safety/ /my-mirror/life/development/ /my-mirror/life/purpose/ /my-mirror/settings/ /assets/assessment-engine.js /assets/reflection-page.js /assets/mirror-voice.js /assets/mirror-client.js; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$B$p")
  [ "$c" = "200" ] || echo "NOT 200: $c $p"
done
echo "pages checked"
Q=./.claude-tools/supa-query.sh
$Q "select s.kind, count(distinct s.id) sets, count(q.id) questions, count(q.id) filter (where q.privacy_category <> 'general') private_q from mirror.question_sets s left join mirror.reflection_questions q on q.set_id=s.id group by 1"
$Q "select answer_type, count(*) from mirror.reflection_questions group by 1 order by 2 desc"
$Q "select (select count(*) from mirror.reflections) reflections, (select count(*) from mirror.dimensions) dimensions, (select count(*) from mirror.assessments) assessments, (select count(*) from mirror.assessment_responses) responses, (select count(distinct person_id) from mirror.assessments) people_with_answers"
$Q "select table_name, table_type from information_schema.tables where table_schema='mirror' order by 1"
$Q "select p.proname, p.prosecdef, has_function_privilege('anon', p.oid, 'execute') anon_exec from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'mirror%' order by 1"
$Q "select tgname, tgrelid::regclass from pg_trigger where tgrelid::regclass::text like 'mirror.%' and not tgisinternal order by 2"
$Q "select key, value from public.portal_settings where key like 'mirror%'"
