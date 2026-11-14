-- Menards receipts and rebates (Stephen, 11/8/2026): https://2ndchinc.org/staff/rebates/ (office staff, authenticator code).
--  * Staff upload a Menards receipt (photo or PDF, in-store or downloaded from the Menards account's order tracker).
--    The menards-read function has Claude read it: store, date, receipt number, items, totals and the rebate lines
--    (rebate number, amount, mail-by date, mailing address when printed). Staff check the figures and save.
--  * Each rebate is tracked: to mail -> mailed -> check received (or denied). The page prints a #10 envelope
--    (return address + rebate mailing address) and a one-page rebate claim (claimant block + rebates enclosed).
--  * Receipt files live in the private bucket "menards-receipts" under <receipt id>/<file>; staff only.
-- New tables: explicit grants (Supabase change of 10/30/2026). The page reaches them only through the functions below.

create table if not exists menards_receipts (
  id uuid primary key,
  store text,                       -- e.g. "Menards #3205, Milwaukee WI"
  purchased_on date,
  receipt_no text,                  -- transaction / receipt number printed on it
  for_what text,                    -- which unit, building or job it was for
  subtotal numeric(10,2),
  tax numeric(10,2),
  total numeric(10,2),
  paid_with text,                   -- e.g. "Visa ...1234" (last 4 only)
  items jsonb not null default '[]'::jsonb,   -- [{description, sku, qty, amount}]
  files text[] not null default '{}',         -- storage paths in menards-receipts
  ai_read jsonb,                    -- what Claude read, kept as it came back
  ai_read_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  created_by text,
  updated_at timestamptz not null default now()
);

create table if not exists menards_rebates (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references menards_receipts(id) on delete cascade,
  rebate_number text,               -- the number on the rebate receipt / form
  description text,                 -- e.g. "11% rebate" or the item it is for
  amount numeric(10,2) not null default 0 check (amount >= 0),
  mail_by date,                     -- postmark deadline
  mail_to text,                     -- full mailing address, one line per row
  status text not null default 'to_mail' check (status in ('to_mail', 'mailed', 'received', 'denied')),
  mailed_on date,
  received_on date,
  check_amount numeric(10,2),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists menards_rebates_receipt on menards_rebates (receipt_id);

alter table menards_receipts enable row level security;
alter table menards_rebates enable row level security;
revoke all on table menards_receipts, menards_rebates from anon, authenticated;
grant all on table menards_receipts, menards_rebates to service_role;

-- Claimant and addresses printed on the claim and the envelope (editable on the page).
insert into portal_settings (key, value) values
  ('menards_claimant_name', '2nd Chance Housing Inc.'),
  ('menards_claimant_street', '6626 N Bourbon St'),
  ('menards_claimant_city_state_zip', 'Milwaukee, WI 53224'),
  ('menards_claimant_phone', '(262) 236-5443'),
  ('menards_claimant_email', 'info@2ndchinc.org'),
  ('menards_default_mail_to', E'Menards Rebate Offer\nP.O. Box 155\nElk Mound, WI 54739-0155')
on conflict (key) do nothing;

-- Receipt files: private, staff only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('menards-receipts', 'menards-receipts', false, 15728640, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "menards receipts upload staff" on storage.objects;
create policy "menards receipts upload staff" on storage.objects for insert to authenticated
  with check (bucket_id = 'menards-receipts' and condo_session_ok() and condo_is_staff());
drop policy if exists "menards receipts read staff" on storage.objects;
create policy "menards receipts read staff" on storage.objects for select to authenticated
  using (bucket_id = 'menards-receipts' and condo_session_ok() and condo_is_staff());
drop policy if exists "menards receipts delete staff" on storage.objects;
create policy "menards receipts delete staff" on storage.objects for delete to authenticated
  using (bucket_id = 'menards-receipts' and condo_session_ok() and condo_is_staff());

create or replace function menards_staff_only()
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Office staff two-step sign-in required' using errcode = '42501'; end if;
end;
$$;
revoke all on function menards_staff_only() from public, anon;
grant execute on function menards_staff_only() to authenticated;

create or replace function menards_view()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform menards_staff_only();
  return jsonb_build_object(
    'settings', coalesce((select jsonb_object_agg(key, value) from portal_settings where key like 'menards\_%'), '{}'::jsonb),
    'receipts', coalesce((select jsonb_agg(to_jsonb(r) - 'ai_read' || jsonb_build_object(
        'rebates', coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at) from menards_rebates b where b.receipt_id = r.id), '[]'::jsonb))
        order by r.purchased_on desc nulls first, r.created_at desc) from menards_receipts r), '[]'::jsonb));
end;
$$;
revoke all on function menards_view() from public, anon;
grant execute on function menards_view() to authenticated;

