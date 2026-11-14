-- Stage 6 (tenant-journey-spec): day to day in the unit.
--  * Monthly video or audio rule letter (rule 14): recorded by staff, stored
--    privately, emailed to every tenant, searchable in the portal; who watched
--    is recorded.
--  * Announcements to all tenants or one building, emailed.
--  * Profile: emergency contact and alternate phone saved directly. The mobile
--    number and email are the two sign-in factors, so changing them is a request
--    the office confirms (the tenant is told at the old and new address).
--  * Keep-info-up-to-date reminders (rule 15): the portal asks every 6 months
--    and every monthly-letter email reminds.
--  * Messages between the tenant and the office.
--  * Condo (ROCA1) violation passed on to the tenant: a notice template.

alter table tenants add column if not exists alt_phone text;
alter table tenants add column if not exists emergency_name text;
alter table tenants add column if not exists emergency_phone text;
alter table tenants add column if not exists emergency_relation text;
alter table tenants add column if not exists profile_confirmed_at timestamptz;

create table if not exists tenant_contact_changes (
  id uuid primary key default gen_random_uuid(),
  requested_by text not null,                    -- the tenant's sign-in email at the time
  field text not null check (field in ('phone', 'email')),
  old_value text,
  new_value text not null,
  status text not null default 'pending' check (status in ('pending', 'applied', 'declined')),
  requested_at timestamptz not null default now(),
  decided_by text,
  decided_at timestamptz,
  note text
);
alter table tenant_contact_changes enable row level security;

create table if not exists rule_letters (
  id uuid primary key default gen_random_uuid(),
  month date not null unique check (extract(day from month) = 1),
  title text not null,
  rule_topic text not null,
  lease_section text,
  summary text not null,
  transcript text,
  media_path text,
  media_kind text check (media_kind in ('video', 'audio')),
  media_mime text,
  duration_seconds int,
  status text not null default 'draft' check (status in ('draft', 'published')),
  published_at timestamptz,
  created_by text,
  updated_at timestamptz not null default now(),
  search tsvector generated always as (to_tsvector('english',
    coalesce(title, '') || ' ' || coalesce(rule_topic, '') || ' ' || coalesce(lease_section, '') || ' ' || coalesce(summary, '') || ' ' || coalesce(transcript, ''))) stored
);
alter table rule_letters enable row level security;
create index if not exists rule_letters_search_idx on rule_letters using gin (search);

create table if not exists rule_letter_views (
  letter_id uuid not null references rule_letters(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  first_viewed_at timestamptz not null default now(),
  primary key (letter_id, tenant_id)
);
alter table rule_letter_views enable row level security;

alter table announcements add column if not exists property_id uuid references rental_properties(id);
alter table announcements add column if not exists posted_by text;
alter table announcements add column if not exists emailed_count int;

create table if not exists tenant_messages (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references tenants(id) on delete cascade,
  from_resident boolean not null,
  body text not null,
  by_email text,
  created_at timestamptz not null default now(),
  read_at timestamptz                              -- read by the other side
);
alter table tenant_messages enable row level security;
create index if not exists tenant_messages_tenant_idx on tenant_messages (tenant_id, created_at);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rule-letters', 'rule-letters', false, 52428800,
        array['video/webm', 'video/mp4', 'video/quicktime', 'audio/webm', 'audio/mp4', 'audio/mpeg', 'audio/ogg', 'audio/x-m4a', 'audio/wav'])
on conflict (id) do update set allowed_mime_types = excluded.allowed_mime_types, file_size_limit = excluded.file_size_limit;

create or replace function resident_can_play_letter(p_name text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from resident_me()) and exists (select 1 from rule_letters where media_path = p_name and status = 'published');
$$;
revoke all on function resident_can_play_letter(text) from public, anon;
grant execute on function resident_can_play_letter(text) to authenticated;
create or replace function staff_session_staff()
returns boolean
language sql stable security definer set search_path = public as $$ select condo_session_ok() and condo_is_staff(); $$;
revoke all on function staff_session_staff() from public, anon;
grant execute on function staff_session_staff() to authenticated;

