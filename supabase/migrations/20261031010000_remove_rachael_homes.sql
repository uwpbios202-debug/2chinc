-- Unit 17 is owned by Mark Postler. Rachael Homes LLC (earlier id 2786687, a
-- former Unit 17 owner) is removed entirely, as Stephen directed 10/5/2026:
-- its owner record, its Unit 17 ownership, and its association ledger.
-- Mark Postler's Unit 17 ownership and ledger are untouched.
update payment_reports set owner_id = null, condo_account_id = null
 where owner_id in (select id from condo_owners where '2786687' = any(legacy_ids))
    or condo_account_id in (select id from condo_ledger_accounts where legacy_owner_label = 'Rachael Homes LLC');

delete from condo_collection_steps where account_id in (select id from condo_ledger_accounts where legacy_owner_label = 'Rachael Homes LLC');
delete from condo_ledger_accounts where legacy_owner_label = 'Rachael Homes LLC';  -- entries cascade
delete from condo_ownerships where owner_id in (select id from condo_owners where '2786687' = any(legacy_ids));
delete from condo_owners where '2786687' = any(legacy_ids);
