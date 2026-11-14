-- 2nd Chance Housing Inc owner sign-in: one office email and mobile for every
-- unit the company owns (Units 2, 3, 4, 5, 11 and 14). The email gets the
-- sign-in code and the mobile gets the texted code (condo_mfa_phone_for reads
-- condo_owners.phone_mobile). Earlier ids 2778252 and 2780123 are the two
-- Earlier records the seed merged into this one owner.
update condo_owners
   set email = 'info@2ndchinc.org',
       phone_mobile = '(262) 236-5443'
 where legacy_ids && array['2778252', '2780123'];
