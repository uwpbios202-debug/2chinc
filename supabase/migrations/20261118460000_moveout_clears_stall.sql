-- Move-out clears the stall (Stephen, 11/8/2026). When the office records "Keys back / surrender" (moveout_staff_vacated), the unit's stall
-- is cleared for the next occupant:
--   * the tenants' registered vehicles, loaners and regular visitors end (they drop off Always Towing's page at once);
--   * their "no vehicle" answer is removed;
--   * stall switches: a pending one is cancelled, one in progress ends that day, a future one is cancelled;
--   * the office gets one email: stall cleared, what was removed, and the parking hanger numbers to collect.
-- Signed parking rules stay on file as records, but only the people who live in (or own) a unit now count as "signed" on the staff screens,
-- so the next tenant shows as not signed until they sign.
-- No new table, so no new grants.

create or replace function parking_clear_for_lease(p_lease uuid, p_on date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_unit text; v_tenants uuid[]; v_ended int := 0; v_hangers text; v_list text; v_sw int := 0;
begin
  select ru.unit_number into v_unit from leases l join rental_units ru on ru.id = l.unit_id where l.id = p_lease;
  if v_unit is null then return jsonb_build_object('unit', null); end if;
  select coalesce(array_agg(tenant_id), '{}') into v_tenants from lease_tenants where lease_id = p_lease;

  select string_agg(vehicle_summary(v), '; '), string_agg(v.hanger_number, ', ') filter (where v.hanger_number is not null)
    into v_list, v_hangers
    from vehicles v where v.unit_number = v_unit and v.status = 'active' and (v.lease_id = p_lease or v.tenant_id = any (v_tenants));
  update vehicles v set status = 'ended', ended_at = now(), updated_at = now(),
         notes = concat_ws(' ', nullif(v.notes, ''), '[Ended at move-out ' || to_char(p_on, 'FMMM/FMDD/YYYY') || '.]')
   where v.unit_number = v_unit and v.status = 'active' and (v.lease_id = p_lease or v.tenant_id = any (v_tenants));
  get diagnostics v_ended = row_count;

  delete from parking_declarations d where d.unit_number = v_unit and (d.lease_id = p_lease or d.tenant_id = any (v_tenants));

  update parking_swaps set status = 'cancelled' where (unit_a = v_unit or unit_b = v_unit)
     and (status = 'pending' or (status = 'accepted' and start_date > p_on));
  get diagnostics v_sw = row_count;
  update parking_swaps set status = 'ended', end_date = greatest(start_date, p_on) where (unit_a = v_unit or unit_b = v_unit)
     and status = 'accepted' and start_date <= p_on and end_date > p_on;

  insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', 'Stall ' || v_unit || ' cleared at move-out',
    '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p><b>Stall ' || repair_esc(v_unit) || '</b> was cleared when Unit ' || repair_esc(v_unit)
    || ' was vacated (' || to_char(p_on, 'FMMM/FMDD/YYYY') || ').</p>'
    || case when v_ended > 0 then '<p>Removed from the registered vehicles (no longer allowed on Always Towing''s page): ' || repair_esc(v_list) || '.</p>'
            else '<p>No vehicles were registered for this tenancy.</p>' end
    || case when v_hangers is not null then '<p><b>Collect parking hanger' || case when position(',' in v_hangers) > 0 then 's' else '' end || ' #' || repair_esc(v_hangers) || '.</b></p>' else '' end
    || '<p>Until the next occupant registers, any vehicle in stall ' || repair_esc(v_unit) || ' is unauthorized. https://2ndchinc.org/parking/</p></div>', 'parking_moveout');
  return jsonb_build_object('unit', v_unit, 'vehicles_ended', v_ended, 'hangers', v_hangers, 'swaps_cancelled', v_sw);
end;
$$;
revoke all on function parking_clear_for_lease(uuid, date) from public, anon, authenticated;

-- Hook it into "Keys back / surrender".
do $$ declare v text := pg_get_functiondef('moveout_staff_vacated(uuid, date, date)'::regprocedure); n text; begin
  n := replace(v, 'update lease_rent_changes set canceled_at = now() where lease_id = l.id and applied_at is null and canceled_at is null;',
                  'update lease_rent_changes set canceled_at = now() where lease_id = l.id and applied_at is null and canceled_at is null;
  perform parking_clear_for_lease(l.id, p_surrendered_on);');
  if n = v then raise exception 'moveout_staff_vacated changed; update this migration'; end if;
  execute n;
end $$;

-- Who counts as "signed" for a stall: only people who live in or own the unit now.
create or replace function parking_unit_signers(p_unit text)
returns table (email text)
language sql stable security definer set search_path = public as $$
  select lower(p.email) from parking_unit_people(p_unit) p
  union
  select lower(o.email) from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current join condo_owners o on o.id = s.owner_id
   where cu.unit_number = p_unit and o.email like '%@%';
$$;
revoke all on function parking_unit_signers(text) from public, anon, authenticated;

do $$ declare v text; n text; begin
  v := pg_get_functiondef('parking_stocktake_staff()'::regprocedure);
  n := replace(v, 'from parking_acks a where a.unit_number = s.home_unit and a.terms_version = v_ver)',
                  'from parking_acks a where a.unit_number = s.home_unit and a.terms_version = v_ver and lower(a.email) in (select email from parking_unit_signers(s.home_unit)))');
  if n = v then raise exception 'parking_stocktake_staff changed; update this migration'; end if;
  execute n;
  v := pg_get_functiondef('parking_acks_staff()'::regprocedure);
  n := replace(v, 'not exists (select 1 from parking_acks a where a.unit_number = s.home_unit and a.terms_version = v_ver)',
                  'not exists (select 1 from parking_acks a where a.unit_number = s.home_unit and a.terms_version = v_ver and lower(a.email) in (select email from parking_unit_signers(s.home_unit)))');
  if n = v then raise exception 'parking_acks_staff changed; update this migration'; end if;
  execute n;
end $$;
