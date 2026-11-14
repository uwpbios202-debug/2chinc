#!/bin/sh
Q=./.claude-tools/supa-query.sh
$Q "select s.kind, count(distinct s.id) sets, count(q.id) questions, count(q.id) filter (where q.category <> 'general') private_q from mirror.question_sets s left join mirror.reflection_questions q on q.set_id=s.id group by 1"
$Q "select (select count(*) from mirror.reflections) reflections, (select count(*) from mirror.dimensions) dimensions, (select count(*) from mirror.assessments) assessments, (select count(*) from mirror.assessments where completed_at is not null) completed, (select count(*) from mirror.assessment_responses) responses, (select count(*) from mirror.assessment_responses where superseded_at is not null) superseded, (select count(distinct individual_id) from mirror.assessments) people_with_answers, (select count(*) from mirror.individuals) individuals"
$Q "select p.proname, p.prosecdef sd, array_to_string(p.proconfig, ';') cfg from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'mirror%' order by 1"
$Q "select pg_get_functiondef('mirror.assessment_responses_append_only'::regproc) def"
$Q "select grantee, privilege_type from information_schema.role_table_grants where table_schema='mirror' and table_name in ('assessment_responses','reflection_questions') and grantee in ('anon','authenticated','service_role') order by 1,2"
