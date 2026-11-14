-- Owner portal fixes, batch B (Stephen, 10/13/2026): communication.
--   1. The five "Email me when..." choices are real: dues posted, late fee or interest, payment received, past due, new document.
--      (A balance more than 60 days old is always emailed about: it is the notice that matters most.)
--   2. The office's reply or status change on an owner request emails the owner; an owner's note on a request alerts the office;
--      owners can add notes until the request is closed.
--   3. Owner emails to the office and to a tenant are kept on the owner's Communications history (staff profile).
-- Only new rows are affected: nothing already in the ledger is touched or emailed.

-- ---------------------------------------------------------------------------
-- 1. Preferences helper and the emails.
create or replace function condo_owner_wants(p_owner uuid, p_key text)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (prefs ->> p_key)::boolean from condo_alert_prefs where owner_id = p_owner),
                  (condo_alert_defaults() ->> p_key)::boolean, true);
$$;
revoke all on function condo_owner_wants(uuid, text) from public, anon, authenticated;

-- Payment received receipt: respects the owner's choice.
do $do$
declare v text := pg_get_functiondef('payment_receipt_trigger()'::regprocedure);
  v_old text := $o$if o.email is not null then$o$;
  v_new text := $n$if o.email is not null and condo_owner_wants(o.id, 'email_payment_received') then$n$;
begin
  if position(v_old in v) = 0 then raise exception 'payment_receipt_trigger changed: cannot patch'; end if;
  execute replace(v, v_old, v_new);
end $do$;

-- Past-due email: the owner's choice, except that a balance more than 60 days old is always sent.
create or replace function condo_past_due_email_ok(p_email text, p_as_of date)
returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from condo_owners where lower(email) = lower(p_email))
      or exists (select 1 from condo_owners o where lower(o.email) = lower(p_email) and condo_owner_wants(o.id, 'email_past_due'))
      or exists (select 1 from condo_ownerships s join condo_owners o on o.id = s.owner_id
                 where s.is_current and lower(o.email) = lower(p_email)
                   and (select coalesce(sum(e.amount), 0) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
                         where a.ownership_id = s.id and not a.excluded and e.entry_date <= p_as_of)
                     - (select coalesce(sum(e.amount) filter (where e.amount > 0), 0) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
                         where a.ownership_id = s.id and not a.excluded and e.entry_date <= p_as_of and e.entry_date > p_as_of - 60) > 0.004);
$$;
revoke all on function condo_past_due_email_ok(text, date) from public, anon, authenticated;
grant execute on function condo_past_due_email_ok(text, date) to service_role;

-- Dues posted / late fee or interest charged: emailed when the monthly billing run posts them (origin 'billing' only, so imports,
-- staff entries and history never email anyone).
create or replace function condo_ledger_owner_notify()
returns trigger
language plpgsql security definer set search_path = public as $$
declare o record; v_pref text; v_unit text; v_bal numeric; v_subj text; v_what text;
begin
  if new.origin is distinct from 'billing' or new.amount <= 0 or new.entry_date < current_date - 2 then return new; end if;
  if new.kind = 'charge' and new.gl_account = 'Association Fee Income' then v_pref := 'email_dues_posted';
  elsif new.gl_account in ('Late Fee Income', 'Interest Income') then v_pref := 'email_late_fee';
  else return new; end if;
  select u.unit_number into v_unit from condo_ledger_accounts a join condo_units u on u.id = a.unit_id where a.id = new.account_id;
  for o in select distinct on (lower(ow.email)) ow.id, ow.name, ow.email, s.id as ownership_id
             from condo_ledger_accounts a join condo_ownerships s on s.id = a.ownership_id join condo_owners ow on ow.id = s.owner_id
            where a.id = new.account_id and s.is_current and coalesce(ow.email, '') like '%@%'
  loop
    if not condo_owner_wants(o.id, v_pref) then continue; end if;
    select coalesce(sum(e.amount), 0) into v_bal from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id where a.ownership_id = o.ownership_id and not a.excluded;
    if v_pref = 'email_dues_posted' then
      v_subj := 'Association dues posted, Unit ' || coalesce(v_unit, '');
      v_what := '<p>This month''s association dues of <b>' || to_char(new.amount, 'FM$999,990.00') || '</b> were posted to your account for Unit ' || coalesce(v_unit, '') || '. They are due on the 1st.'
        || ' If anything is still owed on the ' || condo_setting('dues_late_flat_day', '10') || 'th, a late fee is added.</p>';
    else
      v_subj := case when new.gl_account = 'Interest Income' then 'Interest charged' else 'Late fee charged' end || ', Unit ' || coalesce(v_unit, '');
      v_what := '<p>' || case when new.gl_account = 'Interest Income' then 'Interest' else 'A late fee' end || ' of <b>' || to_char(new.amount, 'FM$999,990.00')
        || '</b> was charged to your account for Unit ' || coalesce(v_unit, '') || ': ' || repair_esc(coalesce(new.description, '')) || '.</p>';
    end if;
    insert into email_outbox (to_email, subject, html, kind) values (o.email, v_subj,
      '<p>Hi ' || repair_esc(split_part(o.name, ' ', 1)) || ',</p>' || v_what
      || '<p>Your balance for this unit is <b>' || case when v_bal < 0 then 'a credit of ' || to_char(-v_bal, 'FM$999,990.00') else to_char(v_bal, 'FM$999,990.00') end || '</b>.</p>'
      || '<p>See every charge and payment in your <a href="https://2ndchinc.org/association-owners/roca1/#payments">owner portal</a>. You can turn these emails off under Alerts.</p>'
      || '<p>Royal Orleans Condominium – Addition One<br>managed by 2nd Chance Housing</p>', 'owner_billing');
  end loop;
  return new;
