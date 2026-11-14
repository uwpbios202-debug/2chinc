-- Stephen, 10/9/2026: James E Simmons (Unit 2, 2019-2020, $170 balance) and Yawdcour LLC (Unit 11, 2017-2022, $0)
-- are removed from the system. Both were former owners with no current ownership. Their rows were exported first
-- to a local archive folder. Already applied by hand on the live database; this keeps a rebuilt database consistent.
delete from condo_collection_steps where account_id in (select id from condo_ledger_accounts where legacy_owner_label in ('JAMES E SIMMONS', 'Yawdcour LLC'));
delete from condo_ledger_accounts where legacy_owner_label in ('JAMES E SIMMONS', 'Yawdcour LLC');  -- entries cascade
delete from condo_ownerships s using condo_owners o where o.id = s.owner_id and not s.is_current and o.name in ('JAMES E SIMMONS', 'Yawdcour LLC');
delete from condo_owners o where o.name in ('JAMES E SIMMONS', 'Yawdcour LLC') and not exists (select 1 from condo_ownerships s where s.owner_id = o.id);
