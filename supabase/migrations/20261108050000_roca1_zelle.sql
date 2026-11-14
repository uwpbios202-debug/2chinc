-- ROCA1 First Citizens account: Zelle details shown to the tenants of unit 16, whose rent goes to ROCA1 (Stephen, 10/9/2026).
-- ROCA1 takes the owner's association dues, assessments and fees from the rent, then Zelles the balance to the owner by hand
-- (recorded on the ROCA1 "Rent deductions" screen).
update bank_accounts set
  pay_zelle_to = 'royalorleansone@gmail.com',
  pay_zelle_name = 'ROYAL ORLEANS CONDOMINIUM',
  pay_zelle_qr = '/resident/zelle-qr-roca1.png',
  pay_note = 'Send your rent by Zelle to ROYAL ORLEANS CONDOMINIUM (royalorleansone@gmail.com) and put your account number in the memo.'
where bank_key = 'first_citizens_roca1';
