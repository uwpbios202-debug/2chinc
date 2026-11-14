-- Applications: a "Wait listed" status and an "Email applicant" button (Stephen, 10/11/2026) so staff can tell an applicant the real status:
-- vacancies now, wait list, upcoming vacancies. Staff always read and edit the message before it is sent; nothing is sent automatically.

alter table rental_applications drop constraint if exists rental_applications_status_check;
alter table rental_applications add constraint rental_applications_status_check
  check (status in ('new', 'reviewing', 'waitlisted', 'approved', 'declined', 'withdrawn'));

do $$
declare v text := pg_get_functiondef('apply_staff_set_status(uuid, text, text)'::regprocedure);
  v_old text := '''new'', ''reviewing'', ''approved'', ''declined'', ''withdrawn''';
begin
  if position(v_old in v) = 0 then raise exception 'apply_staff_set_status changed: cannot patch'; end if;
  execute replace(v, v_old, '''new'', ''reviewing'', ''waitlisted'', ''approved'', ''declined'', ''withdrawn''');
end $$;

-- What staff need to write the message: the applicant, their place on the wait list, and units whose current lease is about to end.
create or replace function apply_staff_status_email_data(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a rental_applications; v_pos int; v_count int;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into a from rental_applications where id = p_id;
  if a.id is null then raise exception 'Application not found'; end if;
  select count(*) filter (where x.created_at <= a.created_at), count(*) into v_pos, v_count from rental_applications x where x.status = 'waitlisted';
  return jsonb_build_object(
    'name', a.applicant->>'name', 'email', a.applicant->>'email', 'status', a.status, 'units', a.applicant->'units', 'move_in', a.applicant->>'move_in',
    'waitlist_position', case when a.status = 'waitlisted' then v_pos end, 'waitlist_count', v_count,
    -- Units whose lease ends within 90 days (placeholder end dates in 2060 are ignored), or with a move-out in progress. Unit numbers and dates only.
    'upcoming', coalesce((select jsonb_agg(jsonb_build_object('unit', x.unit_number, 'date', x.d, 'why', x.why) order by x.d) from (
        select ru.unit_number, l.end_date d, 'lease ends' why from leases l join rental_units ru on ru.id = l.unit_id
         where l.status = 'active' and l.end_date between current_date and current_date + 90 and l.end_date < '2050-01-01'
        union all
        select ru.unit_number, coalesce(m.surrendered_on, current_date), 'move-out in progress' from move_outs m join leases l on l.id = m.lease_id join rental_units ru on ru.id = l.unit_id
         where m.status <> 'closed') x), '[]'::jsonb));
end;
$$;
revoke all on function apply_staff_status_email_data(uuid) from public, anon;
grant execute on function apply_staff_status_email_data(uuid) to authenticated;

-- Send the (staff-edited) message to the applicant's verified email, through the normal outbox.
create or replace function apply_staff_email_applicant(p_id uuid, p_subject text, p_body text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare a rental_applications; v_to text; v_html text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into a from rental_applications where id = p_id;
  if a.id is null then raise exception 'Application not found'; end if;
  v_to := nullif(trim(a.applicant->>'email'), '');
  if v_to is null then raise exception 'This application has no email address.'; end if;
  if length(trim(coalesce(p_subject, ''))) < 3 or length(trim(coalesce(p_body, ''))) < 10 then raise exception 'Write a subject and a message.'; end if;
  v_html := '<div style="font-family:Segoe UI,Arial,sans-serif;color:#1b2633;max-width:620px"><p>'
    || replace(repair_esc(left(trim(p_body), 6000)), E'\n', '<br>') || '</p></div>';
  insert into email_outbox (to_email, subject, html, kind) values (v_to, left(trim(p_subject), 200), v_html, 'apply_status');
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'status', p_id, 'emailed applicant: ' || left(trim(p_subject), 120));
end;
$$;
revoke all on function apply_staff_email_applicant(uuid, text, text) from public, anon;
grant execute on function apply_staff_email_applicant(uuid, text, text) to authenticated;
