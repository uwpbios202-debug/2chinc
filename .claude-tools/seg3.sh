#!/bin/sh
# Bug-check segment 3: staff and office screens status codes + portal script cache header
B=https://2ndchinc.org
for p in /staff/ /staff/view-as/ /staff/w9/ /assets/portal/staff-nav.js \
  /accounting/assistance/ /accounting/autopay/ /accounting/bank/ /accounting/bank/units/ /accounting/costs/ /accounting/disputes/ /accounting/reports/ /accounting/tenant-side/payments/ \
  /association-owners/roca1/board/ /association-owners/roca1/distributions/ /association-owners/roca1/dues/ /association-owners/roca1/records/ /association-owners/roca1/requests/ /association-owners/roca1/staff/ /association-owners/roca1/violations/ \
  /documents/letters/ /documents/notices/ /inspections/move-in/ /inspections/move-out/ /inspections/review/ /inspections/schedule/ \
  /leasing/applications/ /leasing/countersign/ /leasing/household/ /leasing/leases/ /leasing/renewals/ /leasing/work/ /maintenance/ /parking/ /resident/messages/ \
  /staff/aid/ /staff/alarms/ /staff/caseworkers/ /staff/deeds/ /staff/deeds/transfer/ /staff/dues-pay/ /staff/efile/ /staff/email/ /staff/eviction-costs/ /staff/field-staff/ \
  /staff/keys/ /staff/navigators/ /staff/pma/ /staff/rebates/ /staff/reports/ /staff/resources/ /staff/snow/ /staff/waitlist/
do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$B$p")
  [ "$c" = "200" ] || echo "NOT 200: $c $p"
done
echo "pages checked"
printf 'portal.js cache-control: '
curl -sI "$B/assets/portal/portal.js" | grep -i '^cache-control' || echo "(none)"
