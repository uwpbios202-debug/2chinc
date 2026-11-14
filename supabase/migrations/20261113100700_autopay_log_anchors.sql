-- Autopay log: daily fingerprints kept OUTSIDE the database (Stephen, 10/14/2026).
-- The hash chain shows any edit, but someone with full database access could rewrite the log AND recompute the chain. So once a day,
-- when the log has changed, its fingerprint (latest entry and its hash, and a hash of every authorization) is saved and EMAILED to the
-- office. A rewrite after that no longer matches the emails, and the staff log check compares the log with every saved fingerprint.

create table if not exists autopay_anchors (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  last_event_id bigint,
  last_event_hash text,
  events int not null,
  authorizations int not null,
  authorizations_hash text,
  fingerprint text not null
);
alter table autopay_anchors enable row level security;

create or replace function autopay_anchors_guard()
returns trigger language plpgsql as $$
begin raise exception 'Autopay fingerprints cannot be edited or deleted.'; end;
$$;
drop trigger if exists autopay_anchors_guard_t on autopay_anchors;
create trigger autopay_anchors_guard_t before update or delete on autopay_anchors for each row execute function autopay_anchors_guard();

-- Save and email today's fingerprint if the log changed since the last one. Run daily by the rent cycle (autopay_audit).
create or replace function autopay_anchor()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint; v_hash text; v_events int; v_auths int; v_ahash text; v_fp text; k autopay_anchors;
begin
  select e.id, e.row_hash into v_id, v_hash from autopay_events e order by e.id desc limit 1;
  select count(*) into v_events from autopay_events;
  select count(*), autopay_hash(coalesce(string_agg(a.id::text || ':' || a.row_hash, ',' order by a.created_at, a.id), '')) into v_auths, v_ahash from autopay_authorizations a;
  if v_id is null and v_auths = 0 then return jsonb_build_object('skipped', 'nothing logged yet'); end if;
  select * into k from autopay_anchors order by id desc limit 1;
  if k.id is not null and k.last_event_id is not distinct from v_id and k.authorizations_hash = v_ahash then return jsonb_build_object('unchanged', true, 'fingerprint', k.fingerprint); end if;
  v_fp := upper(left(autopay_hash(concat_ws('|', coalesce(v_id::text, ''), coalesce(v_hash, ''), v_events::text, v_auths::text, v_ahash)), 16));
  insert into autopay_anchors (last_event_id, last_event_hash, events, authorizations, authorizations_hash, fingerprint)
  values (v_id, v_hash, v_events, v_auths, v_ahash, v_fp);
  perform office_alert('autopay_alert_email', 'autopay_anchor', '[Autopay] Log fingerprint ' || to_char(autopay_today(), 'FMMon FMDD') || ': ' || v_fp,
    '<p>This is the daily fingerprint of the autopay record (only sent on days it changed). <b>Keep this email; do not delete it.</b></p>'
    || '<ul><li>Fingerprint: <b>' || v_fp || '</b></li><li>Log entries: ' || v_events || ' (latest #' || coalesce(v_id::text, 'none') || ', hash ' || coalesce(left(v_hash, 16), '') || '…)</li>'
    || '<li>Authorizations: ' || v_auths || '</li></ul>'
    || '<p>If the autopay record is ever questioned, these emails prove what it said on this day: a changed record no longer matches them. '
    || 'The Autopay page (https://2ndchinc.org/accounting/autopay/), "Check the log now", also compares the record with every fingerprint.</p>');
  return jsonb_build_object('saved', true, 'fingerprint', v_fp);
end;
$$;
revoke all on function autopay_anchor() from public, anon, authenticated;
grant execute on function autopay_anchor() to service_role;

create or replace function autopay_verify_log()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e record; a autopay_authorizations; v_prev text := null; n int := 0; v_bad bigint; v_bad_a uuid; na int := 0; v_bad_anchor bigint; nk int := 0;
begin
  if not (auth.role() = 'service_role' or (condo_session_ok() and condo_is_staff())) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  for e in select * from autopay_events order by id loop
    n := n + 1;
    if e.prev_hash is distinct from v_prev or e.row_hash <> autopay_hash(concat_ws('|', coalesce(v_prev, ''), e.authorization_id::text, extract(epoch from e.at)::text, e.kind, e.detail::text, e.actor)) then
      v_bad := e.id; exit;
    end if;
    v_prev := e.row_hash;
  end loop;
  for a in select * from autopay_authorizations loop
    na := na + 1;
    if a.row_hash <> autopay_auth_hash(a) then v_bad_a := a.id; exit; end if;
  end loop;
  -- every fingerprint emailed to the office must still match the log (a rewritten log, even with a recomputed chain, no longer does)
  select count(*) into nk from autopay_anchors;
  select k.id into v_bad_anchor from autopay_anchors k
   where (k.last_event_id is not null and not exists (select 1 from autopay_events e2 where e2.id = k.last_event_id and e2.row_hash = k.last_event_hash))
   order by k.id limit 1;
  return jsonb_build_object('ok', v_bad is null and v_bad_a is null and v_bad_anchor is null, 'events_checked', n, 'authorizations_checked', na, 'anchors_checked', nk,
    'first_bad_event', v_bad, 'first_bad_authorization', v_bad_a, 'first_bad_anchor', v_bad_anchor);
end;
$$;
revoke all on function autopay_verify_log() from public, anon;
grant execute on function autopay_verify_log() to authenticated, service_role;

create or replace function autopay_audit(p_as_of date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  select count(*) into n from stripe_payments sp where sp.origin = 'autopay' and sp.created_at > now() - interval '3 days'
     and not exists (select 1 from autopay_events e where e.kind = 'debit_started' and e.detail ->> 'stripe_payment_id' = sp.id::text);
  if n > 0 then
    perform office_alert('autopay_alert_email', 'autopay', 'Autopay withdrawal with no authorization record', '<p>' || n || ' autopay withdrawal(s) in the last 3 days have no matching entry in the autopay log. Open Autopay in the staff menu and check the log.</p>');
  end if;
  return jsonb_build_object('unlogged', n, 'log', autopay_verify_log(), 'anchor', autopay_anchor());
end;
$$;
revoke all on function autopay_audit(date) from public, anon, authenticated;
grant execute on function autopay_audit(date) to service_role;
