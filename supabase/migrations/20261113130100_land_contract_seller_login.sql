-- LOCAL ONLY (listed in .gitignore, never committed or pushed): it holds a real person's email.
-- MH Star LLC, the seller on the 3446 N 12th St land contract, may sign in to https://2ndchinc.org/seller/ (Stephen, 10/18/2026).
insert into land_contract_sellers (contract_id, name, entity, email)
select c.id, 'Jaswinder Singh', 'MH Star LLC', 'shindagill78@yahoo.com'
from land_contracts c where c.id = '65c45d34-6fa4-5fb0-8beb-a76a2b45cb54'
on conflict do nothing;