drop policy if exists "rule-letters staff upload" on storage.objects;
create policy "rule-letters staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'rule-letters' and staff_session_staff());
drop policy if exists "rule-letters read" on storage.objects;
create policy "rule-letters read" on storage.objects for select to authenticated
  using (bucket_id = 'rule-letters' and (staff_session_staff() or resident_can_play_letter(name)));

-- Everyone currently living in a unit (active/future leases and land contract
-- buyers), optionally for one property.
create or replace function current_tenant_recipients(p_property uuid)
returns table (tenant_id uuid, name text, email text)
language sql stable security definer set search_path = public as $$
  select distinct on (lower(t.email)) t.id, t.name, t.email from tenants t
  where t.email is not null and (
    exists (select 1 from lease_tenants lt join leases l on l.id = lt.lease_id join rental_units u on u.id = l.unit_id
            where lt.tenant_id = t.id and l.status in ('active', 'future') and (p_property is null or u.property_id = p_property))
    or exists (select 1 from land_contract_buyers b join land_contracts c on c.id = b.contract_id
               where b.tenant_id = t.id and c.status = 'active' and (p_property is null or c.property_id = p_property)))
  order by lower(t.email), t.created_at;
$$;
revoke all on function current_tenant_recipients(uuid) from public, anon, authenticated;

create or replace function tenant_email_wrap(p_first text, p_body text)
returns text
language sql stable security definer set search_path = public as $$
  select '<p>Hi ' || repair_esc(coalesce(nullif(p_first, ''), 'there')) || ',</p>' || p_body || '<p>2nd Chance Housing</p>';
$$;
revoke all on function tenant_email_wrap(text, text) from public, anon, authenticated;

-- Resident: profile ------------------------------------------------------------

create or replace function resident_profile()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t tenants;
begin
  select * into t from tenants where id in (select resident_me()) order by profile_confirmed_at desc nulls last, created_at limit 1;
  if t.id is null then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('name', t.name, 'email', t.email, 'phone', t.phone, 'alt_phone', t.alt_phone,
    'emergency_name', t.emergency_name, 'emergency_phone', t.emergency_phone, 'emergency_relation', t.emergency_relation,
    'profile_confirmed_at', t.profile_confirmed_at,
    'reminder_due', t.profile_confirmed_at is null or t.profile_confirmed_at < now() - interval '6 months',
    'pending', coalesce((select jsonb_agg(jsonb_build_object('field', c.field, 'new_value', c.new_value, 'requested_at', c.requested_at) order by c.requested_at)
      from tenant_contact_changes c where c.status = 'pending' and lower(c.requested_by) = lower(auth.email())), '[]'::jsonb));
end;
$$;

