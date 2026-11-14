-- Reapplying (Stephen, 10/12/2026): an old application is never deleted or overwritten. Staff link the new application to the old one and the old one
-- becomes "Superseded": out of the active queue, no longer holds a unit (under-contract is derived from approved / on-hold only), still readable.
-- Staff decide; the applicant cannot. A declined application stays "declined" (the decision is evidence); it is only shown as a prior application.
alter table rental_applications add column if not exists supersedes_id uuid references rental_applications(id);
alter table rental_applications add column if not exists superseded_by uuid references rental_applications(id);
alter table rental_applications add column if not exists superseded_at timestamptz;
alter table rental_applications add column if not exists superseded_by_email text;
alter table rental_applications add column if not exists superseded_reason text;
alter table rental_applications add column if not exists superseded_prev_status text;

alter table rental_applications drop constraint if exists rental_applications_status_check;
alter table rental_applications add constraint rental_applications_status_check
  check (status in ('new', 'reviewing', 'on_hold', 'waitlisted', 'approved', 'declined', 'withdrawn', 'superseded'));

-- A superseded application only leaves that status through apply_staff_unsupersede (not by editing the status in the normal save).
create or replace function trg_guard_superseded()
returns trigger language plpgsql as $$
begin
  if old.status = 'superseded' and new.status is distinct from 'superseded' and coalesce(current_setting('app.unsupersede', true), '') <> 'on' then
    raise exception 'This application was replaced by a newer one. Use Restore to bring it back.';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_superseded on rental_applications;
create trigger guard_superseded before update on rental_applications for each row execute function trg_guard_superseded();

create or replace function apply_staff_supersede(p_old uuid, p_new uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare o rental_applications; n rental_applications;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_old = p_new then raise exception 'An application cannot replace itself.'; end if;
  select * into o from rental_applications where id = p_old for update;
  select * into n from rental_applications where id = p_new for update;
  if o.id is null or n.id is null then raise exception 'Application not found'; end if;
  if o.status = 'superseded' then raise exception 'The old application was already replaced.'; end if;
  if n.status in ('superseded', 'declined') then raise exception 'The new application must be an active one (not replaced or declined).'; end if;
  if o.status = 'declined' then raise exception 'A declined application stays on record as declined; it cannot be replaced.'; end if;
  if o.created_at >= n.created_at then raise exception 'The replaced application must be the older one.'; end if;
  if exists (select 1 from lease_signing_docs d where d.application_id = p_old and d.status <> 'void') then
    raise exception 'A lease was already sent to sign for the old application. Void it first.'; end if;
  update rental_applications set status = 'superseded', superseded_prev_status = o.status, superseded_by = p_new, superseded_at = now(),
         superseded_by_email = auth.email(), superseded_reason = nullif(trim(coalesce(p_reason, '')), '') where id = p_old;
  update rental_applications set supersedes_id = p_old where id = p_new;
  insert into apply_access_log (staff_email, action, application_id, detail)
    values (auth.email(), 'supersede', p_old, 'replaced by ' || p_new || ' (was ' || o.status || ')' || case when nullif(trim(coalesce(p_reason, '')), '') is null then '' else ': ' || trim(p_reason) end);
  return jsonb_build_object('old', p_old, 'new', p_new);
end;
$$;
revoke all on function apply_staff_supersede(uuid, uuid, text) from public, anon;
grant execute on function apply_staff_supersede(uuid, uuid, text) to authenticated;

create or replace function apply_staff_unsupersede(p_old uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare o rental_applications;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into o from rental_applications where id = p_old for update;
  if o.id is null or o.status <> 'superseded' then raise exception 'That application is not replaced.'; end if;
  perform set_config('app.unsupersede', 'on', true);
  update rental_applications set status = coalesce(o.superseded_prev_status, 'reviewing'), superseded_by = null, superseded_at = null,
         superseded_by_email = null, superseded_reason = null, superseded_prev_status = null where id = p_old;
  update rental_applications set supersedes_id = null where id = o.superseded_by and supersedes_id = p_old;
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'unsupersede', p_old, 'restored to ' || coalesce(o.superseded_prev_status, 'reviewing'));
  return jsonb_build_object('old', p_old);
end;
$$;
revoke all on function apply_staff_unsupersede(uuid) from public, anon;
grant execute on function apply_staff_unsupersede(uuid) to authenticated;
