-- The application no longer collects an SSN (commit 3c1fe6b), but verifying the ID still required an
-- 'ssn' check the staff page never shows, so "Mark verified" never succeeded and nobody could be approved.
-- Verification is now the spelling check on the ID: name, address and date of birth.

create or replace function apply_staff_verify_identity(p_id uuid, p_checks jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare ok boolean;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  ok := coalesce((p_checks->>'name')::boolean, false) and coalesce((p_checks->>'address')::boolean, false) and coalesce((p_checks->>'dob')::boolean, false);
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
