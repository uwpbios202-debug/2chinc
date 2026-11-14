#!/bin/sh
# Bug-check segment 4: field staff, inspections, snow, keys, alarms (read-only)
B=https://2ndchinc.org
for p in /contractor/ /staff/snow/ /inspections/ /staff/keys/ /staff/alarms/; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$B$p")
  echo "$c $p"
done
Q=./.claude-tools/supa-query.sh
$Q "select (select count(*) from snow_agreements) agreements, (select count(*) from snow_visits) visits, (select count(*) from snow_visits where status='done' and completed_at < now()-interval '2 days' and reviewed_at is null) stuck_done, (select count(*) from email_outbox where kind='snow_move_notice' and sent_at is null) unsent_snow"
$Q "select id, public from storage.buckets where id in ('snow-photos','alarm-photos')"
$Q "select (select count(*) from alarm_points where active and unit_number is null) common_active, (select count(distinct p.id) from alarm_points p join alarm_checks c on c.alarm_id=p.id where p.active and p.unit_number is null and c.checked_at >= date_trunc('month', now())) common_checked_this_month, (select count(*) from alarm_points where active and installed_on is null) no_installed_on"
$Q "select count(*) unsent_alarm_mail from email_outbox where kind in ('alarm_attention','alarm_report') and sent_at is null"