end;
$$;
revoke all on function condo_ledger_owner_notify() from public, anon, authenticated;
drop trigger if exists condo_ledger_owner_notify on condo_ledger_entries;
create trigger condo_ledger_owner_notify after insert on condo_ledger_entries for each row execute function condo_ledger_owner_notify();

-- New document: staff add one for every owner (no unit) or for one unit's owners.
create or replace function condo_staff_add_document(p_unit_number text, p_title text, p_category text, p_path text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_unit text := nullif(trim(p_unit_number), ''); o record;
begin
  if not condo_session_ok() or not condo_is_staff() then raise exception 'Staff only' using errcode = '42501'; end if;
  insert into condo_documents (unit_number, title, category, storage_path, uploaded_by)
  values (v_unit, trim(p_title), coalesce(nullif(trim(p_category), ''), 'General'), p_path, auth.email())
  returning id into v_id;
  for o in select distinct on (lower(ow.email)) ow.id, ow.name, ow.email
             from condo_ownerships s join condo_owners ow on ow.id = s.owner_id join condo_units u on u.id = s.unit_id
            where s.is_current and coalesce(ow.email, '') like '%@%' and (v_unit is null or u.unit_number = v_unit)
  loop
    if not condo_owner_wants(o.id, 'email_new_document') then continue; end if;
    insert into email_outbox (to_email, subject, html, kind) values (o.email, 'New document: ' || left(trim(p_title), 100),
      '<p>Hi ' || repair_esc(split_part(o.name, ' ', 1)) || ',</p><p>A new document was shared with you: <b>' || repair_esc(trim(p_title)) || '</b> (' || repair_esc(coalesce(nullif(trim(p_category), ''), 'General')) || ').</p>'
      || '<p>Open it under <a href="https://2ndchinc.org/association-owners/roca1/#documents">Documents</a> in your owner portal. You can turn these emails off under Alerts.</p>'
      || '<p>Royal Orleans Condominium – Addition One<br>managed by 2nd Chance Housing</p>', 'owner_document');
  end loop;
  return v_id;
end $$;
revoke all on function condo_staff_add_document(text, text, text, text) from public, anon;
grant execute on function condo_staff_add_document(text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Owner requests: the owner hears back; the office hears the owner's notes.
create or replace function owner_request_staff_update(p_id uuid, p_status text, p_priority uuid, p_budget text, p_estimate numeric, p_response text, p_internal_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare old owner_requests; v_to text; v_name text; v_label text; v_reply boolean;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into old from owner_requests where id = p_id;
  if old.id is null then raise exception 'Request not found'; end if;
  if p_status not in ('new', 'reviewing', 'ranked', 'approved', 'scheduled', 'done', 'declined', 'withdrawn') then raise exception 'Unknown status'; end if;
  update owner_requests set status = p_status, priority_id = p_priority, budget_code = nullif(trim(p_budget), ''), estimate = p_estimate,
         response = nullif(trim(p_response), ''), updated_at = now(),
         closed_at = case when p_status in ('done', 'declined', 'withdrawn') then coalesce(closed_at, now()) end
   where id = p_id;
  if p_status is distinct from old.status then
    insert into owner_request_updates (request_id, by_role, by_email, note) values (p_id, 'staff', auth.email(), 'Status: ' || replace(p_status, '_', ' ') || '.');
  end if;
  v_reply := nullif(trim(p_response), '') is distinct from old.response and nullif(trim(p_response), '') is not null;
  if v_reply then
    insert into owner_request_updates (request_id, by_role, by_email, note) values (p_id, 'staff', auth.email(), trim(p_response));
  end if;
  if length(trim(coalesce(p_internal_note, ''))) > 0 then
    insert into owner_request_updates (request_id, by_role, by_email, note, internal) values (p_id, 'staff', auth.email(), trim(p_internal_note), true);
  end if;
  -- Tell the owner (the text of the reply stays in the portal).
  if p_status is distinct from old.status or v_reply then
    select email, name into v_to, v_name from condo_owners where id = old.owner_id;
    v_label := case p_status when 'new' then 'Received' when 'reviewing' then 'Being reviewed' when 'ranked' then 'On the priority list' when 'approved' then 'Approved'
                 when 'scheduled' then 'Scheduled' when 'done' then 'Done' when 'declined' then 'Not approved' else 'Withdrawn' end;
    if coalesce(v_to, '') like '%@%' then
      insert into email_outbox (to_email, subject, html, kind) values (v_to, 'Your owner request #' || old.number || ': ' || v_label,
        '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>Your request <b>#' || old.number || ' ' || repair_esc(left(old.subject, 100)) || '</b> now shows <b>' || v_label || '</b>'
        || case when v_reply then ', and the office wrote you a reply' else '' end || '.</p>'
        || '<p>Read it and add a note in your <a href="https://2ndchinc.org/association-owners/roca1/#requests">owner portal</a>.</p>'
        || '<p>Royal Orleans Condominium – Addition One<br>managed by 2nd Chance Housing</p>', 'owner_request_update');
    end if;
  end if;
end;
$$;
revoke all on function owner_request_staff_update(uuid, text, uuid, text, numeric, text, text) from public, anon;
grant execute on function owner_request_staff_update(uuid, text, uuid, text, numeric, text, text) to authenticated;

create or replace function owner_request_comment(p_id uuid, p_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); r owner_requests;
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_note, ''))) < 2 then raise exception 'Write a note first.'; end if;
  if length(p_note) > 2000 then raise exception 'That note is too long. Keep it under 2,000 characters.'; end if;
  select * into r from owner_requests where id = p_id and owner_id = v_owner;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.status in ('done', 'declined', 'withdrawn') then raise exception 'This request is closed. Send a new request if something is still wrong.'; end if;
  insert into owner_request_updates (request_id, by_role, by_email, note) values (p_id, 'owner', auth.email(), trim(p_note));
  update owner_requests set updated_at = now() where id = p_id;
  perform office_alert('roca_alert_email', 'owner_request', 'Owner note on request #' || r.number || ': ' || left(r.subject, 80),
    '<p>' || repair_esc((select name from condo_owners where id = v_owner)) || ' added a note to request <b>#' || r.number || '</b> (' || r.status || '):</p><p style="white-space:pre-wrap">'
    || repair_esc(left(trim(p_note), 1500)) || '</p><p>Review it at https://2ndchinc.org/association-owners/roca1/requests/</p>');
