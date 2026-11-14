-- Housing Navigator pay: no figures yet (Stephen, 11/11/2026). The milestones stay; every amount is $0 and switched off
-- until the office hears how the Navigator is paid now and sets the plan on https://2ndchinc.org/staff/navigators/#pay .
-- With amount 0 / off, nav_earn() records nothing.
update nav_pay_plan set amount = 0, active = false, updated_at = now(), updated_by = 'migration 20261118840000',
  description = case key
    when 'intake' then 'Complete intake with signed consent, accepted by the office.'
    when 'placement' then 'The person moves into an approved unit (housing search, landlord contact, application help, move-in day).'
    when 'retention_90' then 'The 30, 60 and 90-day check-ins are done and the person is still housed.'
    when 'retention_365' then 'The 6 and 12-month check-ins are done and the person is still housed.'
    when 'landlord_first' then 'A landlord the Navigator brought in houses its first person through the program.'
    else description end;