create or replace function resident_profile_save(p_alt_phone text, p_emergency_name text, p_emergency_phone text, p_emergency_relation text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare digits text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  foreach digits in array array[coalesce(p_alt_phone, ''), coalesce(p_emergency_phone, '')] loop
    if digits <> '' and length(regexp_replace(digits, '\D', '', 'g')) not in (10, 11) then raise exception 'Enter phone numbers with area code, like (414) 555-0123.'; end if;
  end loop;
  if coalesce(trim(p_emergency_name), '') <> '' and coalesce(trim(p_emergency_phone), '') = '' then raise exception 'Add your emergency contact''s phone number.'; end if;
  update tenants set alt_phone = nullif(trim(p_alt_phone), ''), emergency_name = nullif(trim(p_emergency_name), ''),
    emergency_phone = nullif(trim(p_emergency_phone), ''), emergency_relation = nullif(trim(p_emergency_relation), ''), profile_confirmed_at = now()
  where id in (select resident_me());
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function resident_profile_confirm()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  update tenants set profile_confirmed_at = now() where id in (select resident_me());
  return jsonb_build_object('ok', true);
end;
$$;

-- Mobile number or email change: the office confirms it before it takes effect.
create or replace function resident_contact_change(p_field text, p_new text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare t tenants; v_new text := trim(coalesce(p_new, ''));
begin
  select * into t from tenants where id in (select resident_me()) order by created_at limit 1;
  if t.id is null then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if p_field = 'phone' then
    if length(regexp_replace(v_new, '\D', '', 'g')) <> 10 then raise exception 'Enter a 10-digit mobile number, like (414) 555-0123.'; end if;
    if regexp_replace(v_new, '\D', '', 'g') = regexp_replace(coalesce(t.phone, ''), '\D', '', 'g') then raise exception 'That''s already your number.'; end if;
  elsif p_field = 'email' then
    v_new := lower(v_new);
    if v_new !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then raise exception 'Enter a valid email address.'; end if;
    if v_new = lower(coalesce(t.email, '')) then raise exception 'That''s already your email.'; end if;
  else raise exception 'Unknown field';
  end if;
  update tenant_contact_changes set status = 'declined', note = 'Replaced by a newer request', decided_at = now()
  where status = 'pending' and field = p_field and lower(requested_by) = lower(auth.email());
  insert into tenant_contact_changes (requested_by, field, old_value, new_value)
  values (lower(auth.email()), p_field, case when p_field = 'phone' then t.phone else t.email end, v_new);
  insert into email_outbox (to_email, subject, html, kind) select value, 'Contact change to confirm — ' || t.name,
    '<p>' || repair_esc(t.name) || ' asked to change their ' || case when p_field = 'phone' then 'mobile number' else 'email' end ||
    ' from <b>' || repair_esc(coalesce(case when p_field = 'phone' then t.phone else t.email end, '—')) || '</b> to <b>' || repair_esc(v_new) ||
    '</b>. It is also a sign-in factor, so call the tenant at a number you already have to confirm, then approve it on the Messages page.</p>', 'contact_change'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('ok', true);
end;
$$;

-- Resident: monthly letters, announcements, messages ----------------------------

create or replace function resident_letters(p_query text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q tsquery := case when length(trim(coalesce(p_query, ''))) > 1 then websearch_to_tsquery('english', p_query) end;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'month', r.month, 'title', r.title, 'rule_topic', r.rule_topic, 'lease_section', r.lease_section,
      'summary', r.summary, 'transcript', r.transcript, 'media_path', r.media_path, 'media_kind', r.media_kind, 'duration_seconds', r.duration_seconds,
      'viewed', exists (select 1 from rule_letter_views v where v.letter_id = r.id and v.tenant_id in (select resident_me()))) order by r.month desc)
    from rule_letters r where r.status = 'published' and (q is null or r.search @@ q)), '[]'::jsonb);
end;
$$;

create or replace function resident_letter_viewed(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from rule_letters where id = p_id and status = 'published') then return; end if;
  insert into rule_letter_views (letter_id, tenant_id) select p_id, x from resident_me() x on conflict do nothing;
end;
$$;

create or replace function resident_announcements()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('title', a.title, 'body', a.body, 'created_on', a.created_on) order by a.created_on desc, a.title)
    from announcements a where a.status = 'current' and (a.expires_on is null or a.expires_on >= current_date)
      and (a.property_id is null or a.property_id in (
        select u.property_id from leases l join rental_units u on u.id = l.unit_id join lease_tenants lt on lt.lease_id = l.id
        where lt.tenant_id in (select resident_me()) and l.status in ('active', 'future')
        union select c.property_id from land_contracts c join land_contract_buyers b on b.contract_id = c.id where b.tenant_id in (select resident_me())))), '[]'::jsonb);
end;
$$;

create or replace function resident_messages()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  update tenant_messages set read_at = now() where tenant_id in (select resident_me()) and not from_resident and read_at is null;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'from_resident', m.from_resident, 'body', m.body, 'created_at', m.created_at, 'read_at', m.read_at) order by m.created_at)
    from tenant_messages m where m.tenant_id in (select resident_me())), '[]'::jsonb);
end;
$$;

