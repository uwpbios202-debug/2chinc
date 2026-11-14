-- Work in lieu does not hold off NO PARKING (Stephen, 11/8/2026). The work credit is posted to the tenant's rent when it is agreed
-- (Unit 4: $450 of November's $900 credited 11/1), so the tenant's own share is what is still owed and it must be paid like any rent.
-- An active work-in-lieu agreement is no longer listed as a sign of a payment attempt. No new table, so no new grants.
do $$ declare v text := pg_get_functiondef('parking_pay_evidence(text)'::regprocedure); n text; begin
  n := replace(v, '      if exists (select 1 from work_agreements w where w.lease_id = v_lease and w.status = ''active'') then
        ev := ev || jsonb_build_array(jsonb_build_object(''code'', ''work'', ''text'', ''The tenant has an active work-in-lieu agreement.''));
      end if;
', '');
  if n = v then raise exception 'parking_pay_evidence changed (work); update this migration'; end if;
  execute n;
end $$;
