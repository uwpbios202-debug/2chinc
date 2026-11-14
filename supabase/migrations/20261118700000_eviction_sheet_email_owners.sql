-- Eviction costs: an Email button for the office and for the owners of Units 15 and 16 (Stephen, 11/10/2026).
-- Owners of the units in portal setting `eviction_sheet_owner_units` (today 15, 16) see the eviction budget (the template) and any sheet
-- tied to a lease on their unit, read-only, on the owner portal (#eviction), and can print it or email it to any address.
-- The office emails from https://2ndchinc.org/staff/eviction-costs/ . Each email is logged (eviction_sheet_emails); at most 20 a day per sender.

insert into portal_settings (key, value) values ('eviction_sheet_owner_units', '15,16') on conflict (key) do nothing;

create table if not exists eviction_sheet_emails (
  id uuid primary key default gen_random_uuid(),
  sheet_id uuid references eviction_sheets(id) on delete set null,
  sent_by text not null,
  sender_role text not null check (sender_role in ('staff', 'owner')),
  to_email text not null,
  created_at timestamptz not null default now()
);
alter table eviction_sheet_emails enable row level security;
revoke all on table eviction_sheet_emails from public, anon, authenticated;
grant all on table eviction_sheet_emails to service_role;

-- The signed-in owner's units that may see eviction sheets.
create or replace function eviction_owner_units_mine()
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct cu.unit_number), '{}')
    from condo_ownerships co join condo_units cu on cu.id = co.unit_id
   where condo_session_ok() and co.owner_id = condo_owner_for_email(auth.email()) and co.end_date is null
     and cu.unit_number = any (string_to_array(replace(coalesce((select value from portal_settings where key = 'eviction_sheet_owner_units'), ''), ' ', ''), ','));
$$;
revoke all on function eviction_owner_units_mine() from public, anon, authenticated;

-- Sheets an owner may see: the template, and sheets tied to a lease on one of their units.
create or replace function eviction_owner_can_see(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select cardinality(eviction_owner_units_mine()) > 0 and exists (
    select 1 from eviction_sheets s left join leases l on l.id = s.lease_id left join rental_units ru on ru.id = l.unit_id
     where s.id = p_id and (s.is_template or ru.unit_number = any (eviction_owner_units_mine())));
$$;
revoke all on function eviction_owner_can_see(uuid) from public, anon, authenticated;

create or replace function eviction_sheets_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_units text[] := eviction_owner_units_mine();
begin
  if cardinality(v_units) = 0 then return jsonb_build_object('allowed', false, 'sheets', '[]'::jsonb); end if;
  return jsonb_build_object('allowed', true, 'units', to_jsonb(v_units), 'sheets', coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'title', case when s.is_template then 'Eviction expense budget (Milwaukee County)' else s.title end,
        'is_template', s.is_template, 'unit', ru.unit_number, 'note', s.note, 'updated_at', s.updated_at,
        'items', coalesce((select jsonb_agg(jsonb_build_object('expense', i.expense, 'covers', i.covers, 'status', i.status, 'kind', i.kind, 'amount', i.amount, 'note', i.note)
                           order by i.sort) from eviction_sheet_items i where i.sheet_id = s.id), '[]'::jsonb))
      order by s.is_template desc, s.updated_at desc)
    from eviction_sheets s left join leases l on l.id = s.lease_id left join rental_units ru on ru.id = l.unit_id
   where s.is_template or ru.unit_number = any (v_units)), '[]'::jsonb));
end;
$$;
revoke all on function eviction_sheets_mine() from public, anon;
grant execute on function eviction_sheets_mine() to authenticated;

