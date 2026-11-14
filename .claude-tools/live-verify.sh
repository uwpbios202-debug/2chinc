#!/bin/sh
# Read-only: check the pages just deployed are live with the new code.
echo "conversation (person):    $(curl -s -o /dev/null -w '%{http_code}' https://2ndchinc.org/mirror/my-mirror/conversation/)"
echo "conversation (workspace): $(curl -s -o /dev/null -w '%{http_code}' https://2ndchinc.org/mirror/workspace/conversation/)"
echo "settings:                 $(curl -s -o /dev/null -w '%{http_code}' https://2ndchinc.org/mirror/my-mirror/settings/)"
echo "settings calls conversations export: $(curl -s https://2ndchinc.org/mirror/my-mirror/settings/ | grep -c mirror_my_export_conversations)"
echo "daily-number cTaxMsg/cSay matches: $(curl -s https://2ndchinc.org/mirror/daily-number/ | grep -c 'cTaxMsg\|cSay')"
echo "admin platform section matches: $(curl -s https://2ndchinc.org/mirror/admin/ | grep -c 'mirror_platform_admins\|2nd Chance platform admins')"
echo "home: $(curl -s -o /dev/null -w '%{http_code}' https://2ndchinc.org/)  mirror: $(curl -s -o /dev/null -w '%{http_code}' https://2ndchinc.org/mirror/)"
