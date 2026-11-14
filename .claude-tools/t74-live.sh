#!/bin/sh
for u in https://2ndchinc.org/mirror/my-mirror/documents/ https://2ndchinc.org/mirror/workspace/documents/ https://2ndchinc.org/mirror/assets/mirror-docs.js?v=20261113a https://2ndchinc.org/mirror/my-mirror/ https://2ndchinc.org/mirror/my-mirror/settings/; do
  printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' "$u")"; echo "$u"
done
printf 'function without sign-in: '; curl -s -o /dev/null -w '%{http_code}\n' -X POST https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/mirror-files -H 'Content-Type: application/json' -d '{"action":"open","id":"x"}'
