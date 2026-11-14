-- Gap #1 (docs/leasing-gap-analysis.md): the staff page sends the current status with every Save, so editing the notes on
-- an approved application re-sent "You're approved" and reset the decision date. The email and the decision stamp now
-- happen only when the status actually CHANGES to approved or declined. The applicant's name is escaped in the email,
-- and the error no longer mentions the SSN (no longer collected).

create or replace function apply_staff_set_status(p_id uuid, p_status text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r rental_applications; v_changed boolean;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('new', 'reviewing', 'approved', 'declined', 'withdrawn') then raise exception 'Unknown status %', p_status; end if;
  select * into r from rental_applications where id = p_id for update;
  if r.id is null then raise exception 'Application not found'; end if;
  v_changed := r.status is distinct from p_status;
  if v_changed and p_status = 'approved' and r.id_verified_at is null then raise exception 'Verify the ID first (name, address and date of birth).'; end if;
  if v_changed and p_status = 'approved' and r.docs_offline_at is null and exists (select 1 from jsonb_array_elements(r.media) m where m->>'scene' in ('id_front', 'id_back', 'ssn_card')) then
    raise exception 'Move the ID images offline first.'; end if;
  update rental_applications
     set status = p_status, staff_notes = coalesce(p_notes, staff_notes),
         decided_at = case when v_changed and p_status in ('approved', 'declined') then now() else decided_at end,
         decided_by = case when v_changed and p_status in ('approved', 'declined') then auth.email() else decided_by end
   where id = p_id returning * into r;
  insert into apply_access_log (staff_email, action, application_id, detail)
  values (auth.email(), 'status', p_id, case when v_changed then p_status else 'notes saved (' || p_status || ')' end);
  if v_changed and p_status = 'approved' then
    insert into email_outbox (to_email, subject, html, kind) values (r.applicant->>'email', 'You''re approved — welcome to 2nd Chance Housing',
      '<p>Hi ' || repair_esc(split_part(r.applicant->>'name', ' ', 1)) || ',</p><p>Good news: your application is approved. Next we''ll prepare your lease. You''ll get an email with a private link to review and sign it online.</p>' ||
      '<p>Your keys are handed over as soon as the security deposit and first month''s rent are paid, even before the lease start date.</p><p>Questions? Call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'approval');
  end if;
  return to_jsonb(r) - 'ssn_cipher';
end;
$$;
revoke all on function apply_staff_set_status(uuid, text, text) from public, anon;
grant execute on function apply_staff_set_status(uuid, text, text) to authenticated;