-- Save a receipt and its rebates in one go (the edit form). Rebates not in the list are removed.
create or replace function menards_receipt_save(p jsonb)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid := (p->>'id')::uuid; b jsonb; v_keep uuid[] := '{}'; v_bid uuid;
begin
  perform menards_staff_only();
  if v_id is null then raise exception 'Receipt id missing'; end if;
  insert into menards_receipts (id, created_by) values (v_id, lower(auth.email())) on conflict (id) do nothing;
  update menards_receipts set
    store = nullif(trim(p->>'store'), ''),
    purchased_on = nullif(p->>'purchased_on', '')::date,
    receipt_no = nullif(trim(p->>'receipt_no'), ''),
    for_what = nullif(trim(p->>'for_what'), ''),
    subtotal = nullif(p->>'subtotal', '')::numeric,
    tax = nullif(p->>'tax', '')::numeric,
    total = nullif(p->>'total', '')::numeric,
    paid_with = nullif(trim(p->>'paid_with'), ''),
    items = coalesce(p->'items', items),
    files = coalesce((select array_agg(x) from jsonb_array_elements_text(p->'files') x where x like v_id::text || '/%'), files),
    notes = nullif(trim(p->>'notes'), ''),
    updated_at = now()
  where id = v_id;
  for b in select * from jsonb_array_elements(coalesce(p->'rebates', '[]'::jsonb)) loop
    v_bid := nullif(b->>'id', '')::uuid;
    if v_bid is null or not exists (select 1 from menards_rebates where id = v_bid and receipt_id = v_id) then
      insert into menards_rebates (receipt_id) values (v_id) returning id into v_bid;
    end if;
    update menards_rebates set
      rebate_number = nullif(trim(b->>'rebate_number'), ''),
      description = nullif(trim(b->>'description'), ''),
      amount = coalesce(nullif(b->>'amount', '')::numeric, 0),
      mail_by = nullif(b->>'mail_by', '')::date,
      mail_to = nullif(trim(b->>'mail_to'), ''),
      status = coalesce(nullif(b->>'status', ''), 'to_mail'),
      mailed_on = nullif(b->>'mailed_on', '')::date,
      received_on = nullif(b->>'received_on', '')::date,
      check_amount = nullif(b->>'check_amount', '')::numeric,
      notes = nullif(trim(b->>'notes'), ''),
      updated_at = now()
    where id = v_bid;
    v_keep := v_keep || v_bid;
  end loop;
  delete from menards_rebates where receipt_id = v_id and not (id = any (v_keep));
  return v_id;
end;
$$;
revoke all on function menards_receipt_save(jsonb) from public, anon;
grant execute on function menards_receipt_save(jsonb) to authenticated;

-- Mark rebates mailed (after printing the claim and envelope), or received / denied.
create or replace function menards_rebates_mark(p_ids uuid[], p_status text, p_on date default null, p_check_amount numeric default null)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  perform menards_staff_only();
  if p_status not in ('to_mail', 'mailed', 'received', 'denied') then raise exception 'Bad status'; end if;
  update menards_rebates set status = p_status,
    mailed_on = case when p_status = 'mailed' then coalesce(p_on, (now() at time zone 'America/Chicago')::date)
                     when p_status = 'to_mail' then null else mailed_on end,
    received_on = case when p_status = 'received' then coalesce(p_on, (now() at time zone 'America/Chicago')::date)
                       when p_status in ('to_mail', 'mailed') then null else received_on end,
    check_amount = case when p_status = 'received' then coalesce(p_check_amount, amount) else check_amount end,
    updated_at = now()
  where id = any (p_ids);
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function menards_rebates_mark(uuid[], text, date, numeric) from public, anon;
grant execute on function menards_rebates_mark(uuid[], text, date, numeric) to authenticated;

create or replace function menards_receipt_delete(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_files text[];
begin
  perform menards_staff_only();
  delete from menards_receipts where id = p_id returning files into v_files;
  return to_jsonb(coalesce(v_files, '{}'));
end;
$$;
revoke all on function menards_receipt_delete(uuid) from public, anon;
grant execute on function menards_receipt_delete(uuid) to authenticated;

create or replace function menards_settings_save(p jsonb)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare k text;
begin
  perform menards_staff_only();
  foreach k in array array['menards_claimant_name', 'menards_claimant_street', 'menards_claimant_city_state_zip',
                           'menards_claimant_phone', 'menards_claimant_email', 'menards_default_mail_to'] loop
    if p ? k then
      insert into portal_settings (key, value) values (k, coalesce(trim(p->>k), ''))
      on conflict (key) do update set value = excluded.value;
    end if;
  end loop;
end;
$$;
revoke all on function menards_settings_save(jsonb) from public, anon;
grant execute on function menards_settings_save(jsonb) to authenticated;

-- System costs: the receipt reader is paid per use.
insert into system_cost_items (name, what, amount, months, status, notes, sort)
select 'Claude API (Menards receipts)', 'Reads uploaded Menards receipts on https://2ndchinc.org/staff/rebates/', 0, 1, 'per_payment',
       'About 2 to 5 cents per receipt read (Claude Opus 5.5). Billed by Anthropic.', 120
where not exists (select 1 from system_cost_items where name = 'Claude API (Menards receipts)');