end;
$$;
revoke all on function owner_request_comment(uuid, text) from public, anon;
grant execute on function owner_request_comment(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Owner emails kept on the owner's history.
create table if not exists owner_mail_log (
  id bigint generated always as identity primary key,
  owner_id uuid not null references condo_owners(id),
  kind text not null check (kind in ('office', 'tenant')),
  unit_number text,
  to_label text,
  subject text,
  body text,
  created_at timestamptz not null default now()
);
create index if not exists owner_mail_log_owner_idx on owner_mail_log (owner_id, created_at desc);
alter table owner_mail_log enable row level security;

create or replace function owner_log_mail(p_kind text, p_unit text, p_to text, p_subject text, p_body text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if p_kind not in ('office', 'tenant') then raise exception 'Bad kind'; end if;
  insert into owner_mail_log (owner_id, kind, unit_number, to_label, subject, body)
  values (v_owner, p_kind, nullif(left(coalesce(p_unit, ''), 20), ''), left(coalesce(p_to, ''), 200), left(coalesce(p_subject, ''), 200), left(coalesce(p_body, ''), 5000));
end;
$$;
revoke all on function owner_log_mail(text, text, text, text, text) from public, anon;
grant execute on function owner_log_mail(text, text, text, text, text) to authenticated;

do $do$
declare v text := pg_get_functiondef('owner_staff_profile(uuid)'::regprocedure);
  v_old text := $o$'alert_prefs', (select prefs from condo_alert_prefs where owner_id = o.id));$o$;
  v_new text := $n$'alert_prefs', (select prefs from condo_alert_prefs where owner_id = o.id),
    'portal_mail', coalesce((select jsonb_agg(jsonb_build_object('at', m.created_at, 'kind', m.kind, 'unit', m.unit_number, 'to', m.to_label, 'subject', m.subject, 'body', m.body) order by m.created_at desc)
        from (select * from owner_mail_log where owner_id = o.id order by created_at desc limit 50) m), '[]'::jsonb));$n$;
begin
  if position(v_old in v) = 0 then raise exception 'owner_staff_profile changed: cannot patch'; end if;
  execute replace(v, v_old, v_new);
end $do$;
