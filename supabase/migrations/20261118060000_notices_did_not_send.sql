-- A draft notice staff decide not to send (Stephen, 11/2/2026) is marked "did not send" with a reason and moves into its month's folder on the
-- Notices page, colour coded against the ones that were sent. The rent cycle still sees the month's batch as prepared, so it does not draft it again.
alter table notices drop constraint if exists notices_status_check;
alter table notices add constraint notices_status_check check (status = any (array['draft', 'sent', 'not_sent']));
alter table notices add column if not exists not_sent_reason text, add column if not exists not_sent_at timestamptz, add column if not exists not_sent_by text;

create or replace function notice_mark_not_sent(p_ids uuid[], p_reason text)
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update notices set status = 'not_sent', not_sent_reason = nullif(trim(coalesce(p_reason, '')), ''), not_sent_at = now(), not_sent_by = auth.email()
   where id = any (p_ids) and status = 'draft';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function notice_mark_not_sent(uuid[], text) from public, anon;
grant execute on function notice_mark_not_sent(uuid[], text) to authenticated;

create or replace function notice_restore_draft(p_id uuid)
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update notices set status = 'draft', not_sent_reason = null, not_sent_at = null, not_sent_by = null where id = p_id and status = 'not_sent';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function notice_restore_draft(uuid) from public, anon;
grant execute on function notice_restore_draft(uuid) to authenticated;

-- The folder list: sent and did-not-send notices (drafts are on the Ready to sign list).
create or replace function notices_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'template_name', n.template_name, 'subject', n.subject, 'sent_at', n.sent_at,
      'sent_by', n.sent_by, 'signed_by_agent', n.signed_by_agent, 'emailed_to', coalesce(n.emailed_to, '{}'), 'pdf_path', n.pdf_path, 'service_method', n.service_method,
      'served_on', n.served_on, 'service_note', n.service_note, 'voided', n.voided, 'status', n.status, 'batch', n.batch,
      'not_sent_reason', n.not_sent_reason, 'not_sent_at', n.not_sent_at, 'lease_label', u.address || ' — ' || l.tenants_label) order by coalesce(n.not_sent_at, n.sent_at) desc)
    from notices n left join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id where n.status in ('sent', 'not_sent')), '[]'::jsonb);
end;
$$;
