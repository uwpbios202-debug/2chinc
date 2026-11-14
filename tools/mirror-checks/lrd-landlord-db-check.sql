-- Landlord Recruitment Database check (migrations 20261119420000 + 20261119421000). Fictional Navigators and staff; always rolled back.
-- Run: build a file of both migrations + lrd-landlord-db-check-part1.sql + the seed again, then
--      sh ./.claude-tools/mirror-rollback-check.sh <that file> tools/mirror-checks/lrd-landlord-db-check.sql
-- Part 1 leaves its results in the temp table lrd_chk; this file adds the re-import check and raises them all.
do $chk$
declare r text[]; ok boolean;
begin
  select array_agg(line order by n) into r from lrd_chk;
  -- 8 a second import keeps the office and Navigator work (status, do-not-contact, claim, sign-up, office lead)
  ok := (select contact_status = 'Signed up' and nav_landlord_id is not null from lrd_landlords where landlord_id = 'LLS-PM02')
    and (select contact_status = 'Do not contact' and do_not_contact from lrd_landlords where landlord_id = 'LLS-PM03')
    and (select contact_status = 'Not contacted' from lrd_landlords where landlord_id = 'LLS-PM05')
    and (select count(*) = 42 from lrd_landlords) and (select count(*) = 1 from lrd_landlords where is_local)
    and (select owner_or_company_name = 'CHECK OFFICE LEAD' from lrd_landlords where is_local);
  r := r || format('8 re-import keeps signed-up, do-not-contact and office lead: %s', ok);
  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
