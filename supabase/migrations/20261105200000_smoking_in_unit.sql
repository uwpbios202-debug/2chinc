-- New standard leases (Stephen, 10/7/2026): smoking is allowed only inside the tenant's unit, the same wording on every
-- lease type (month-to-month, annual, CVI). Breach notices quote the tenant's own lease, so the old "no smoking on the
-- property" row stays for tenants on earlier leases, and a second row quotes the new clause. Staff pick the one that
-- matches the tenant's lease.

update lease_breach_types set title = 'Smoking on the property (leases that ban all smoking)' where code = 'smoking';

insert into lease_breach_types (code, category, title, provision_ref, lease_quote, remedy, consequence, prompt, sort) values
  ('smoking_outside_unit', 'Rules', 'Smoking outside the unit (leases that allow smoking in the unit)', 'Rules and Regulations, Smoking',
   'Smoking is allowed only inside Tenant''s unit. No smoking in hallways, stairways, entries or any other common area, or anywhere else on the property. Any damage to the property as a result of Tenant''s smoking will be the tenant''s responsibility.',
   'Smoke only inside your unit: stop smoking in the hallways, stairways, entries, other common areas and everywhere else on the property, and pay for any damage the smoking caused.',
   'You are responsible for any damage from smoking. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."',
   'Where outside the unit and when the smoking happened, and who saw or smelled it.', 11)
on conflict (code) do update set title = excluded.title, provision_ref = excluded.provision_ref, lease_quote = excluded.lease_quote,
  remedy = excluded.remedy, consequence = excluded.consequence, prompt = excluded.prompt, sort = excluded.sort, active = true;
