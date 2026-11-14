-- eFile pre-flight for evictions (Stephen, 11/11/2026): "build the system so we do not make any tiny error".
-- Built from what went wrong on the 1/2026 Unit 2 filing (case 2026SC000640) and its rejected first attempt:
--   * rejected 1/2/2026: English-only SC-500 (Milwaukee needs the English/Spanish form), two class codes, page 1 box did not match page 2;
--   * four $133 filing payments (1/2 twice, 1/6, 1/8) for one case; the refund check went to a former member whose eFile account filed it;
--   * the "small claims eviction complaint" attached to the case was the BLANK form (the filled one was a fillable PDF that was not flattened),
--     and the filled one did not add up ($850 rent + $0 damages = "$1,050");
--   * the notice's premises line had no unit number; the complaint's "served on" date did not match the notice's date;
--   * a motion to seal was filed saying the case was dismissed before the dismissal was entered (denied 2/3/2026);
--   * the declaration of service was filed on the court date itself.
-- And from the Unit 4 notice served 11/6/2026: the notice was built 11/2 with "pay on or before November 6" and "served on November 2",
-- but it was postmarked 11/6. Wis. Stat. 704.17(1p)(a) requires a pay-by date at least 5 days after the notice is given, so the paper
-- the tenant holds gives her no time even though the site's "cure by" moved to 11/10. Nothing checked the paper against the stamp date.
--
-- efile_preflight(notice) reads the notice PAPER (its html) and the live ledger and returns STOP / CHECK / OK lines plus the exact
-- words and numbers to type into https://efiling.wicourts.gov/. The /staff/efile/ page shows them with a checklist that must be ticked
-- before the case is submitted; the submission (with the payment confirmation) is recorded so nobody pays twice; a rejection is recorded
-- with its reason and the checklist starts over. The daily office eFile email now says "do NOT eFile yet" when a STOP is found.
-- Rent only: late fees are never part of a notice, a demand or a filing (CLAUDE.md). Day 1 = certified-mail stamp date (Stephen's rule).
-- No new tables (columns + functions only), so no new grants are needed.

alter table public.notices add column if not exists efile_checklist jsonb not null default '{}'::jsonb;
alter table public.notices add column if not exists efile_checked_by text;
alter table public.notices add column if not exists efile_checked_at timestamptz;
alter table public.notices add column if not exists efile_submitted_at timestamptz;
alter table public.notices add column if not exists efile_submitted_by text;
alter table public.notices add column if not exists efile_payment_conf text;
alter table public.notices add column if not exists efile_rejections jsonb not null default '[]'::jsonb;

-- The checklist items that must all be ticked before "Submitted" can be recorded (the page shows the wording).
create or replace function efile_checklist_keys()
returns text[] language sql immutable as $$
  select array['account', 'no_duplicate', 'county_class', 'bilingual', 'boxes_match', 'names', 'amounts', 'flattened', 'attachments', 'signer']::text[]
$$;
revoke all on function efile_checklist_keys() from public, anon;
grant execute on function efile_checklist_keys() to authenticated, service_role;

create or replace function notice_plain_text(p_html text)
returns text language sql immutable as $$
  select trim(regexp_replace(regexp_replace(replace(replace(coalesce(p_html, ''), '&nbsp;', ' '), '&amp;', '&'), '<[^>]+>', ' ', 'g'), '\s+', ' ', 'g'))
$$;
revoke all on function notice_plain_text(text) from public, anon;
grant execute on function notice_plain_text(text) to service_role;

create or replace function notice_parse_date(p text)
returns date language plpgsql immutable as $$
begin
  if p is null then return null; end if;
  return to_date(trim(p), 'FMMonth FMDD, YYYY');
exception when others then return null;
end;
$$;
revoke all on function notice_parse_date(text) from public, anon;
grant execute on function notice_parse_date(text) to service_role;

-- The whole check. Service role only; staff call efile_preflight().
create or replace function efile_core(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  n notices; l leases; ru rental_units;
  mon constant text := '((?:January|February|March|April|May|June|July|August|September|October|November|December) [0-9]{1,2}, [0-9]{4})';
  txt text; m text[]; v_days int; v_min date; v_payby date; v_served_txt date; v_served_how text; v_amount numeric;
  v_today date := (now() at time zone 'America/Chicago')::date;
  v_due numeric; v_due_at_notice numeric; v_paid_since numeric; v_nonpay boolean; v_owner text; v_premises text;
  v_defs jsonb; v_def_names text; v_kind text; v_basis text; v_rules jsonb;
  checks jsonb := '[]'::jsonb; v_stops int; v_list_done boolean; v_statement text; v_method_words text;
begin
  select * into n from notices where id = p_id;
  if n.id is null then return jsonb_build_object('ok', false, 'error', 'Notice not found'); end if;
  if n.lease_id is null then return jsonb_build_object('ok', false, 'error', 'This is not a lease notice (land contract notices are filed differently).'); end if;
  select * into l from leases where id = n.lease_id;
  select * into ru from rental_units where id = l.unit_id;
  txt := notice_plain_text(n.html);
  v_nonpay := n.template_name ~* 'pay rent or vacate';
  v_days := notice_days(p_id);
  v_rules := lease_notice_rules(n.lease_id);
  v_kind := v_rules->>'lease_kind';
  v_basis := v_rules->>'nonpayment_basis';

  -- What the paper says.
  m := regexp_match(txt, 'on or before (?:[A-Za-z]+day, )?' || mon, 'i');           v_payby := notice_parse_date(m[1]);
  m := regexp_match(txt, 'Served by ([A-Za-z ]+?) on ' || mon, 'i');                 v_served_how := m[1]; v_served_txt := notice_parse_date(m[2]);
  m := regexp_match(txt, 'Total unpaid rent required: \$([0-9,]+\.[0-9]{2})', 'i');
  if m is null then m := regexp_match(txt, 'You must pay \$([0-9,]+\.[0-9]{2})', 'i'); end if;
  v_amount := nullif(replace(coalesce(m[1], ''), ',', ''), '')::numeric;
  m := regexp_match(txt, 'Premises: (.+?, WI [0-9]{5})', 'i');                       v_premises := m[1];
  if v_premises is null then v_premises := coalesce(ru.address, l.rental_label); end if;

  -- Who: every tenant on the lease is a defendant; the current unit owner is the plaintiff.
  select jsonb_agg(jsonb_build_object('name', trim(t.name)) order by t.name), string_agg(trim(t.name), ' and ' order by t.name)
    into v_defs, v_def_names
    from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = n.lease_id;
  select o.name into v_owner from condo_ownerships co join condo_owners o on o.id = co.owner_id
   where co.unit_id = ru.condo_unit_id and (co.end_date is null or co.end_date >= v_today) order by co.start_date desc limit 1;

  -- Money (rent only).
  v_due := lease_rent_due(n.lease_id, v_today);
  if n.served_on is not null then
    v_due_at_notice := lease_rent_due(n.lease_id, n.served_on);
    select coalesce(-sum(e.amount), 0) into v_paid_since from lease_ledger_entries e
     where e.lease_id = n.lease_id and e.kind in ('payment', 'assistance', 'in_kind') and e.amount < 0 and e.entry_date >= n.served_on;
  end if;

  -- ---- The checks. level: stop (do not file), check (a person must look and decide), ok.
  if n.status <> 'sent' or coalesce(n.voided, false) then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'This notice is not a live, sent notice', 'detail', 'It is voided or was never sent. File only on a served notice that is still in force.');
  end if;
  if v_days is null then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'Not an eviction notice', 'detail', 'Only pay-or-vacate and termination notices lead to an eviction filing.');
  end if;
  if n.pdf_path is null then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'No PDF of the notice on file', 'detail', 'The court needs the exact notice that was served.');
  end if;
  if l.federal_program is not null and coalesce(v_days, 0) < 30 then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'Federally covered tenancy: a 30-day notice is required', 'detail', 'This lease is marked ' || l.federal_program || '. A ' || coalesce(v_days, 0) || '-day notice cannot support the filing.');
  end if;

  -- Service.
  if n.served_on is null or n.service_method is null then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'Service is not recorded', 'detail', 'Record how and when the notice was served (certified-mail stamp date) on the Notices page.');
  elsif n.service_method = 'email_only' then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'Email is not legal service', 'detail', 'Serve the notice by certified mail or personal delivery (Wis. Stat. 704.21), then file.');
  elsif n.service_method = 'mail' then
    checks := checks || jsonb_build_object('level', 'check', 'title', 'Served by ordinary mail', 'detail', 'Wis. Stat. 704.21 lists registered or certified mail. Be sure you can prove the mailing before filing.');
  else
    checks := checks || jsonb_build_object('level', 'ok', 'title', 'Service recorded', 'detail', initcap(replace(n.service_method, '_', ' ')) || ', day 1 = ' || to_char(n.served_on, 'FMMonth FMDD, YYYY') || coalesce(' (' || n.service_note || ')', '') || '.');
  end if;
  if n.served_on is not null and n.service_method = 'certified_mail' and n.proof_path is null then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'No stamped certified-mail receipt on file', 'detail', 'Add the green receipt with the post-office stamp on the Notices page. It goes into the court packet.');
  elsif n.proof_path is not null then
    checks := checks || jsonb_build_object('level', 'ok', 'title', 'Stamped receipt on file', 'detail', 'It is page 2 of the court packet.');
  end if;

  -- The paper's own dates against the stamp date. This is the check that would have caught Unit 4.
  if n.served_on is not null and v_days is not null then
    v_min := n.served_on + v_days - 1;
    if v_payby is null then
      checks := checks || jsonb_build_object('level', 'check', 'title', 'Could not read the pay-by date on the notice', 'detail', 'Open the notice PDF. Its pay/vacate date must be on or after ' || to_char(v_min, 'FMDay, FMMonth FMDD, YYYY') || ' (stamp date ' || to_char(n.served_on, 'FMMonth FMDD') || ' = day 1, ' || v_days || ' days).');
    elsif v_payby < v_min then
      checks := checks || jsonb_build_object('level', 'stop', 'title', 'The notice gives fewer than ' || v_days || ' days',
        'detail', 'The notice tells the tenant to pay or move by ' || to_char(v_payby, 'FMDay, FMMonth FMDD, YYYY') || ', but it was stamped ' || to_char(n.served_on, 'FMMonth FMDD, YYYY')
          || '. Counting the stamp date as day 1, the date had to be ' || to_char(v_min, 'FMMonth FMDD') || ' or later (Wis. Stat. 704.17: "at least ' || v_days || ' days after the giving of the notice"). '
          || 'A court will very likely dismiss on this notice. Do not file it: send a new notice (build it with the real mailing date and mail it that same day), record its stamp date, and file after its cure period.');
    else
      checks := checks || jsonb_build_object('level', 'ok', 'title', 'Pay-by date on the notice is long enough', 'detail', 'The notice says ' || to_char(v_payby, 'FMMonth FMDD, YYYY') || '; the earliest lawful date was ' || to_char(v_min, 'FMMonth FMDD, YYYY') || '.');
    end if;
    if v_served_txt is not null and v_served_txt <> n.served_on then
      checks := checks || jsonb_build_object('level', case when v_payby is not null and v_payby < v_min then 'stop' else 'check' end,
        'title', 'The notice states a different service date',
        'detail', 'The paper says "served ' || coalesce(lower(v_served_how), '') || ' on ' || to_char(v_served_txt, 'FMMonth FMDD, YYYY') || '", but the stamp date is ' || to_char(n.served_on, 'FMMonth FMDD, YYYY')
          || '. The complaint must give the real service date, and the commissioner will see both.');
    end if;
  end if;

  -- Timing.
  if n.efile_on is null then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'No eFile date worked out', 'detail', 'Record the service on the Notices page; the site then works out the cure date and the first day you may file.');
  elsif v_today < n.efile_on then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'Too early to file', 'detail', 'The cure period ends ' || to_char(n.cure_deadline, 'FMDay, FMMonth FMDD') || '. The first day to file is ' || to_char(n.efile_on, 'FMDay, FMMonth FMDD, YYYY') || '. A case filed early is dismissed.');
  else
    checks := checks || jsonb_build_object('level', 'ok', 'title', 'Cure period is over', 'detail', 'Cure by ' || to_char(n.cure_deadline, 'FMMonth FMDD') || '; filing allowed from ' || to_char(n.efile_on, 'FMMonth FMDD, YYYY') || '.');
  end if;

  -- Rent.
  if v_nonpay then
    if v_amount is null then
      checks := checks || jsonb_build_object('level', 'check', 'title', 'Could not read the amount on the notice', 'detail', 'Open the notice PDF and confirm it asks for rent only.');
    elsif v_due_at_notice is not null and v_amount > v_due_at_notice + 0.005 then
      checks := checks || jsonb_build_object('level', 'stop', 'title', 'The notice asks for more than the rent owed', 'detail', 'Notice: $' || to_char(v_amount, 'FM999,990.00') || '. Unpaid rent on the stamp date: $' || to_char(v_due_at_notice, 'FM999,990.00') || '. A pay-or-vacate notice may ask for unpaid rent only.');
    else
      checks := checks || jsonb_build_object('level', 'ok', 'title', 'Notice asks for rent only', 'detail', '$' || to_char(v_amount, 'FM999,990.00') || ' (no late fees).');
    end if;
    if v_due <= 0 then
      checks := checks || jsonb_build_object('level', 'stop', 'title', 'The rent is paid', 'detail', 'Unpaid rent today is $0.00. Do not file.');
    end if;
    if coalesce(v_paid_since, 0) > 0 then
      checks := checks || jsonb_build_object('level', 'check', 'title', 'Money came in after the notice', 'detail', '$' || to_char(v_paid_since, 'FM999,990.00') || ' was credited on or after the stamp date. Accepting rent after a notice can be argued as giving up the notice; decide before filing, and say so in the complaint if asked.');
    end if;
  end if;

  -- People.
  if v_defs is null then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'No tenant on the lease', 'detail', 'There is nobody to name as defendant.');
  elsif exists (select 1 from jsonb_array_elements(v_defs) d where array_length(regexp_split_to_array(d->>'name', '\s+'), 1) < 3) then
    checks := checks || jsonb_build_object('level', 'check', 'title', 'Confirm each defendant''s full legal name', 'detail', 'On file: ' || v_def_names || '. Type the full legal name (first, middle, last) exactly as on the lease or ID, and name every adult who signed the lease.');
  end if;
  if v_owner is null then
    checks := checks || jsonb_build_object('level', 'check', 'title', 'Unit owner not found', 'detail', 'The plaintiff must be the landlord (the owner). Confirm who owns this unit before filing.');
  elsif v_owner !~* '^2nd chance housing' then
    checks := checks || jsonb_build_object('level', 'check', 'title', 'This unit is not owned by 2nd Chance Housing Inc', 'detail', 'Owner on file: ' || v_owner || '. The owner is the plaintiff; 2nd Chance as manager does not file in its own name for someone else''s unit. Decide who signs before filing.');
  end if;
  if l.status <> 'active' then
    checks := checks || jsonb_build_object('level', 'check', 'title', 'The lease is not active', 'detail', 'Status: ' || l.status || '. Confirm the tenant is still in the unit; an eviction is for someone in possession.');
  end if;

  -- Already filed / already paid.
  if n.case_number is not null then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'Already filed', 'detail', 'Case ' || n.case_number || ' is recorded for this notice. Never file a second case on the same notice.');
  elsif n.efile_submitted_at is not null then
    checks := checks || jsonb_build_object('level', 'stop', 'title', 'Already submitted to the court', 'detail', 'Submitted ' || to_char(n.efile_submitted_at at time zone 'America/Chicago', 'FMMonth FMDD "at" FMHH12:MI AM')
      || coalesce(' by ' || n.efile_submitted_by, '') || coalesce(', payment confirmation ' || n.efile_payment_conf, '')
      || '. Wait for the court''s "accepted" or "rejected" email. If it was rejected, press "It was rejected" below and enter the reason. Do not submit or pay again.');
  end if;
  if jsonb_array_length(n.efile_rejections) > 0 then
    checks := checks || jsonb_build_object('level', 'check', 'title', 'Rejected before: fix every reason', 'detail',
      (select string_agg(to_char((r->>'at')::timestamptz at time zone 'America/Chicago', 'FMMM/FMDD') || ': ' || (r->>'reason'), ' | ') from jsonb_array_elements(n.efile_rejections) r));
  end if;

  -- What to type: the complaint's "Brief statement of dates and facts", built from the paper and the ledger.
  v_method_words := case n.service_method when 'certified_mail' then 'by certified mail' when 'personal' then 'by personal delivery' when 'posted' then 'by posting on the premises and mailing' when 'mail' then 'by mail' else 'by ' || coalesce(n.service_method, '?') end;
  if v_nonpay then
    v_statement := 'Defendant' || case when jsonb_array_length(coalesce(v_defs, '[]')) > 1 then 's rent' else ' rents' end || ' the premises at ' || coalesce(v_premises, '?')
      || ' from Plaintiff on a ' || replace(coalesce(v_kind, 'rental'), '_', '-') || ' tenancy. Monthly rent is $' || to_char(l.rent, 'FM999,990.00') || '. '
      || 'Defendant failed to pay rent when due. On ' || coalesce(to_char(n.served_on, 'FMMonth FMDD, YYYY'), '?') || ' Plaintiff served Defendant ' || v_method_words
      || ' with a ' || coalesce(v_days::text, '?') || '-day notice to pay rent or vacate under Wis. Stat. ' || coalesce(substring(v_basis from '§ ?([0-9.]+(?:[(][0-9a-z]+[)])*)'), '704.17')
      || ', requiring payment of $' || coalesce(to_char(v_amount, 'FM999,990.00'), '?') || ' on or before ' || coalesce(to_char(v_payby, 'FMMonth FMDD, YYYY'), '?')
      || '. Defendant did not pay the rent or vacate and remains in possession. Plaintiff seeks restitution of the premises and judgment for unpaid rent of $'
      || to_char(greatest(v_due, 0), 'FM999,990.00') || ' plus costs. Copies of the notice, the certified mail receipt and the rent ledger are attached.';
  end if;

  select count(*) into v_stops from jsonb_array_elements(checks) c where c->>'level' = 'stop';
  v_list_done := (select bool_and(coalesce((n.efile_checklist->>k)::boolean, false)) from unnest(efile_checklist_keys()) k);

  return jsonb_build_object('ok', true, 'id', n.id, 'template_name', n.template_name, 'nonpay', v_nonpay,
    'stops', v_stops, 'checks', checks, 'checklist', n.efile_checklist, 'checklist_done', coalesce(v_list_done, false),
    'checked_by', n.efile_checked_by, 'checked_at', n.efile_checked_at,
    'submitted_at', n.efile_submitted_at, 'submitted_by', n.efile_submitted_by, 'payment_conf', n.efile_payment_conf, 'rejections', n.efile_rejections,
    'case_number', n.case_number, 'case_filed_on', n.case_filed_on, 'court_at', n.court_at, 'court_place', n.court_place,
    'served_on', n.served_on, 'service_method', n.service_method, 'cure_deadline', n.cure_deadline, 'efile_on', n.efile_on, 'days', v_days,
    'paper', jsonb_build_object('pay_by', v_payby, 'served_text', v_served_txt, 'amount', v_amount, 'premises', v_premises),
    'type', jsonb_build_object(
      'county', 'Milwaukee',
      'class_code', '31004',
      'class_label', 'Small Claims - Eviction (31004)',
      'plaintiff', coalesce(case when v_owner ~* '^2nd chance housing' then '2nd Chance Housing Inc.' else v_owner end, '2nd Chance Housing Inc.'),
      'plaintiff_address', '6626 North Bourbon Street, Milwaukee, WI 53224',
      'defendants', coalesce(v_defs, '[]'::jsonb), 'defendant_address', v_premises,
      'monthly_rent', l.rent, 'rent_due', greatest(v_due, 0), 'rent_due_at_notice', v_due_at_notice, 'paid_since_notice', coalesce(v_paid_since, 0),
      'statement', v_statement, 'signer', 'Albert Harris', 'phone', '(262) 236-5443'),
    'ready', v_stops = 0 and coalesce(v_list_done, false) and n.efile_submitted_at is null and n.case_number is null);
