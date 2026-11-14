-- The system must read as new (Stephen, 10/13/2026): no note an owner, tenant or buyer can see may refer to a previous system or
-- to who corrected what. Only the explanatory TEXT is cleared; no amount, date, account or ledger line is touched or recomputed.
--   * account / lease notes that say the old system mislabeled, never posted, or entered something wrongly: cleared
--   * a land-contract line that says the old system booked it as a deposit: reworded to say only what it was
-- Staff attributions ("Verified via staff by ...") and the goodwill-credit explanation are not about a previous system and stay.

update condo_ledger_accounts set correction_note = null
 where correction_note ~* 'old system|legacy|mislabel';

update leases set correction_note = null
 where correction_note ~* 'old system|legacy|mislabel';

update lease_ledger_entries set correction_note = null
 where correction_note ~* 'old system|legacy|mislabel';

update land_contract_ledger
   set correction_note = regexp_replace(correction_note, '\s*Legacy booked this as a lease security deposit\.', ' This was held as a lease security deposit.')
 where correction_note ~* 'legacy';
update land_contract_ledger set correction_note = null where correction_note ~* 'old system|legacy|mislabel';
