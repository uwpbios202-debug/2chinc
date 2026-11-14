-- Assigned staff, part 2 (Stephen, 10/6/2026): they see the documents the tenant and the owner see, and a Communications
-- timeline for the unit. Read-only; nothing here can send, post or change anything.

-- Which documents a unit's staff may open (signed leases, notices, owner documents), checked against their own units.
create or replace function field_can_open_doc(p_bucket text, p_path text)
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and field_is_staff() and (
    (p_bucket = 'lease-signing' and exists (
       select 1 from lease_signing_docs d join leases l on l.id = d.lease_id join rental_units ru on ru.id = l.unit_id
         join staff_units su on lower(su.email) = lower(auth.email()) and su.unit = ru.unit_number
       where d.executed_pdf_path = p_path))
    or (p_bucket = 'notices' and exists (
       select 1 from notices n join leases l on l.id = n.lease_id join rental_units ru on ru.id = l.unit_id
         join staff_units su on lower(su.email) = lower(auth.email()) and su.unit = ru.unit_number
       where n.pdf_path = p_path))
    or (p_bucket = 'owner-docs' and exists (
       select 1 from condo_documents c where c.storage_path = p_path
         and (c.unit_number is null or c.unit_number in (select su.unit from staff_units su where lower(su.email) = lower(auth.email()))))));
$$;
revoke all on function field_can_open_doc(text, text) from public, anon;
grant execute on function field_can_open_doc(text, text) to authenticated;

drop policy if exists "field staff read signed leases" on storage.objects;
create policy "field staff read signed leases" on storage.objects for select to authenticated
  using (bucket_id = 'lease-signing' and field_can_open_doc('lease-signing', name));
drop policy if exists "field staff read notices" on storage.objects;
create policy "field staff read notices" on storage.objects for select to authenticated
  using (bucket_id = 'notices' and field_can_open_doc('notices', name));
drop policy if exists "field staff read owner docs" on storage.objects;
create policy "field staff read owner docs" on storage.objects for select to authenticated
  using (bucket_id = 'owner-docs' and field_can_open_doc('owner-docs', name));

