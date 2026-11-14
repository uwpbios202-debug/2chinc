#!/bin/sh
# Builds the public website for Cloudflare Pages into dist/.
# ALLOWLIST ONLY: everything published lives under site/. The rest of this repo
# (prospects, templates with signatures, tools) must never be published.
#
# Cloudflare Pages settings: build command `sh build.sh`, output directory `dist`.
set -e
rm -rf dist
mkdir -p dist
cp -R site/. dist/
# Leasing apply/sign, the resident portal, and the staff pages ship only once their
# backends (rental-apply and lease-signing functions + migrations) are on the live
# project: run with INCLUDE_APPLY=1.
if [ "${INCLUDE_APPLY:-0}" != "1" ]; then
  rm -rf dist/resident dist/staff dist/inspections \
    dist/leasing/apply dist/leasing/sign dist/leasing/applications dist/leasing/leases \
    dist/inspections/move-in dist/inspections/move-out dist/leasing/renewals dist/leasing/countersign \
    dist/maintenance dist/documents/letters dist/documents/notices \
    dist/accounting/tenant-side/payments dist/investor
else
  # Staff lease builder ("Prepare lease" on the applications page). Copied in on its own:
  # the rest of templates/ stays unpublished. It has no signature images; the agent's
  # signature is applied only at countersigning.
  mkdir -p dist/leasing/prepare
  cp templates/lease-agreement/index.html dist/leasing/prepare/index.html
fi
# Investor desk scripts are cached by browsers for 4 hours; stamp a fresh version on every build so a deploy always takes effect.
if [ -f dist/investor/desk/index.html ]; then
  V=$(date +%s)
  sed -i "s|\(desk/[a-z]*\.js\)?v=[0-9]*|\1?v=$V|g" dist/investor/desk/index.html
fi
echo "Built dist/:" && find dist -type f
