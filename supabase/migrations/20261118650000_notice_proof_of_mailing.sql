-- Proof of mailing on a served notice (11/9/2026, Stephen):
--  * staff attach a photo or scan of the green certified mail receipt (PS Form 3800) to a sent notice
--    (stored in the private 'notices' bucket under proof/<notice id>.<ext>, notices.proof_path);
--  * the tenant's home page shows a card next to the balance while a pay-or-vacate notice is running:
--    served date, unpaid RENT only (never late fees) and the cure date, then "Eviction filed" once the case is recorded,
--    with a thumbnail of the receipt and a zoom button.

alter table notices add column if not exists proof_path text;
alter table notices add column if not exists proof_added_at timestamptz;

-- The bucket held PDFs only; receipts are photos.
update storage.buckets set allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
where id = 'notices';

-- Staff upload receipts (proof/ folder only). Functions only, no table reads in the policy (see migration 20261118590000).
drop policy if exists "notices proof staff insert" on storage.objects;
create policy "notices proof staff insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'notices' and name like 'proof/%' and condo_session_ok() and condo_is_staff());
drop policy if exists "notices proof staff update" on storage.objects;
create policy "notices proof staff update" on storage.objects for update to authenticated
  using (bucket_id = 'notices' and name like 'proof/%' and condo_session_ok() and condo_is_staff());

-- Tenants may read the receipt of their own sent notice, like the notice PDF itself.
create or replace function resident_can_read_notice(p_path text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_session_ok() and exists (
    select 1 from notices n where (n.pdf_path = p_path or n.proof_path = p_path) and not n.voided and n.status = 'sent' and (
      exists (select 1 from lease_tenants lt where lt.lease_id = n.lease_id and lt.tenant_id in (select resident_me()))
      or exists (select 1 from land_contract_buyers b where b.contract_id = n.land_contract_id and b.tenant_id in (select resident_me()))));
$$;

create or replace function notice_attach_proof(p_id uuid, p_path text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_path is null or p_path not like 'proof/' || p_id::text || '.%' then raise exception 'Unexpected file name.'; end if;
  update notices set proof_path = p_path, proof_added_at = now() where id = p_id and status = 'sent' and not voided;
  if not found then raise exception 'Notice not found (or not sent).'; end if;
  return jsonb_build_object('ok', true, 'proof_path', p_path);
end;
$$;
revoke all on function notice_attach_proof(uuid, text) from public, anon;
grant execute on function notice_attach_proof(uuid, text) to authenticated;

-- The running pay-or-vacate notice for the signed-in tenant (null when none).
-- Shown until the eFile date while rent is owed; after a case is recorded, until the day after court.
create or replace function resident_eviction_status()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare n record;
begin
  if not exists (select resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  select x.* into n from notices x
  where x.lease_id is not null and not x.voided and x.status = 'sent' and x.served_on is not null and x.efile_on is not null
    and x.template_name ilike '%pay rent or vacate%'
    and exists (select 1 from lease_tenants lt where lt.lease_id = x.lease_id and lt.tenant_id in (select resident_me()))
    and ((x.case_number is null and current_date <= x.efile_on)
      or (x.case_number is not null and (x.court_at is null or x.court_at > now() - interval '1 day')))
  order by x.served_on desc limit 1;
  if n.id is null then return null; end if;
  return jsonb_build_object('id', n.id, 'template_name', n.template_name, 'served_on', n.served_on, 'service_method', n.service_method,
    'cure_deadline', n.cure_deadline, 'efile_on', n.efile_on, 'rent_due', lease_rent_due(n.lease_id, current_date),
    'case_number', n.case_number, 'case_filed_on', n.case_filed_on, 'court_at', n.court_at, 'court_place', n.court_place,
    'pdf_path', n.pdf_path, 'proof_path', n.proof_path);
end;
$$;
revoke all on function resident_eviction_status() from public, anon;
grant execute on function resident_eviction_status() to authenticated;

-- Staff list: same as 20261118521000 plus proof_path.
create or replace function notices_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'template_name', n.template_name, 'subject', n.subject, 'sent_at', n.sent_at,
      'sent_by', n.sent_by, 'signed_by_agent', n.signed_by_agent, 'emailed_to', coalesce(n.emailed_to, '{}'), 'pdf_path', n.pdf_path, 'service_method', n.service_method,
      'served_on', n.served_on, 'service_note', n.service_note, 'voided', n.voided, 'status', n.status, 'batch', n.batch,
      'not_sent_reason', n.not_sent_reason, 'not_sent_at', n.not_sent_at, 'lease_label', u.address || ' — ' || l.tenants_label,
      'cure_deadline', case when n.lease_id is not null then n.cure_deadline end, 'efile_on', n.efile_on,
      'mediation_emailed_at', n.mediation_emailed_at, 'efile_reminded_at', n.efile_reminded_at,
      'rent_due', case when n.lease_id is not null and n.efile_on is not null then lease_rent_due(n.lease_id, current_date) end,
      'case_number', n.case_number, 'case_filed_on', n.case_filed_on, 'court_at', n.court_at, 'court_place', n.court_place,
      'case_emailed_at', n.case_emailed_at, 'court_reminded_at', n.court_reminded_at,
      'proof_path', n.proof_path, 'proof_added_at', n.proof_added_at) order by coalesce(n.not_sent_at, n.sent_at) desc)
    from notices n left join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id where n.status in ('sent', 'not_sent')), '[]'::jsonb);
end;
$$;