create or replace function resident_message_send(p_body text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_tenant uuid; v_name text; v_unit text;
begin
  select x into v_tenant from resident_me() x limit 1;
  if v_tenant is null then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_body, ''))) < 2 then raise exception 'Write your message first.'; end if;
  if (select count(*) from tenant_messages where tenant_id = v_tenant and from_resident and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many messages in an hour. Please call the office.'; end if;
  insert into tenant_messages (tenant_id, from_resident, body, by_email) values (v_tenant, true, left(trim(p_body), 4000), auth.email());
  select t.name, (select u.address from lease_tenants lt join leases l on l.id = lt.lease_id join rental_units u on u.id = l.unit_id
                  where lt.tenant_id = t.id and l.status in ('active', 'future') limit 1) into v_name, v_unit from tenants t where t.id = v_tenant;
  insert into email_outbox (to_email, subject, html, kind) select value, 'Message from ' || v_name || coalesce(' — ' || v_unit, ''),
    '<p><i>' || repair_esc(left(trim(p_body), 4000)) || '</i></p><p>Reply on the Messages page (replies are emailed to the tenant and kept in their portal).</p>', 'message_staff'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function resident_profile() from public, anon;
revoke all on function resident_profile_save(text, text, text, text) from public, anon;
revoke all on function resident_profile_confirm() from public, anon;
revoke all on function resident_contact_change(text, text) from public, anon;
revoke all on function resident_letters(text) from public, anon;
revoke all on function resident_letter_viewed(uuid) from public, anon;
revoke all on function resident_announcements() from public, anon;
revoke all on function resident_messages() from public, anon;
revoke all on function resident_message_send(text) from public, anon;
grant execute on function resident_profile() to authenticated;
grant execute on function resident_profile_save(text, text, text, text) to authenticated;
grant execute on function resident_profile_confirm() to authenticated;
grant execute on function resident_contact_change(text, text) to authenticated;
grant execute on function resident_letters(text) to authenticated;
grant execute on function resident_letter_viewed(uuid) to authenticated;
grant execute on function resident_announcements() to authenticated;
grant execute on function resident_messages() to authenticated;
grant execute on function resident_message_send(text) to authenticated;

-- Staff: monthly letters ---------------------------------------------------------

create or replace function letters_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('tenants', (select count(*) from current_tenant_recipients(null)),
    'letters', coalesce((select jsonb_agg(to_jsonb(r) - 'search' || jsonb_build_object('views', (select count(*) from rule_letter_views v where v.letter_id = r.id),
        'viewers', (select jsonb_agg(t.name order by t.name) from rule_letter_views v join tenants t on t.id = v.tenant_id where v.letter_id = r.id)) order by r.month desc)
      from rule_letters r), '[]'::jsonb));
end;
$$;

create or replace function letters_staff_save(p_id uuid, p_month date, p_title text, p_rule_topic text, p_lease_section text, p_summary text, p_transcript text,
                                              p_media_path text, p_media_kind text, p_media_mime text, p_seconds int)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid; v_status text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_month is null then raise exception 'Choose the month.'; end if;
  if length(trim(coalesce(p_title, ''))) < 3 or length(trim(coalesce(p_rule_topic, ''))) < 3 then raise exception 'Enter a title and the rule this letter is about.'; end if;
  if length(trim(coalesce(p_summary, ''))) < 20 then raise exception 'Write the written version (at least a few sentences) so tenants can read it and find it by search.'; end if;
  if p_media_path is not null and (p_media_kind not in ('video', 'audio') or p_media_path !~ '^[0-9]{4}-[0-9]{2}/') then raise exception 'Bad recording.'; end if;
  select status into v_status from rule_letters where id = p_id;
  if v_status = 'published' then raise exception 'This letter is already sent to tenants.'; end if;
  insert into rule_letters (id, month, title, rule_topic, lease_section, summary, transcript, media_path, media_kind, media_mime, duration_seconds, created_by)
  values (coalesce(p_id, gen_random_uuid()), date_trunc('month', p_month)::date, trim(p_title), trim(p_rule_topic), nullif(trim(p_lease_section), ''), trim(p_summary),
          nullif(trim(p_transcript), ''), p_media_path, case when p_media_path is not null then p_media_kind end, p_media_mime, p_seconds, auth.email())
  on conflict (id) do update set month = excluded.month, title = excluded.title, rule_topic = excluded.rule_topic, lease_section = excluded.lease_section,
    summary = excluded.summary, transcript = excluded.transcript, media_path = coalesce(excluded.media_path, rule_letters.media_path),
    media_kind = coalesce(excluded.media_kind, rule_letters.media_kind), media_mime = coalesce(excluded.media_mime, rule_letters.media_mime),
    duration_seconds = coalesce(excluded.duration_seconds, rule_letters.duration_seconds), updated_at = now()
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  raise exception 'There is already a letter for %. Open that one instead.', to_char(p_month, 'FMMonth YYYY');
end;
$$;

create or replace function letters_staff_publish(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r rule_letters; t record; n int := 0; v_url text := (select value from portal_settings where key = 'resident_url');
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from rule_letters where id = p_id;
  if r.id is null then raise exception 'Letter not found'; end if;
  if r.status = 'published' then raise exception 'Already sent.'; end if;
  if r.media_path is null then raise exception 'Record or upload the video or audio first.'; end if;
  update rule_letters set status = 'published', published_at = now(), updated_at = now() where id = p_id;
  for t in select * from current_tenant_recipients(null) loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Your ' || to_char(r.month, 'FMMonth') || ' letter: ' || r.title,
      tenant_email_wrap(split_part(t.name, ' ', 1),
        '<p>This month''s ' || r.media_kind || ' letter is about <b>' || repair_esc(r.rule_topic) || '</b>' || coalesce(' (' || repair_esc(r.lease_section) || ')', '') || '.</p>' ||
        '<p>' || repair_esc(left(r.summary, 600)) || case when length(r.summary) > 600 then '…' else '' end || '</p>' ||
        '<p><a href="' || v_url || '#letters">Watch or listen in your resident portal</a>. Past letters are there too, and you can search them.</p>' ||
        '<p style="color:#555">Also: is your phone number, email and emergency contact still right? Check them on the Profile page of the portal.</p>'),
      'rule_letter');
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'emailed', n);
end;
$$;

