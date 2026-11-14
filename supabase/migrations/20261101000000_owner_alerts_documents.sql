-- Owner portal: alert preferences and owner documents.
-- Alerts that matter (unpaid dues, late fees, interest) are always shown in the portal,
-- computed from the ledger. These preferences choose which EMAIL alerts an owner receives.

create table if not exists condo_alert_prefs (
  owner_id uuid primary key references condo_owners(id) on delete cascade,
  prefs jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table condo_alert_prefs enable row level security;

create or replace function condo_alert_defaults() returns jsonb language sql immutable as $$
  select jsonb_build_object('email_dues_posted', true, 'email_past_due', true, 'email_late_fee', true,
                            'email_payment_received', true, 'email_new_document', true);
$$;

create or replace function condo_my_alert_prefs()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  return condo_alert_defaults() || coalesce((select prefs from condo_alert_prefs where owner_id = v_owner), '{}'::jsonb);
end $$;
revoke all on function condo_my_alert_prefs() from public, anon;
grant execute on function condo_my_alert_prefs() to authenticated;

create or replace function condo_set_my_alert_prefs(p_prefs jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); v_clean jsonb := '{}'::jsonb; k text;
begin
  if not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  for k in select jsonb_object_keys(condo_alert_defaults()) loop
    if p_prefs ? k and jsonb_typeof(p_prefs -> k) = 'boolean' then v_clean := v_clean || jsonb_build_object(k, p_prefs -> k); end if;
  end loop;
  insert into condo_alert_prefs (owner_id, prefs) values (v_owner, v_clean)
    on conflict (owner_id) do update set prefs = condo_alert_prefs.prefs || excluded.prefs, updated_at = now();
  return condo_alert_defaults() || (select prefs from condo_alert_prefs where owner_id = v_owner);
end $$;
revoke all on function condo_set_my_alert_prefs(jsonb) from public, anon;
grant execute on function condo_set_my_alert_prefs(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Documents. unit_number null = for every owner (bylaws, rules, minutes).
create table if not exists condo_documents (
  id bigint generated always as identity primary key,
  unit_number text,
  title text not null check (length(trim(title)) > 0),
  category text not null default 'General',
  storage_path text not null unique,
  uploaded_by text,
  uploaded_at timestamptz not null default now()
);
alter table condo_documents enable row level security;

-- May the signed-in user see the document stored at this path?
create or replace function condo_doc_visible(p_path text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from condo_documents d
    where d.storage_path = p_path
      and (condo_is_staff()
           or (d.unit_number is null and condo_owner_for_email(auth.email()) is not null)
           or d.unit_number in (select u.unit_number from condo_ownerships s join condo_units u on u.id = s.unit_id
                                where s.is_current and s.owner_id = condo_owner_for_email(auth.email()))));
$$;
revoke all on function condo_doc_visible(text) from public, anon;
grant execute on function condo_doc_visible(text) to authenticated;

create or replace function condo_my_documents()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if condo_owner_for_email(auth.email()) is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'unit_number', d.unit_number, 'title', d.title, 'category', d.category,
            'path', d.storage_path, 'uploaded_at', d.uploaded_at) order by d.uploaded_at desc)
          from condo_documents d where condo_doc_visible(d.storage_path)), '[]'::jsonb);
end $$;
revoke all on function condo_my_documents() from public, anon;
grant execute on function condo_my_documents() to authenticated;

create or replace function condo_staff_add_document(p_unit_number text, p_title text, p_category text, p_path text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not condo_session_ok() or not condo_is_staff() then raise exception 'Staff only' using errcode = '42501'; end if;
  insert into condo_documents (unit_number, title, category, storage_path, uploaded_by)
  values (nullif(trim(p_unit_number), ''), trim(p_title), coalesce(nullif(trim(p_category), ''), 'General'), p_path, auth.email())
  returning id into v_id;
  return v_id;
end $$;
revoke all on function condo_staff_add_document(text, text, text, text) from public, anon;
grant execute on function condo_staff_add_document(text, text, text, text) to authenticated;

create or replace function condo_staff_documents()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not condo_session_ok() or not condo_is_staff() then raise exception 'Staff only' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(d) order by d.uploaded_at desc) from condo_documents d), '[]'::jsonb);
end $$;
revoke all on function condo_staff_documents() from public, anon;
grant execute on function condo_staff_documents() to authenticated;

create or replace function condo_staff_delete_document(p_id bigint)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not condo_session_ok() or not condo_is_staff() then raise exception 'Staff only' using errcode = '42501'; end if;
  delete from condo_documents where id = p_id;
end $$;
revoke all on function condo_staff_delete_document(bigint) from public, anon;
grant execute on function condo_staff_delete_document(bigint) to authenticated;

-- Private bucket. Owners read only files listed for them; staff upload and delete.
insert into storage.buckets (id, name, public, file_size_limit)
values ('owner-docs', 'owner-docs', false, 20971520) on conflict (id) do nothing;
drop policy if exists "owner-docs read" on storage.objects;
create policy "owner-docs read" on storage.objects for select to authenticated
  using (bucket_id = 'owner-docs' and condo_doc_visible(name));
drop policy if exists "owner-docs staff upload" on storage.objects;
create policy "owner-docs staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'owner-docs' and condo_session_ok() and condo_is_staff());
drop policy if exists "owner-docs staff delete" on storage.objects;
create policy "owner-docs staff delete" on storage.objects for delete to authenticated
  using (bucket_id = 'owner-docs' and condo_session_ok() and condo_is_staff());
