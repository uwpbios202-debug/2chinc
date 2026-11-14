-- Rent ready (Stephen, 11/10/2026): a listed unit is NOT shown as ready until staff mark it rent ready on
-- https://2ndchinc.org/staff/waitlist/ . Until then the landing page says applications are being accepted.
-- Marking a unit rent ready emails everyone on the confirmed waitlist once, in waitlist order (earliest sign-up first),
-- and each email tells the person their place on the list. Number 1 gets a head start: emailed at once, everyone else
-- waitlist_head_start_hours (48) later. Everyone is emailed whatever size they asked for (Stephen, 11/10/2026).
-- Units 15 and 17 start as not rent ready.
create table if not exists unit_rent_ready (
  unit_number text primary key,
  ready boolean not null default false,
  changed_at timestamptz not null default now(),
  changed_by text,
  waitlist_emailed_at timestamptz,               -- last waitlist email sent for this unit
  waitlist_emailed_count int not null default 0
);
alter table unit_rent_ready enable row level security;
grant select, insert, update, delete on unit_rent_ready to service_role;
-- authenticated and anon: no direct access (staff and the public go through the functions below).

insert into unit_rent_ready (unit_number, ready, changed_by) values ('15', false, 'setup'), ('17', false, 'setup')
on conflict (unit_number) do nothing;

insert into portal_settings (key, value) values ('waitlist_head_start_hours', '48') on conflict (key) do nothing;

-- What the public website may know: only which unit numbers are rent ready.
create or replace function public_units_rent_ready()
returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(unit_number order by unit_number), '{}') from unit_rent_ready where ready;
$$;
revoke all on function public_units_rent_ready() from public;
grant execute on function public_units_rent_ready() to anon, authenticated;

-- The send schedule: one row per waitlist person each time a unit is marked ready. waitlist_ready_release() turns due rows into emails.
create table if not exists waitlist_ready_sends (
  id bigint generated always as identity primary key,
  unit_number text not null,
  waitlist_id uuid not null references waitlist(id) on delete cascade,
  position int not null,
  total int not null,
  head_start_hours int not null,
  note text,
  send_at timestamptz not null,
  queued_at timestamptz,            -- email written to email_outbox
  skipped text,                     -- why it was not sent (unit marked not ready, person left the list)
  created_at timestamptz not null default now()
);
create index if not exists waitlist_ready_sends_due on waitlist_ready_sends (send_at) where queued_at is null and skipped is null;
alter table waitlist_ready_sends enable row level security;
grant select, insert, update, delete on waitlist_ready_sends to service_role;
grant usage on sequence waitlist_ready_sends_id_seq to service_role;

-- Staff list: units 2nd Chance manages that are not leased and not owner-occupied, with their rent-ready state and schedule.
create or replace function waitlist_staff_ready_units()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'unit', ru.unit_number,
             'address', regexp_replace(coalesce(cu.address, ru.address, ''), '\s*-\s*\d+$', ''),
             'ready', coalesce(r.ready, false),
             'changed_at', r.changed_at, 'changed_by', r.changed_by,
             'emailed_at', r.waitlist_emailed_at, 'emailed_count', coalesce(r.waitlist_emailed_count, 0),
             'waiting', (select count(*) from waitlist_ready_sends s where s.unit_number = ru.unit_number and s.queued_at is null and s.skipped is null),
             'waiting_at', (select min(s.send_at) from waitlist_ready_sends s where s.unit_number = ru.unit_number and s.queued_at is null and s.skipped is null))
           order by length(ru.unit_number), ru.unit_number)
      from rental_units ru
      left join condo_units cu on cu.unit_number = ru.unit_number
      left join unit_rent_ready r on r.unit_number = ru.unit_number
     where ru.managed_by <> 'owner'
       and coalesce(cu.occupancy, '') <> 'owner'
       and not (ru.unit_number = any (public_units_leased()))), '[]'::jsonb);
end $$;
revoke all on function waitlist_staff_ready_units() from public, anon;
grant execute on function waitlist_staff_ready_units() to authenticated;

-- Write the waitlist emails that are due, in waitlist order. Returns how many were queued (the cron job flushes the outbox when > 0).
create or replace function waitlist_ready_release()
returns int
language plpgsql security definer set search_path = public as $$
declare
  r record; n int := 0; v_addr text; esc_unit text; v_msg text; v_name text;