-- Staff: announcements ------------------------------------------------------------

create or replace function announcements_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'announcements', coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object('property', p.name) order by a.created_on desc, a.title)
      from announcements a left join rental_properties p on p.id = a.property_id), '[]'::jsonb),
    'properties', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name) from rental_properties p), '[]'::jsonb));
end;
$$;

create or replace function announcements_staff_post(p_title text, p_body text, p_property uuid, p_expires date, p_email boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid; t record; n int := 0; v_where text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_title, ''))) < 3 or length(trim(coalesce(p_body, ''))) < 5 then raise exception 'Enter a title and the announcement.'; end if;
  if p_expires is not null and p_expires < current_date then raise exception 'The end date is in the past.'; end if;
  insert into announcements (title, body, status, created_on, expires_on, property_id, posted_by)
  values (trim(p_title), trim(p_body), 'current', current_date, p_expires, p_property, auth.email()) returning id into v_id;
  if p_email then
    select name into v_where from rental_properties where id = p_property;
    for t in select * from current_tenant_recipients(p_property) loop
      insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Announcement: ' || trim(p_title),
        tenant_email_wrap(split_part(t.name, ' ', 1), '<p><b>' || repair_esc(trim(p_title)) || '</b></p><p>' ||
          replace(repair_esc(trim(p_body)), E'\n', '<br>') || '</p><p>It is also posted in your resident portal under Announcements.</p>'), 'announcement');
      n := n + 1;
    end loop;
    update announcements set emailed_count = n where id = v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'emailed', n);
end;
$$;

create or replace function announcements_staff_expire(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update announcements set status = 'expired' where id = p_id;
  return jsonb_build_object('ok', found);
end;
$$;

-- Staff: messages and contact changes ----------------------------------------------

create or replace function messages_staff_inbox()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'threads', coalesce((select jsonb_agg(x order by x->>'last_at' desc) from (
      select jsonb_build_object('tenant_id', t.id, 'name', t.name, 'email', t.email, 'phone', t.phone,
        'unit', (select u.address from lease_tenants lt join leases l on l.id = lt.lease_id join rental_units u on u.id = l.unit_id where lt.tenant_id = t.id order by l.start_date desc limit 1),
        'last_at', max(m.created_at), 'unread', count(*) filter (where m.from_resident and m.read_at is null),
        'last', (select body from tenant_messages z where z.tenant_id = t.id order by z.created_at desc limit 1)) x
      from tenant_messages m join tenants t on t.id = m.tenant_id group by t.id) s), '[]'::jsonb),
    'contact_changes', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('name', (select name from tenants where lower(email) = lower(c.requested_by) limit 1)) order by c.requested_at)
      from tenant_contact_changes c where c.status = 'pending'), '[]'::jsonb),
    'tenants', coalesce((select jsonb_agg(jsonb_build_object('tenant_id', r.tenant_id, 'name', r.name) order by r.name) from current_tenant_recipients(null) r), '[]'::jsonb));
