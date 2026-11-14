-- NO PARKING, Stephen's decisions of 11/8/2026:
--   1. "$0.00 balance required": a partial payment no longer protects the stall. What still blocks NO PARKING is a payment that is under way
--      or not yet checked (portal payment clearing / started / just paid / recently failed, an "I've paid" report not yet verified or rejected,
--      autopay, an active work-in-lieu agreement, an unmatched deposit, a bank feed that is not current). Once those clear, any rent still
--      owed after the 10th allows NO PARKING.
--   2. Units without a tenant (owner-occupied 1, 7, 13; vacant; Unit 6): "leave alone for now". Owner dues never lead to NO PARKING while
--      the setting parking_revoke_owner_units is 'off'.
--   3. Rule 20 now reads: "If your rent is unpaid on the 10th and no payment has been started or reported, your parking is revoked and a
--      vehicle in your stall is towed." (Nobody had signed yet, so no one has to sign again.)
-- No new table, so no new grants.

insert into portal_settings (key, value) values ('parking_revoke_owner_units', 'off') on conflict (key) do nothing;

do $$ declare v text := pg_get_functiondef('parking_pay_evidence(text)'::regprocedure); n text; begin
  -- 1. drop the tenant "partial payment" protection
  n := regexp_replace(v, 'for x in select entry_date, amount from lease_ledger_entries where lease_id = v_lease.*?end loop;\s*', '', '');
  if n = v then raise exception 'parking_pay_evidence changed (partial); update this migration'; end if;
  v := n;
  -- 2. owner units off unless the setting is on
  n := replace(v, '    if v_owed >= v_min then', '    if v_owed >= v_min and condo_setting(''parking_revoke_owner_units'', ''off'') <> ''on'' then
      ev := ev || jsonb_build_array(jsonb_build_object(''code'', ''owner_units_off'', ''text'', ''Units without a tenant are left alone for now (owner dues do not lead to NO PARKING).''));
    elsif v_owed >= v_min then');
  if n = v then raise exception 'parking_pay_evidence changed (owner); update this migration'; end if;
  execute n;
end $$;

update parking_terms set text = 'If your rent is unpaid on the 10th and no payment has been started or reported, your parking is revoked and a vehicle in your stall is towed.',
       updated_at = now()
 where kind = 'rule' and position = 20 and active;
update parking_terms set text = 'Vehicle in the stall while parking is revoked (rent unpaid on the 10th, no payment started or reported)', updated_at = now()
 where kind = 'fine' and position = 14 and active;
