-- Zelle for OWNERS ONLY: Royal Orleans Condominium (ROCA1), Zelle tag "rocaone".
-- The QR image is owners/zelle-roca1.png. Tenants' Zelle (pay_zelle_*) is separate
-- and is not set here: owners and tenants have separate bank accounts.
insert into portal_settings (key, value) values
  ('owner_pay_zelle_to', 'rocaone'),
  ('owner_pay_zelle_name', 'ROYAL ORLEANS CONDOMINIUM'),
  ('owner_pay_zelle_qr', '/owners/zelle-roca1.png')
on conflict (key) do update set value = excluded.value;