-- Documents for the unit: what the tenant sees and what the owner sees.
create or replace function field_unit_documents(p_property text, p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ru uuid := inspection_rental_unit(p_property, p_unit);
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  return jsonb_build_object(
    'signed_leases', coalesce((select jsonb_agg(jsonb_build_object('title', d.title, 'date', d.executed_at, 'bucket', 'lease-signing', 'path', d.executed_pdf_path, 'who', l.tenants_label) order by d.executed_at desc)
        from lease_signing_docs d join leases l on l.id = d.lease_id where l.unit_id = v_ru and d.executed_pdf_path is not null), '[]'::jsonb),
    'notices', coalesce((select jsonb_agg(jsonb_build_object('title', n.subject, 'date', n.sent_at, 'bucket', 'notices', 'path', n.pdf_path, 'status', case when n.voided then 'voided' else n.status end) order by n.sent_at desc)
        from notices n join leases l on l.id = n.lease_id where l.unit_id = v_ru and n.pdf_path is not null), '[]'::jsonb),
    'on_file', coalesce((select jsonb_agg(jsonb_build_object('kind', f.kind, 'status', f.status, 'dated', f.dated, 'note', f.note) order by f.dated nulls last, f.id)
        from lease_files f join leases l on l.id = f.lease_id where l.unit_id = v_ru), '[]'::jsonb),
    'owner_docs', coalesce((select jsonb_agg(jsonb_build_object('title', c.title, 'category', c.category, 'date', c.uploaded_at, 'bucket', 'owner-docs', 'path', c.storage_path, 'for_unit', c.unit_number is not null) order by c.category, c.title)
        from condo_documents c where c.unit_number is null or c.unit_number = p_unit), '[]'::jsonb));
end;
$$;
revoke all on function field_unit_documents(text, text) from public, anon;
grant execute on function field_unit_documents(text, text) to authenticated;

-- Communications: every line of communication and request for the unit, newest first.
create or replace function field_unit_comms(p_property text, p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ru uuid := inspection_rental_unit(p_property, p_unit); v_lease uuid; v_tenants uuid[]; v_emails text[]; v_owner uuid; v_owner_email text; v_acct uuid;
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  select l.id into v_lease from leases l where l.unit_id = v_ru and l.status = 'active' order by l.start_date desc nulls last limit 1;
  select coalesce(array_agg(t.id), '{}'), coalesce(array_agg(lower(t.email)) filter (where t.email is not null), '{}') into v_tenants, v_emails
    from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = v_lease;
  select s.owner_id, lower(o.email) into v_owner, v_owner_email from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current join condo_owners o on o.id = s.owner_id where cu.unit_number = p_unit limit 1;
  if v_owner_email is not null then v_emails := v_emails || v_owner_email; end if;
  select a.id into v_acct from condo_units cu join condo_ledger_accounts a on a.unit_id = cu.id and a.billing_account where cu.unit_number = p_unit limit 1;

  return coalesce((select jsonb_agg(e order by (e ->> 'at') desc) from (
    select jsonb_build_object('at', m.created_at, 'channel', 'Message', 'from', case when m.from_resident then 'tenant' else 'office' end, 'who', coalesce(t.name, m.by_email),
             'title', case when m.from_resident then 'Message from the tenant' else 'Message to the tenant' end, 'body', m.body) e
      from tenant_messages m join tenants t on t.id = m.tenant_id where m.tenant_id = any (v_tenants)
    union all
    select jsonb_build_object('at', r.created_at, 'channel', 'Repair request', 'from', 'tenant', 'who', coalesce((select name from tenants where id = r.tenant_id), ''),
             'title', 'Request #' || r.number || ': ' || r.subject, 'body', r.description, 'ref', r.number)
      from maintenance_requests r where r.lease_id = v_lease
    union all
    select jsonb_build_object('at', u.at, 'channel', 'Repair request', 'from', case when coalesce(u.by_email, '') = any (v_emails) then 'tenant' else 'office' end, 'who', coalesce(u.by_email, ''),
             'title', 'Update on request #' || r.number || ': ' || r.subject || coalesce(' (' || u.status || ')', '') || case when u.visible_to_resident then '' else ' [internal note]' end, 'body', u.note, 'ref', r.number)
      from maintenance_request_updates u join maintenance_requests r on r.id = u.request_id where r.lease_id = v_lease
    union all
    select jsonb_build_object('at', n.sent_at, 'channel', 'Notice', 'from', 'office', 'who', n.sent_by, 'title', n.subject || case when n.voided then ' [voided]' else '' end, 'body', 'Status: ' || n.status || coalesce('. Served ' || to_char(n.served_on, 'FMMM/FMDD/YYYY'), ''))
      from notices n where n.lease_id = v_lease
    union all
    select jsonb_build_object('at', o.created_at, 'channel', 'Email', 'from', 'office', 'who', o.to_email, 'title', o.subject, 'body', 'Type: ' || o.kind || case when o.sent_at is null then ' (not sent yet)' else '' end)
      from email_outbox o where lower(o.to_email) = any (v_emails)
    union all
    select jsonb_build_object('at', pr.created_at, 'channel', 'Payment report', 'from', 'tenant', 'who', coalesce(pr.payer_name, ''),
             'title', 'Reported a ' || replace(pr.method, '_', ' ') || ' payment of ' || to_char(pr.amount, 'FM$999,990.00'), 'body', 'Status: ' || pr.status || coalesce('. ' || pr.note, ''))
      from payment_reports pr where (pr.lease_id = v_lease and v_lease is not null) or (pr.condo_account_id = v_acct and v_acct is not null)
    union all
    select jsonb_build_object('at', wn.created_at, 'channel', 'Work in lieu', 'from', case when wn.author_role = 'staff' then 'office' else 'tenant' end, 'who', wn.author_email,
             'title', 'Note on ' || w.title, 'body', coalesce(wn.note, '(photo)'))
      from work_notes wn join work_agreements w on w.id = wn.agreement_id where w.lease_id = v_lease
    union all
    select jsonb_build_object('at', cm.created_at, 'channel', 'Website message', 'from', 'tenant', 'who', cm.email, 'title', 'Message from the Contact page', 'body', cm.message)
      from contact_messages cm where lower(cm.email) = any (v_emails)
    order by 1 desc limit 250) x), '[]'::jsonb);
end;
$$;
revoke all on function field_unit_comms(text, text) from public, anon;
grant execute on function field_unit_comms(text, text) to authenticated;
