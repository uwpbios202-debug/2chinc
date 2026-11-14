-- Stage 1 (tenant-journey-spec): ID, SSN card, and the animal question.
--   * The ID (front/back photos) fills the application: the back's PDF417
--     barcode is read in the browser (name, date of birth, address, ID number).
--   * The SSN card verifies the typed SSN. The SSN is stored only encrypted
--     (key held by the edge function, not the database) plus its last 4.
--   * ID and SSN card images are kept only until staff verify every spelling
--     and number; staff then move them to the secure offline drive and the
--     system deletes them from storage (logged).
--   * Animals: a pet stops the application; service / assistance animals get
--     the assistance-animal application. Every applicant acknowledges the
--     pet caution.

alter table rental_applications add column if not exists id_fields jsonb;            -- from the barcode (and as confirmed by the applicant)
alter table rental_applications add column if not exists date_of_birth date;
alter table rental_applications add column if not exists current_address text;
alter table rental_applications add column if not exists ssn_cipher text;            -- AES-GCM, key in APPLY_SSN_KEY
alter table rental_applications add column if not exists ssn_last4 text;
alter table rental_applications add column if not exists animal text check (animal in ('none', 'assistance'));
alter table rental_applications add column if not exists assistance_animal jsonb;
alter table rental_applications add column if not exists pet_caution_ack boolean not null default false;
alter table rental_applications add column if not exists id_checks jsonb;            -- {name, address, dob, id_number, ssn} -> true
alter table rental_applications add column if not exists id_verified_at timestamptz;
alter table rental_applications add column if not exists id_verified_by text;
alter table rental_applications add column if not exists docs_offline_at timestamptz;
alter table rental_applications add column if not exists docs_offline_by text;

-- Applicants who stopped at the pet question (no personal data; counts only).
create table if not exists apply_pet_stops (id bigint generated always as identity primary key, at timestamptz not null default now());
alter table apply_pet_stops enable row level security;

create or replace function apply_staff_verify_identity(p_id uuid, p_checks jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare ok boolean;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  ok := coalesce((p_checks->>'name')::boolean, false) and coalesce((p_checks->>'address')::boolean, false) and coalesce((p_checks->>'dob')::boolean, false)
        and coalesce((p_checks->>'ssn')::boolean, false);
  update rental_applications set id_checks = p_checks,
         id_verified_at = case when ok then now() else null end, id_verified_by = case when ok then auth.email() else null end
   where id = p_id;
  if not found then raise exception 'Application not found'; end if;
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'status', p_id, 'identity checks: ' || p_checks::text);
  return jsonb_build_object('verified', ok);
end;
$$;
revoke all on function apply_staff_verify_identity(uuid, jsonb) from public, anon;
grant execute on function apply_staff_verify_identity(uuid, jsonb) to authenticated;

-- Approval email (everyone is approved once identity is verified).
create or replace function apply_staff_set_status(p_id uuid, p_status text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r rental_applications;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('new', 'reviewing', 'approved', 'declined', 'withdrawn') then raise exception 'Unknown status %', p_status; end if;
  select * into r from rental_applications where id = p_id;
  if r.id is null then raise exception 'Application not found'; end if;
  if p_status = 'approved' and r.id_verified_at is null then raise exception 'Verify the ID and SSN first.'; end if;
  if p_status = 'approved' and r.docs_offline_at is null and exists (select 1 from jsonb_array_elements(r.media) m where m->>'scene' in ('id_front', 'id_back', 'ssn_card')) then
    raise exception 'Move the ID and SSN card images offline first.'; end if;
  update rental_applications
     set status = p_status, staff_notes = coalesce(p_notes, staff_notes),
         decided_at = case when p_status in ('approved', 'declined') then now() else decided_at end,
         decided_by = case when p_status in ('approved', 'declined') then auth.email() else decided_by end
   where id = p_id returning * into r;
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'status', p_id, p_status);
  if p_status = 'approved' then
    insert into email_outbox (to_email, subject, html, kind) values (r.applicant->>'email', 'You''re approved — welcome to 2nd Chance Housing',
      '<p>Hi ' || split_part(r.applicant->>'name', ' ', 1) || ',</p><p>Good news: your application is approved. Next we''ll prepare your lease. You''ll get an email with a private link to review and sign it online.</p>' ||
      '<p>Your keys are handed over as soon as the security deposit and first month''s rent are paid, even before the lease start date.</p><p>Questions? Call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'approval');
  end if;
  return to_jsonb(r) - 'ssn_cipher';
end;
$$;

-- Staff list never returns the SSN ciphertext.
create or replace function apply_staff_list()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  insert into apply_access_log (staff_email, action) values (auth.email(), 'list');
  return coalesce((select jsonb_agg(to_jsonb(a) - 'ssn_cipher' order by a.created_at desc) from rental_applications a), '[]'::jsonb);
end;
$$;