end;
$$;

create or replace function messages_staff_thread(p_tenant uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update tenant_messages set read_at = now() where tenant_id = p_tenant and from_resident and read_at is null;
  return jsonb_build_object('tenant', (select jsonb_build_object('name', name, 'email', email, 'phone', phone, 'alt_phone', alt_phone,
      'emergency_name', emergency_name, 'emergency_phone', emergency_phone, 'emergency_relation', emergency_relation, 'profile_confirmed_at', profile_confirmed_at) from tenants where id = p_tenant),
    'messages', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from tenant_messages m where m.tenant_id = p_tenant), '[]'::jsonb));
end;
$$;

create or replace function messages_staff_reply(p_tenant uuid, p_body text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare t tenants;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into t from tenants where id = p_tenant;
  if t.id is null then raise exception 'Tenant not found'; end if;
  if length(trim(coalesce(p_body, ''))) < 2 then raise exception 'Write the reply first.'; end if;
  insert into tenant_messages (tenant_id, from_resident, body, by_email) values (p_tenant, false, left(trim(p_body), 4000), auth.email());
  if t.email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Message from 2nd Chance Housing',
      tenant_email_wrap(split_part(t.name, ' ', 1), '<p>' || replace(repair_esc(left(trim(p_body), 4000)), E'\n', '<br>') || '</p><p>Reply in your resident portal: <a href="' ||
        (select value from portal_settings where key = 'resident_url') || '#messages">Messages</a>.</p>'), 'message');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function contact_change_decide(p_id uuid, p_approve boolean, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c tenant_contact_changes; v_name text; v_body text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into c from tenant_contact_changes where id = p_id and status = 'pending';
  if c.id is null then raise exception 'Nothing to decide.'; end if;
  select name into v_name from tenants where lower(email) = lower(c.requested_by) limit 1;
  if p_approve then
    if c.field = 'email' and exists (select 1 from tenants where lower(email) = lower(c.new_value)) then raise exception 'Another tenant already uses that email.'; end if;
    if c.field = 'phone' then update tenants set phone = c.new_value where lower(email) = lower(c.requested_by);
    else update tenants set email = lower(c.new_value) where lower(email) = lower(c.requested_by); end if;
  end if;
  update tenant_contact_changes set status = case when p_approve then 'applied' else 'declined' end, decided_by = auth.email(), decided_at = now(),
    note = nullif(trim(p_note), '') where id = p_id;
  v_body := case when p_approve
    then '<p>Your ' || case when c.field = 'phone' then 'mobile number' else 'email address' end || ' on file was changed to <b>' || repair_esc(c.new_value) ||
         '</b>. ' || case when c.field = 'phone' then 'Sign-in codes will be texted to it.' else 'Sign in with the new email from now on.' end || '</p>'
    else '<p>We did not change your ' || case when c.field = 'phone' then 'mobile number' else 'email address' end || '.' ||
         coalesce(' ' || repair_esc(nullif(trim(p_note), '')), '') || '</p>' end ||
    '<p>If you didn''t ask for this, call us right away at ' || (select value from portal_settings where key = 'org_phone') || '.</p>';
  -- Tell the old address, and the new one when the email changed.
  insert into email_outbox (to_email, subject, html, kind) values (c.requested_by, 'Your contact information', tenant_email_wrap(split_part(v_name, ' ', 1), v_body), 'contact_change');
  if p_approve and c.field = 'email' then
    insert into email_outbox (to_email, subject, html, kind) values (lower(c.new_value), 'Your contact information', tenant_email_wrap(split_part(v_name, ' ', 1), v_body), 'contact_change');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function letters_staff_list() from public, anon;
revoke all on function letters_staff_save(uuid, date, text, text, text, text, text, text, text, text, int) from public, anon;
revoke all on function letters_staff_publish(uuid) from public, anon;
revoke all on function announcements_staff_list() from public, anon;
revoke all on function announcements_staff_post(text, text, uuid, date, boolean) from public, anon;
revoke all on function announcements_staff_expire(uuid) from public, anon;
revoke all on function messages_staff_inbox() from public, anon;
revoke all on function messages_staff_thread(uuid) from public, anon;
revoke all on function messages_staff_reply(uuid, text) from public, anon;
revoke all on function contact_change_decide(uuid, boolean, text) from public, anon;
grant execute on function letters_staff_list() to authenticated;
grant execute on function letters_staff_save(uuid, date, text, text, text, text, text, text, text, text, int) to authenticated;
grant execute on function letters_staff_publish(uuid) to authenticated;
grant execute on function announcements_staff_list() to authenticated;
grant execute on function announcements_staff_post(text, text, uuid, date, boolean) to authenticated;
grant execute on function announcements_staff_expire(uuid) to authenticated;
grant execute on function messages_staff_inbox() to authenticated;
grant execute on function messages_staff_thread(uuid) to authenticated;
grant execute on function messages_staff_reply(uuid, text) to authenticated;
grant execute on function contact_change_decide(uuid, boolean, text) to authenticated;

-- Rent cycle helper: on the 25th, remind staff if next month's letter isn't sent.
create or replace function letters_due_reminder(p_as_of date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m date := (date_trunc('month', p_as_of) + interval '1 month')::date;
begin
  if exists (select 1 from rule_letters where month = m and status = 'published') then return jsonb_build_object('reminded', false); end if;
  insert into email_outbox (to_email, subject, html, kind) select value, 'Record the ' || to_char(m, 'FMMonth') || ' rule letter',
    '<p>The ' || to_char(m, 'FMMonth YYYY') || ' video or audio rule letter isn''t sent yet. Record it on the Letters page (pick one rule to focus on) and send it by the 1st.</p>', 'letter_reminder'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('reminded', true, 'month', m);
end;
$$;
revoke all on function letters_due_reminder(date) from public, anon, authenticated;
grant execute on function letters_due_reminder(date) to service_role;

-- ROCA1 condo violation passed on to the tenant (composed on the Notices page).
insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields) values
('2c-condo-violation', 'Tenant', '2nd Chance — Condo (ROCA1) Violation', 'Condominium Rule Violation',
 'Passes a violation reported by the Royal Orleans Condominium Association (ROCA1) on to the tenant.',
 '<p style="text-align: center"><strong>NOTICE OF CONDOMINIUM RULE VIOLATION</strong></p>
<p>[[Current_Date]]</p>
<p>To: [[Lease_All_Tenants]]</p>
<p>[[Unit_Address]]</p>
<p>The Royal Orleans Condominium Association (ROCA1) has reported a violation of the association''s rules at your unit.</p>
<p><strong>Violation:</strong> [[Violation_Type]]</p>
<p><strong>What was reported:</strong> [[Violation_Description]]</p>
<p><strong>What you need to do:</strong> [[Violation_Action]]</p>
<p><strong>Deadline:</strong> [[Violation_Due_Date]]</p>
<p>Your lease makes the ROCA1 By-Laws and Rules and Regulations part of your Rules and Regulations, so a violation of the association''s rules is also a violation of your lease. Please correct it by the deadline.</p>
<p>If you believe this report is wrong, or have questions, call us at [[Sender_Phone]].</p>
<p>[[Sender_Signature]]</p>',
 array['Current_Date', 'Lease_All_Tenants', 'Unit_Address', 'Violation_Type', 'Violation_Description', 'Violation_Action', 'Violation_Due_Date', 'Sender_Phone', 'Sender_Signature'])
on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description, name = excluded.name;

-- Unread office replies (for the portal's Messages badge), without marking them read.
create or replace function resident_unread_messages()
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from tenant_messages where tenant_id in (select resident_me()) and not from_resident and read_at is null;
$$;
revoke all on function resident_unread_messages() from public, anon;
grant execute on function resident_unread_messages() to authenticated;
