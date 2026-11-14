-- Retention (Information Security Policy, section 6): an approved application that never became a lease
-- is deleted, with its recordings and photos, one year after it was approved. "Became a lease" means a
-- lease was created from it, or a lease for it is out for signature or signed (anything not voided).
-- The rest is unchanged from 20261104000000_apply_drafts.sql: unfinished applications after 7 days,
-- saved drafts 45 days after the last save, declined or withdrawn applications after 90 days.
-- The rental-apply "purge" action deletes the rows and their storage files for everything listed here.
create or replace function apply_purge_due()
returns table (session_id uuid, application_id uuid)
language sql stable security definer set search_path = public
as $$
  select s.id, null::uuid from apply_sessions s
   where s.submitted_at is null
     and case when exists (select 1 from apply_drafts d where d.session_id = s.id)
              then (select max(d.updated_at) from apply_drafts d where d.session_id = s.id) < now() - interval '45 days'
              else s.created_at < now() - interval '7 days' end
  union all
  select a.session_id, a.id from rental_applications a
   where a.status in ('declined', 'withdrawn') and coalesce(a.decided_at, a.created_at) < now() - interval '90 days'
  union all
  select a.session_id, a.id from rental_applications a
   where a.status = 'approved' and coalesce(a.decided_at, a.created_at) < now() - interval '1 year'
     and not exists (select 1 from leases l where l.application_id = a.id)
     and not exists (select 1 from lease_signing_docs d where d.application_id = a.id and d.status <> 'void');
$$;
