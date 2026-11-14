-- The alarm tables are reached only through the alarm_* functions (security definer). The project still applied its
-- default grants to anon and authenticated on 11/5/2026; row security already blocked them, and per the grants rule
-- (CLAUDE.md, 10/30/2026) they get no direct access at all. service_role keeps everything.
revoke all on table alarm_points, alarm_checks, alarm_reports from anon, authenticated;
grant all on table alarm_points, alarm_checks, alarm_reports to service_role;
