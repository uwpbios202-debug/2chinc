-- Applications: an "On hold" status (Stephen, 10/12/2026), for an application we cannot process yet, for example when it lists a second
-- adult who has not submitted their own application. The reason goes in the staff notes; the applicant is told by the "Email applicant" button.
alter table rental_applications drop constraint if exists rental_applications_status_check;
alter table rental_applications add constraint rental_applications_status_check
  check (status in ('new', 'reviewing', 'on_hold', 'waitlisted', 'approved', 'declined', 'withdrawn'));

do $$
declare v text := pg_get_functiondef('apply_staff_set_status(uuid, text, text)'::regprocedure);
  v_old text := '''new'', ''reviewing'', ''waitlisted'', ''approved'', ''declined'', ''withdrawn''';
begin
  if position(v_old in v) = 0 then raise exception 'apply_staff_set_status changed: cannot patch'; end if;
  execute replace(v, v_old, '''new'', ''reviewing'', ''on_hold'', ''waitlisted'', ''approved'', ''declined'', ''withdrawn''');
end $$;
