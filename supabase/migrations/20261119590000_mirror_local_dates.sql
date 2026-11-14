-- The Human Mirror: "today" is Milwaukee's day, not UTC's (found 11/13/2026 by check t88 at 8:30 pm Central, when UTC is already the
-- next day). The database runs in UTC, so current_date and the column defaults current_date (milestones.achieved_on,
-- service_enrollments.started_on, inventory_given.given_on) gave tomorrow's date every evening after 6 pm (7 pm in summer): a service
-- started tonight, a gift given tonight or a milestone reached tonight fell outside a report or a count that ends today, and "ended on",
-- hope-by comparisons and the dashboard's "this week" were a day off in the evening.
-- Fix: the Mirror functions that use the date run with the session time zone America/Chicago (a per-function setting, like search_path).
-- Inside them current_date, ::date of a timestamp and the column defaults all give Milwaukee's date. Nothing else in the database
-- changes (the property-management functions keep UTC); no data is rewritten (the past stays as it was).

do $tz$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in (
              'mirror_consents_recorded', 'mirror_enrollment_save', 'mirror_goal_save', 'mirror_inventory', 'mirror_milestone_save',
              'mirror_my_invitation_answer', 'mirror_my_org_end', 'mirror_my_settings', 'mirror_person_add', 'mirror_person_status',
              'mirror_progress', 'mirror_workspace_dashboard', 'mirror_inventory_give', 'mirror_org_report', 'mirror_people_counts',
              'mirror_services', 'mirror_enrollments', 'mirror_received', 'mirror_my_export_services', 'mirror_my_export_received')
  loop
    execute format('alter function %s set timezone = %L', f, 'America/Chicago');
  end loop;
end $tz$;
