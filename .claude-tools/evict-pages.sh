#!/usr/bin/env bash
# Read-only: status codes of the eviction pages and assets.
for u in https://2ndchinc.org/staff/efile/ https://2ndchinc.org/documents/notices/ https://2ndchinc.org/assets/portal/court-forms.js https://2ndchinc.org/assets/portal/court-packet.js https://2ndchinc.org/assets/portal/proof-upload.js https://2ndchinc.org/assets/portal/envelope.js https://2ndchinc.org/assets/forms/SC-500_es.pdf https://2ndchinc.org/assets/forms/SC-5100V.pdf; do
  echo "$(curl -s -o /dev/null -w '%{http_code}' "$u") $u"
done
curl -s https://2ndchinc.org/assets/portal/court-forms.js | grep -c "export async function serviceRequest"
curl -s https://2ndchinc.org/staff/efile/ | grep -c "Claude checked the affidavit"