begin
  for r in select s.*, w.email, w.name, w.token, w.status as w_status, coalesce(u.ready, false) as unit_ready
             from waitlist_ready_sends s
             join waitlist w on w.id = s.waitlist_id
             left join unit_rent_ready u on u.unit_number = s.unit_number
            where s.queued_at is null and s.skipped is null and s.send_at <= now()
            order by s.send_at, s.position
            for update of s skip locked loop
    if not r.unit_ready then update waitlist_ready_sends set skipped = 'unit marked not ready' where id = r.id; continue; end if;
    if r.w_status <> 'active' then update waitlist_ready_sends set skipped = 'left the waitlist' where id = r.id; continue; end if;
    select regexp_replace(address, '\s*-\s*\d+$', '') into v_addr from condo_units where unit_number = r.unit_number;
    esc_unit := replace(replace(replace(r.unit_number, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_msg := replace(replace(replace(coalesce(r.note, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_name := case when r.name is not null then ' ' || replace(replace(replace(r.name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') else '' end;
    insert into email_outbox (to_email, subject, html, kind) values (
      r.email, 'Unit ' || r.unit_number || ' is ready: you are number ' || r.position || ' on the 2nd Chance Housing waitlist',
      '<p>Hello' || v_name || ',</p>'
      || '<p>You asked to hear when a home opens up. <b>Unit ' || esc_unit || '</b>'
      || case when coalesce(v_addr, '') <> '' then ' at ' || replace(replace(replace(v_addr, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ', Milwaukee' else '' end
      || ' is now ready to move in.</p>'
      || '<p>You are <b>number ' || r.position || ' of ' || r.total || '</b> on our waitlist. '
      || case when r.position = 1 and r.total > 1 then 'Because you are first on the list, you are getting this email ' || r.head_start_hours || ' hours before anyone else.'
              when r.position = 1 then 'You are first on the list.'
              else 'The person who joined first was emailed ' || r.head_start_hours || ' hours before the rest of the list.' end || '</p>'
      || case when v_msg <> '' then '<p style="white-space:pre-wrap">' || v_msg || '</p>' else '' end
      || '<p>Applying is free. See the rent, deposit and details at <a href="https://2ndchinc.org/#units">https://2ndchinc.org/#units</a>, and apply at '
      || '<a href="https://2ndchinc.org/leasing/apply/?unit=' || esc_unit || '">https://2ndchinc.org/leasing/apply/?unit=' || esc_unit || '</a>.</p>'
      || '<p>Questions? Reply to this email or call (262) 236-5443.</p>'
      || '<p style="color:#666;font-size:12px">You are getting this because you joined the 2nd Chance Housing waitlist. '
      || '<a href="https://2ndchinc.org/waitlist/?leave=' || r.token || '">Take me off the list</a>.</p>',
      'waitlist_unit');
    update waitlist_ready_sends set queued_at = now() where id = r.id;
    update waitlist set last_notified_at = now(), notify_count = notify_count + 1 where id = r.waitlist_id;
    update unit_rent_ready set waitlist_emailed_at = now(), waitlist_emailed_count = waitlist_emailed_count + 1 where unit_number = r.unit_number;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function waitlist_ready_release() from public, anon, authenticated;

-- Mark a unit rent ready (true) or not ready (false). Marking it ready (from not ready) schedules one email per confirmed
-- waitlist person: number 1 now, everyone else after the head start. Marking it not ready stops emails not yet sent.
-- Returns {sent_now, later, later_at}.
create or replace function waitlist_staff_set_ready(p_unit text, p_ready boolean, p_message text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_was boolean; v_unit text; v_total int; v_hours int; v_later_at timestamptz; v_now int; v_later int;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  v_unit := nullif(trim(coalesce(p_unit, '')), '');
  if v_unit is null or not exists (select 1 from rental_units where unit_number = v_unit and managed_by <> 'owner') then
    raise exception 'Choose a unit.';
  end if;
  select ready into v_was from unit_rent_ready where unit_number = v_unit;
  insert into unit_rent_ready (unit_number, ready, changed_at, changed_by)
  values (v_unit, coalesce(p_ready, false), now(), auth.jwt()->>'email')
  on conflict (unit_number) do update set ready = excluded.ready, changed_at = excluded.changed_at, changed_by = excluded.changed_by;

  if not coalesce(p_ready, false) then
    update waitlist_ready_sends set skipped = 'unit marked not ready' where unit_number = v_unit and queued_at is null and skipped is null;
    return jsonb_build_object('sent_now', 0, 'later', 0);
  end if;
  if coalesce(v_was, false) then return jsonb_build_object('sent_now', 0, 'later', 0, 'already', true); end if;

  v_hours := greatest(0, coalesce(nullif(condo_setting('waitlist_head_start_hours', '48'), '')::int, 48));
  v_later_at := now() + make_interval(hours => v_hours);
  select count(*) into v_total from waitlist where status = 'active';
  insert into waitlist_ready_sends (unit_number, waitlist_id, position, total, head_start_hours, note, send_at)
  select v_unit, x.id, x.pos, v_total, v_hours, nullif(left(trim(coalesce(p_message, '')), 1000), ''),
         case when x.pos = 1 then now() else v_later_at end
    from (select w.id, row_number() over (order by w.created_at, w.id)::int as pos from waitlist w where w.status = 'active') x;
  v_now := waitlist_ready_release();
  select count(*) into v_later from waitlist_ready_sends where unit_number = v_unit and queued_at is null and skipped is null;
  return jsonb_build_object('sent_now', v_now, 'later', v_later, 'later_at', v_later_at);
end $$;
revoke all on function waitlist_staff_set_ready(text, boolean, text) from public, anon;
grant execute on function waitlist_staff_set_ready(text, boolean, text) to authenticated;

-- Every 15 minutes: queue the waitlist emails whose head start has passed, then flush the outbox (same pattern as
-- repair-heat-escalate; the cycle secret is copied from the bank-sync job when this runs, never written in git).
do $do$
declare v_secret text;
begin
  select substring(command from $r$'x-cycle-secret', '([^']+)'$r$) into v_secret from cron.job where jobname = 'bank-sync';
  if v_secret is null then raise exception 'Could not find the cycle secret on the bank-sync job'; end if;
  perform cron.unschedule('waitlist-ready-release') where exists (select 1 from cron.job where jobname = 'waitlist-ready-release');
  perform cron.schedule('waitlist-ready-release', '*/15 * * * *', format($c$
    select case when waitlist_ready_release() > 0 then net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/outbox-flush',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', %L), body := '{}'::jsonb) end;
  $c$, v_secret));
end;
$do$;