-- The sheet as an email-safe HTML table.
create or replace function eviction_sheet_html(p_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare s eviction_sheets; v_rows text; v_total numeric;
begin
  select * into s from eviction_sheets where id = p_id;
  select string_agg('<tr><td style="border:1px solid #bbb;padding:6px;vertical-align:top"><b>' || repair_esc(i.expense) || '</b></td>'
      || '<td style="border:1px solid #bbb;padding:6px;vertical-align:top">' || repair_esc(i.covers)
      || case when i.note <> '' then '<div style="font-size:12px;color:#555;margin-top:3px">' || repair_esc(i.note) || '</div>' else '' end || '</td>'
      || '<td style="border:1px solid #bbb;padding:6px;vertical-align:top">' || repair_esc(i.status) || '</td>'
      || '<td style="border:1px solid #bbb;padding:6px;vertical-align:top;text-align:right;white-space:nowrap">'
      || case when i.amount > 0 then to_char(i.amount, 'FM$999,990.00') else 'to be entered' end || '</td></tr>', '' order by i.sort),
    coalesce(sum(i.amount), 0)
    into v_rows, v_total from eviction_sheet_items i where i.sheet_id = p_id;
  return '<h2 style="margin:0 0 4px">' || repair_esc(case when s.is_template then 'Eviction expense budget (Milwaukee County)' else s.title end) || '</h2>'
    || '<table style="border-collapse:collapse;width:100%;font-size:14px"><thead><tr>'
    || '<th style="border:1px solid #bbb;padding:6px;text-align:left">Expense</th><th style="border:1px solid #bbb;padding:6px;text-align:left">What it covers</th>'
    || '<th style="border:1px solid #bbb;padding:6px;text-align:left">Cost status</th><th style="border:1px solid #bbb;padding:6px;text-align:right">Amount</th></tr></thead><tbody>'
    || coalesce(v_rows, '')
    || '<tr><td colspan="3" style="border:1px solid #bbb;padding:6px"><b>Known costs so far</b> (rows "to be entered" are not counted)</td>'
    || '<td style="border:1px solid #bbb;padding:6px;text-align:right"><b>' || to_char(v_total, 'FM$999,990.00') || '</b></td></tr></tbody></table>'
    || case when coalesce(s.note, '') <> '' then '<p style="font-size:12px;color:#555">' || repair_esc(s.note) || '</p>' else '' end;
end;
$$;
revoke all on function eviction_sheet_html(uuid) from public, anon, authenticated;

-- Email a sheet: office staff (any sheet) or an owner (sheets they may see), to any one address.
create or replace function eviction_sheet_email(p_id uuid, p_to text, p_message text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare v_role text; v_by text := lower(auth.email()); v_from text; v_to text := lower(trim(coalesce(p_to, ''))); s eviction_sheets;
begin
  if condo_session_ok() and condo_is_staff() then v_role := 'staff'; v_from := '2nd Chance Housing (for ROCA1)';
  elsif eviction_owner_can_see(p_id) then v_role := 'owner'; v_from := (select name from condo_owners where id = condo_owner_for_email(auth.email()));
  else raise exception 'You can''t email this sheet.' using errcode = '42501'; end if;
  select * into s from eviction_sheets where id = p_id;
  if s.id is null then raise exception 'That sheet isn''t on file.'; end if;
  if v_to !~ '^[^@\s<>,;]+@[^@\s<>,;]+\.[a-z]{2,}$' then raise exception 'Enter one email address.'; end if;
  if (select count(*) from eviction_sheet_emails where sent_by = v_by and created_at > now() - interval '1 day') >= 20 then
    raise exception 'That''s 20 emails today; please try again tomorrow.'; end if;
  insert into email_outbox (to_email, subject, html, kind) values (v_to,
    case when s.is_template then 'Eviction expense budget (Milwaukee County)' else 'Eviction costs: ' || s.title end,
    '<p>' || repair_esc(coalesce(v_from, 'An owner')) || ' sent you this eviction expense sheet from 2ndchinc.org.</p>'
    || case when length(trim(coalesce(p_message, ''))) > 0 then '<p style="white-space:pre-wrap;border-left:3px solid #ccc;padding-left:10px">' || repair_esc(left(trim(p_message), 1500)) || '</p>' else '' end
    || eviction_sheet_html(p_id)
    || '<p style="font-size:12px;color:#555">A budgeting tool, not legal advice. 2nd Chance Housing, for ROCA1 · https://2ndchinc.org</p>',
    'eviction_sheet');
  insert into eviction_sheet_emails (sheet_id, sent_by, sender_role, to_email) values (p_id, v_by, v_role, v_to);
end;
$$;
revoke all on function eviction_sheet_email(uuid, text, text) from public, anon;
grant execute on function eviction_sheet_email(uuid, text, text) to authenticated;

-- Staff list: also the owners of the eviction-sheet units, for the "Email to an owner" picks on the staff page.
create or replace function eviction_sheets_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform eviction_staff_check();
  return jsonb_build_object(
    'sheets', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'is_template', s.is_template, 'lease_id', s.lease_id,
        'unit', ru.unit_number, 'updated_at', s.updated_at,
        'total', (select coalesce(sum(i.amount), 0) from eviction_sheet_items i where i.sheet_id = s.id))
        order by s.is_template desc, s.updated_at desc)
      from eviction_sheets s left join leases l on l.id = s.lease_id left join rental_units ru on ru.id = l.unit_id), '[]'::jsonb),
    'leases', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'unit', ru.unit_number, 'tenants', l.tenants_label, 'status', l.status)
        order by nullif(regexp_replace(ru.unit_number, '\D', '', 'g'), '')::int nulls last, l.start_date desc)
      from leases l join rental_units ru on ru.id = l.unit_id where l.status in ('active', 'future')), '[]'::jsonb),
    'owners', coalesce((select jsonb_agg(jsonb_build_object('unit', cu.unit_number, 'name', o.name, 'email', o.email) order by cu.unit_number)
      from condo_ownerships co join condo_units cu on cu.id = co.unit_id join condo_owners o on o.id = co.owner_id
     where co.end_date is null and coalesce(o.email, '') <> ''
       and cu.unit_number = any (string_to_array(replace(coalesce((select value from portal_settings where key = 'eviction_sheet_owner_units'), ''), ' ', ''), ','))), '[]'::jsonb));
end;
$$;
revoke all on function eviction_sheets_list() from public, anon;
grant execute on function eviction_sheets_list() to authenticated;
