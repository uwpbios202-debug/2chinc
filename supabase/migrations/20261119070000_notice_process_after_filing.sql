-- Process screen, part 2 (Stephen, 11/12/2026): the checked-off steps on /staff/efile/?n=...&process=1 now run all the way through the case,
-- not only up to "gather the 3 documents". After step 6 come: wait out the days, fill in eFiling with the what-to-type sheet + checklist,
-- submit and pay once, court accepted (case number + court date), then the hand steps saved here: serve the summons and complaint,
-- file the Declaration of Service (SC-5100V), go to court with the ledger, judgment or dismissal entered.
-- Steps 7 to 10 come from data already recorded (efile_on, efile checklist, submission, case number); only the 4 new hand steps are new keys.
-- No new table, so no new grants.

create or replace function notice_process_keys()
returns text[] language sql immutable as $$
  select array['printed', 'envelope', 'label', 'gathered', 'summons', 'declaration', 'court', 'outcome']::text[]
$$;
revoke all on function notice_process_keys() from public, anon;
grant execute on function notice_process_keys() to authenticated, service_role;

create or replace function notice_process_get(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select jsonb_build_object('id', n.id, 'template_name', n.template_name, 'subject', n.subject, 'sent_at', n.sent_at,
      'label', coalesce(u.address, l.rental_label) || ' — ' || l.tenants_label, 'unit', u.unit_number,
      'pdf_path', n.pdf_path, 'proof_path', n.proof_path, 'served_on', n.served_on, 'service_method', n.service_method, 'service_note', n.service_note,
      'cure_deadline', n.cure_deadline, 'efile_on', n.efile_on, 'case_number', n.case_number, 'steps', n.process_steps,
      'case_filed_on', n.case_filed_on, 'court_at', n.court_at, 'court_place', n.court_place,
      'rent_due', lease_rent_due(n.lease_id, current_date), 'days', notice_days(n.id))
    into r
    from notices n join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id
   where n.id = p_id and n.status = 'sent' and not coalesce(n.voided, false);
  if r is null then raise exception 'Notice not found'; end if;
  return r;
end;
$$;
revoke all on function notice_process_get(uuid) from public, anon;
grant execute on function notice_process_get(uuid) to authenticated;
