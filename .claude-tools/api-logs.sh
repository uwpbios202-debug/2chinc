#!/usr/bin/env bash
# Read-only: query Supabase API request logs (edge_logs) for paths matching $1 over the last $2 hours (default 3).
set -euo pipefail
cd "$(dirname "$0")/.."
pat="${1:-chpms}"; hours="${2:-3}"
set -a; . ./.env.supabase; set +a
start="$(date -u -d "-$hours hours" +%Y-%m-%dT%H:%M:%SZ)"; end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sql="select timestamp, r.method, r.path, s.status_code from edge_logs cross join unnest(metadata) m cross join unnest(m.request) r cross join unnest(m.response) s where r.path like '%$pat%' order by timestamp desc limit 40"
curl -sS -G "https://api.supabase.com/v1/projects/hvnsgwfcjpakvhhkfsuy/analytics/endpoints/logs" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" --data-urlencode "sql=$sql" \
  --data-urlencode "iso_timestamp_start=$start" --data-urlencode "iso_timestamp_end=$end" | head -c 6000
echo
