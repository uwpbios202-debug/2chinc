-- Move-in / move-out checklists, room by room (Stephen, 10/9/2026):
--   * six conditions per item, as in the earlier inspection form: Good, Fair, Clean, Marked, Dirty, Damaged
--   * a photo button beside every item; photos are optional (a good item can be skipped), so the
--     old "at least one photo of every room" rule is gone. Damaged still needs a description.
--   * per-item photos live in rooms.<room>.items.<item>.p (paths in the move-in bucket, under the lease's folder)
-- The tenant's checklist saves itself as they go, so they can stop and reopen anytime.

create or replace function move_in_checklist_problem(p_lease uuid, p_data jsonb)
returns text
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; room jsonb; it text; c text;
begin
  for r in select * from jsonb_array_elements((select value::jsonb from portal_settings where key = 'move_in_rooms')) loop
    room := p_data->'rooms'->(r->>'key');
    if coalesce((r->>'optional')::boolean, false) and coalesce((room->>'na')::boolean, false) then continue; end if;
    for it in select jsonb_array_elements_text(r->'items') loop
      c := room->'items'->it->>'c';
      if c is null or c not in ('good', 'fair', 'clean', 'marked', 'dirty', 'damaged') then
        return (r->>'name') || ': choose the condition of "' || it || '"' ||
          case when coalesce((r->>'optional')::boolean, false) then ', or mark the room "Not in my unit"' else '' end || '.';
      end if;
      if c = 'damaged' and coalesce(trim(room->'items'->it->>'n'), '') = '' then return (r->>'name') || ': describe the damage to "' || it || '".'; end if;
    end loop;
  end loop;
  return null;
end;
$$;

-- Same as 20261025000000_move_out.sql, except the photo check also covers the per-item photos.
create or replace function resident_move_in_save(p_lease uuid, p_data jsonb, p_prior_list boolean, p_submit boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l leases; v_status text; v_problem text; p text; v_addr text;
begin
  perform resident_require_current();
  if not resident_lease_ok(p_lease) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease and move_in_charges_posted;
  if l.id is null then raise exception 'No move-in for this lease.'; end if;
  if l.keys_ready_at is null then raise exception 'The checklist opens once your move-in amount is paid and your keys are ready.'; end if;
  select status into v_status from move_in_checklists where lease_id = p_lease;
  if v_status in ('submitted', 'approved') then raise exception 'Your checklist was already sent. Call the office if something needs to change.'; end if;
  -- Photos must be this lease's own uploads.
  for p in select jsonb_array_elements_text(coalesce(r.value->'photos', '[]'::jsonb)) from jsonb_each(coalesce(p_data->'rooms', '{}'::jsonb)) r
           union all
           select jsonb_array_elements_text(coalesce(i.value->'p', '[]'::jsonb))
             from jsonb_each(coalesce(p_data->'rooms', '{}'::jsonb)) r, jsonb_each(case when jsonb_typeof(r.value->'items') = 'object' then r.value->'items' else '{}'::jsonb end) i loop
    if left(p, 37) <> p_lease::text || '/' then raise exception 'Photo not recognised.'; end if;
  end loop;
  if p_submit then
    v_problem := move_in_checklist_problem(p_lease, p_data);
    if v_problem is not null then raise exception '%', v_problem; end if;
  end if;
  insert into move_in_checklists (lease_id, data, status, prior_damage_list_requested, submitted_at, submitted_by, updated_at)
  values (p_lease, p_data, case when p_submit then 'submitted' else 'draft' end, coalesce(p_prior_list, false),
          case when p_submit then now() end, case when p_submit then auth.email() end, now())
  on conflict (lease_id) do update set data = excluded.data, status = case when p_submit then 'submitted' else move_in_checklists.status end,
    prior_damage_list_requested = excluded.prior_damage_list_requested,
    submitted_at = coalesce(excluded.submitted_at, move_in_checklists.submitted_at), submitted_by = coalesce(excluded.submitted_by, move_in_checklists.submitted_by), updated_at = now();
  if p_submit then
    select address into v_addr from rental_units where id = l.unit_id;
    insert into email_outbox (to_email, subject, html, kind) values ((select value from portal_settings where key = 'office_email'),
      'Move-in checklist to review — ' || v_addr,
      '<p>' || l.tenants_label || ' sent the move-in checklist for <b>' || v_addr || '</b>' ||
      case when now()::date > coalesce(l.keys_released_at::date, l.start_date) + 7 then ' (after the 7-day window)' else '' end || '.</p>' ||
      case when coalesce(p_prior_list, false) then '<p><b>The tenant asked for the list of damages charged to the previous tenant''s security deposit.</b> Send it to them.</p>' else '' end ||
      '<p>Review and sign off on the Move-ins page.</p>', 'move_in_checklist');
  end if;
  return jsonb_build_object('ok', true, 'status', case when p_submit then 'submitted' else coalesce(v_status, 'draft') end);
end;
$$;
