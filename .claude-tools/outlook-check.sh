#!/bin/sh
check() {
  printf '%-40s ' "$1"
  curl -s -o /dev/null -m 15 -w '%{http_code} %{time_total}s ip=%{remote_ip}\n' "$1" || echo "FAILED (curl exit $?)"
}
check https://outlook.live.com/mail/
check https://outlook.office.com/mail/
check https://outlook.office365.com/
check https://login.live.com/
check https://login.microsoftonline.com/
check https://www.microsoft.com/
check https://www.google.com/
nslookup outlook.live.com 2>&1 | tail -4
nslookup outlook.office.com 2>&1 | tail -4