end;
$$;
revoke all on function efile_core(uuid) from public, anon, authenticated;
grant execute on function efile_core(uuid) to service_role;

create or replace function efile_preflight(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return efile_core(p_id);
end;
$$;
revoke all on function efile_preflight(uuid) from public, anon;
grant execute on function efile_preflight(uuid) to authenticated;

-- Served eviction notices, newest first, with their STOP count (the /staff/efile/ list).
create or replace function efile_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'template_name', n.template_name, 'label', coalesce(u.address, l.rental_label) || ' — ' || l.tenants_label,
      'served_on', n.served_on, 'cure_deadline', n.cure_deadline, 'efile_on', n.efile_on, 'case_number', n.case_number, 'court_at', n.court_at,
      'submitted_at', n.efile_submitted_at, 'stops', (efile_core(n.id)->>'stops')::int) order by n.sent_at desc)
    from notices n join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id
   where n.status = 'sent' and not coalesce(n.voided, false) and notice_days(n.id) is not null
     and (n.case_number is null or n.court_at is null or n.court_at > now() - interval '60 days')
     and n.sent_at > now() - interval '180 days'), '[]'::jsonb);
end;
$$;
revoke all on function efile_list() from public, anon;
grant execute on function efile_list() to authenticated;

create or replace function efile_staff_name()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(trim(s.name), '') from condo_staff s where lower(s.email) = lower(auth.jwt()->>'email') limit 1), auth.jwt()->>'email', 'staff')
$$;
revoke all on function efile_staff_name() from public, anon, authenticated;
grant execute on function efile_staff_name() to service_role;

