-- Waitlist: people in Illinois, Wisconsin and elsewhere who call about the program or vacancies sign up with an email
-- (public page https://2ndchinc.org/waitlist/, edge function waitlist-join). When a unit opens, staff press
-- "Announce a unit" (https://2ndchinc.org/staff/waitlist/) and everyone who fits gets one email. Email only (no SMS yet).
create table if not exists waitlist (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  name text,
  state text,                                   -- WI, IL or other
  bedrooms text not null default 'any',         -- any, 1, 2, 3
  note text,
  token uuid not null default gen_random_uuid(),-- unsubscribe link
  status text not null default 'pending' check (status in ('pending','active','left')), -- pending until the emailed confirm link is used; only active get announcements
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  last_notified_at timestamptz,
  notify_count int not null default 0
);
create unique index if not exists waitlist_email_key on waitlist (lower(email));
alter table waitlist enable row level security;
grant select, insert, update, delete on waitlist to service_role;

-- Every sign-up attempt with the visitor's network address, kept 30 days (the function purges older rows). Staff use it to spot
-- one address making many sign-ups, and to trust a shared address (shelter, library, caseworker office).
create table if not exists waitlist_ip_log (
  id bigint generated always as identity primary key,
  ip text not null,
  email text,
  outcome text not null,                         -- joined, blocked, bad_check
  created_at timestamptz not null default now()
);
create index if not exists waitlist_ip_log_ip on waitlist_ip_log (ip, created_at desc);
alter table waitlist_ip_log enable row level security;
grant select, insert, delete on waitlist_ip_log to service_role;
grant usage on sequence waitlist_ip_log_id_seq to service_role;

-- Addresses staff have verified. A trusted address gets a much higher daily limit (default 10 new sign-ups per address per day).
create table if not exists waitlist_trusted_networks (
  id uuid primary key default gen_random_uuid(),
  ip text not null unique,
  label text not null,                           -- e.g. "Public library, Milwaukee"
  kind text not null default 'other' check (kind in ('shelter','library','caseworker','agency','other')),
  note text,
  added_at timestamptz not null default now()
);
alter table waitlist_trusted_networks enable row level security;
grant select on waitlist_trusted_networks to service_role;

create or replace function waitlist_staff_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'entries', coalesce((select jsonb_agg(to_jsonb(w) - 'token' order by w.created_at desc) from waitlist w), '[]'::jsonb),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', unit_number, 'address', address, 'bedrooms', bedrooms, 'occupancy', occupancy) order by unit_number)
                       from condo_units where occupancy = 'vacant'), '[]'::jsonb));
end $$;
revoke all on function waitlist_staff_list() from public, anon;
grant execute on function waitlist_staff_list() to authenticated;

-- Busy addresses (3 or more different emails in 7 days) and the trusted list, for the staff page.
create or replace function waitlist_staff_networks() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'busy', coalesce((select jsonb_agg(b order by b.tries desc) from (
        select l.ip, count(*) tries, count(distinct l.email) emails, count(*) filter (where l.outcome = 'blocked') blocked, max(l.created_at) last_seen
          from waitlist_ip_log l where l.created_at > now() - interval '7 days'
           and not exists (select 1 from waitlist_trusted_networks t where t.ip = l.ip)
         group by l.ip having count(distinct l.email) >= 3 or count(*) filter (where l.outcome = 'blocked') > 0) b), '[]'::jsonb),
    'trusted', coalesce((select jsonb_agg(to_jsonb(t) order by t.added_at desc) from waitlist_trusted_networks t), '[]'::jsonb));
end $$;
revoke all on function waitlist_staff_networks() from public, anon;
grant execute on function waitlist_staff_networks() to authenticated;

create or replace function waitlist_staff_trust(p_ip text, p_label text, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  p_ip := nullif(trim(coalesce(p_ip, '')), ''); p_label := nullif(trim(coalesce(p_label, '')), '');
  if p_ip is null or length(p_ip) > 64 then raise exception 'Enter the network address.'; end if;
  if p_label is null then raise exception 'Give it a name, such as the shelter or library.'; end if;
  insert into waitlist_trusted_networks (ip, label, kind)
  values (p_ip, left(p_label, 120), case when p_kind in ('shelter','library','caseworker','agency') then p_kind else 'other' end)
  on conflict (ip) do update set label = excluded.label, kind = excluded.kind;
end $$;
revoke all on function waitlist_staff_trust(text, text, text) from public, anon;
grant execute on function waitlist_staff_trust(text, text, text) to authenticated;

create or replace function waitlist_staff_untrust(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  delete from waitlist_trusted_networks where id = p_id;
end $$;
revoke all on function waitlist_staff_untrust(uuid) from public, anon;
grant execute on function waitlist_staff_untrust(uuid) to authenticated;

create or replace function waitlist_staff_remove(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  delete from waitlist where id = p_id;
end $$;
revoke all on function waitlist_staff_remove(uuid) from public, anon;
grant execute on function waitlist_staff_remove(uuid) to authenticated;

-- Queue one email per matching active entry. p_bedrooms: 'any' emails everyone; '1','2','3' emails those who want that size or 'any'.
create or replace function waitlist_staff_announce(p_unit text, p_bedrooms text, p_message text) returns int
language plpgsql security definer set search_path = public as $$
declare
  w record; n int := 0; v_addr text; v_msg text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  p_unit := nullif(trim(coalesce(p_unit, '')), '');
  if p_unit is null then raise exception 'Choose a unit.'; end if;
  select address into v_addr from condo_units where unit_number = p_unit;
  v_msg := replace(replace(replace(coalesce(left(trim(p_message), 1000), ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  for w in select * from waitlist where status = 'active'
             and (coalesce(p_bedrooms, 'any') = 'any' or bedrooms = 'any' or bedrooms = p_bedrooms) loop
    insert into email_outbox (to_email, subject, html, kind) values (
      w.email, 'A unit is available at 2nd Chance Housing',
      '<p>Hello' || case when w.name is not null then ' ' || replace(replace(replace(w.name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') else '' end || ',</p>'
      || '<p>You asked to hear when a home opens up. <b>Unit ' || replace(replace(replace(p_unit, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</b>'
      || case when v_addr is not null then ' at ' || replace(replace(replace(v_addr, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') else '' end || ' is available.</p>'
      || case when v_msg <> '' then '<p style="white-space:pre-wrap">' || v_msg || '</p>' else '' end
      || '<p>See the rent, deposit and details at <a href="https://2ndchinc.org/#units">https://2ndchinc.org/#units</a>, or apply at '
      || '<a href="https://2ndchinc.org/leasing/apply/">https://2ndchinc.org/leasing/apply/</a>.</p>'
      || '<p>Questions? Reply to this email or call (262) 236-5443.</p>'
      || '<p style="color:#666;font-size:12px">You are getting this because you joined the 2nd Chance Housing waitlist. '
      || '<a href="https://2ndchinc.org/waitlist/?leave=' || w.token || '">Take me off the list</a>.</p>',
      'waitlist_unit');
    update waitlist set last_notified_at = now(), notify_count = notify_count + 1 where id = w.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function waitlist_staff_announce(text, text, text) from public, anon;
grant execute on function waitlist_staff_announce(text, text, text) to authenticated;