-- Save the ticks (only known keys are kept).
create or replace function efile_checklist_save(p_id uuid, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select coalesce(jsonb_object_agg(k, true), '{}'::jsonb) into v from unnest(efile_checklist_keys()) k where coalesce((p_items->>k)::boolean, false);
  update notices set efile_checklist = v, efile_checked_by = efile_staff_name(), efile_checked_at = now() where id = p_id and lease_id is not null;
  if not found then raise exception 'Notice not found'; end if;
  return efile_core(p_id);
end;
$$;
revoke all on function efile_checklist_save(uuid, jsonb) from public, anon;
grant execute on function efile_checklist_save(uuid, jsonb) to authenticated;

-- Record that the case was submitted and paid. Refused while any STOP or unticked item remains, or if it was already submitted.
create or replace function efile_record_submitted(p_id uuid, p_conf text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  perform 1 from notices where id = p_id for update;
  v := efile_core(p_id);
  if not coalesce((v->>'ok')::boolean, false) then raise exception '%', v->>'error'; end if;
  if (v->>'submitted_at') is not null or (v->>'case_number') is not null then raise exception 'Already submitted for this notice. Do not submit or pay again.'; end if;
  if (v->>'stops')::int > 0 then raise exception 'There are % STOP item(s). Fix them first.', v->>'stops'; end if;
  if not (v->>'checklist_done')::boolean then raise exception 'Tick every item of the checklist first.'; end if;
  if nullif(trim(coalesce(p_conf, '')), '') is null then raise exception 'Enter the payment confirmation number from the court''s payment email.'; end if;
  update notices set efile_submitted_at = now(), efile_submitted_by = efile_staff_name(), efile_payment_conf = trim(p_conf) where id = p_id;
  return efile_core(p_id);
end;
$$;
revoke all on function efile_record_submitted(uuid, text) from public, anon;
grant execute on function efile_record_submitted(uuid, text) to authenticated;

-- The court rejected it: keep the reason, clear the submission and the ticks so the whole checklist is done again.
create or replace function efile_record_rejected(p_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Paste the reason from the court''s rejection email.'; end if;
  update notices set efile_rejections = efile_rejections || jsonb_build_array(jsonb_build_object('at', now(), 'by', efile_staff_name(), 'reason', left(trim(p_reason), 1500),
           'payment_conf', efile_payment_conf)),
         efile_submitted_at = null, efile_submitted_by = null, efile_payment_conf = null, efile_checklist = '{}'::jsonb, efile_checked_by = null, efile_checked_at = null
   where id = p_id and efile_submitted_at is not null and case_number is null;
  if not found then raise exception 'Only a submitted case without a case number can be marked rejected.'; end if;
  return efile_core(p_id);
end;
$$;
revoke all on function efile_record_rejected(uuid, text) from public, anon;
grant execute on function efile_record_rejected(uuid, text) to authenticated;

-- Daily office email on the eFile date: now runs the pre-flight and says "do NOT eFile yet" when anything is a STOP.
create or replace function notice_efile_reminders()
returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_today date := (now() at time zone 'America/Chicago')::date; v_due numeric; v_subject text; v_body text; v_n int := 0; v_pf jsonb; v_stoplist text;
begin
  for r in
    select n.id, n.lease_id, n.template_name, n.served_on, n.cure_deadline, n.efile_on, ru.unit_number, ru.address, l.tenants_label,
           n.template_name ~* 'pay rent or vacate' as nonpay
      from notices n join leases l on l.id = n.lease_id left join rental_units ru on ru.id = l.unit_id
     where n.status = 'sent' and not coalesce(n.voided, false) and n.efile_reminded_at is null
       and n.efile_on is not null and n.efile_on <= v_today and n.efile_on >= v_today - 3
  loop
    v_due := lease_rent_due(r.lease_id, v_today);
    v_pf := efile_core(r.id);
    select string_agg('<li><b>' || replace(replace(c->>'title', '<', '&lt;'), '>', '&gt;') || '</b>: ' || replace(replace(c->>'detail', '<', '&lt;'), '>', '&gt;') || '</li>', '')
      into v_stoplist from jsonb_array_elements(v_pf->'checks') c where c->>'level' = 'stop';
    if r.nonpay and v_due <= 0 then
      v_subject := 'Unit ' || coalesce(r.unit_number, '?') || ': rent paid, do NOT file the eviction';
      v_body := '<p>The notice''s cure period ended ' || to_char(r.cure_deadline, 'FMMonth FMDD') || ' and the unpaid rent is now $0.00. Do not eFile.</p>';
    elsif v_stoplist is not null then
      v_subject := 'Unit ' || coalesce(r.unit_number, '?') || ': do NOT eFile yet (the pre-filing check found a problem)';
      v_body := '<p><b>' || coalesce(r.tenants_label, '') || '</b>, ' || coalesce(r.address, '') || '.</p><p>The eFile check stopped this filing:</p><ul>' || v_stoplist || '</ul>'
        || '<p>Open the check: <a href="https://2ndchinc.org/staff/efile/?n=' || r.id || '">https://2ndchinc.org/staff/efile/?n=' || r.id || '</a></p>';
    else
      v_subject := 'Unit ' || coalesce(r.unit_number, '?') || ': eviction can be eFiled today'
        || case when r.nonpay and exists (select 1 from lease_ledger_entries e where e.lease_id = r.lease_id and e.kind in ('payment', 'assistance')
                  and e.amount < 0 and e.entry_date >= r.served_on) then ' (partly paid since the notice: you decide)' else '' end;
      v_body := '<p><b>' || coalesce(r.tenants_label, '') || '</b>, ' || coalesce(r.address, '') || '.</p>'
        || '<p>' || r.template_name || ' served ' || to_char(r.served_on, 'FMMonth FMDD, YYYY') || ' (day 1). Cure period ended '
        || to_char(r.cure_deadline, 'FMDay, FMMonth FMDD') || '. Earliest eFile: <b>' || to_char(r.efile_on, 'FMDay, FMMonth FMDD, YYYY') || '</b>.</p>'
        || case when r.nonpay then '<p>Unpaid <b>rent</b> today: <b>$' || to_char(v_due, 'FM999,990.00') || '</b> (rent only: late fees are never part of the filing).</p>' else '' end
        || '<p>Before you file, go through the eFile check (what to type, the checklist, and the court packet): <a href="https://2ndchinc.org/staff/efile/?n=' || r.id || '">https://2ndchinc.org/staff/efile/?n=' || r.id || '</a></p>';
    end if;
    insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', v_subject, v_body, 'notice_efile');
    update notices set efile_reminded_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function notice_efile_reminders() from public, anon, authenticated;
grant execute on function notice_efile_reminders() to service_role;
