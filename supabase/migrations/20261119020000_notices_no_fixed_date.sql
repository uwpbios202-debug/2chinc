-- Notices: no fixed pay-by / move-out date on the paper (Stephen, 11/11/2026).
-- Our notices printed "You must pay $X on or before <date>" and "Served by certified mail on <date>". Both dates were set when the
-- notice was BUILT, not when it was mailed, so a notice mailed days later told the tenant a deadline that was too short (Unit 4:
-- built 11/2, "pay on or before November 6", postmarked 11/6). The wording Milwaukee County has accepted for years (the Unit 2 notice,
-- 12/12/2025) has no date: it "requires you to vacate the premises described in this notice within 5 days from service hereof unless
-- you pay the total unpaid rent of $X". The pay-or-vacate, breach and 14-day notices now say "within N days from service hereof";
-- the "Served by ... on ..." line is gone from all four built notices. The 28-day notice keeps its end date (Wis. Stat. 704.19 requires
-- the notice to name the end of a rental period). Already-sent notices are kept exactly as they were (history is left as-is).
-- The eFile check accepts the new wording (OK: N days from service) and the complaint statement no longer quotes a date.

do $$
declare n int;
begin
  -- Pay or vacate.
  update letter_templates set
    html = regexp_replace(
      replace(replace(html,
        'This notice ends your tenancy unless you pay the rent owed. You must pay <b>[[Amount_Required]]</b> on or before <b>[[Deadline]]</b>, or move out of the premises by that date. If you do neither, the landlord may file an eviction action against you.',
        'This notice terminates your tenancy pursuant to [[Notice_Statute]], and requires you to vacate the premises described in this notice within [[Notice_Days]] days from service hereof unless you pay the total unpaid rent of <b>[[Amount_Required]]</b>. If you do neither, the landlord may file an eviction action against you.'),
        'If you pay less than [[Amount_Required]] by the deadline, this notice is not cancelled unless the landlord agrees in writing.',
        'If you pay less than the [[Amount_Required]] required by this notice, you are still in default and this notice is not cancelled unless the landlord agrees in writing.'),
      '<p>Served by [^<]*</p>\s*', '', 'g'),
    email_html = replace(replace(email_html,
        'The paper notice is being sent by [[Service_Method]] on [[Mail_Date]]; that is the official copy.',
        'The paper notice is being sent by [[Service_Method]]; that is the official copy.'),
        'To keep your home, pay <b>[[Amount_Required]]</b> on or before <b>[[Deadline]]</b>.',
        'To keep your home, pay <b>[[Amount_Required]]</b> within [[Notice_Days]] days after the paper notice is served.')
  where template_key = '2c-pay-or-vacate';
  select count(*) into n from letter_templates where template_key = '2c-pay-or-vacate'
    and html like '%within [[Notice_Days]] days from service hereof%' and html not like '%[[Deadline]]%' and html not like '%Served by%'
    and email_html not like '%[[Deadline]]%' and email_html not like '%[[Mail_Date]]%';
  if n <> 1 then raise exception 'pay-or-vacate template did not update as expected'; end if;

  -- 14-day notice to vacate.
  update letter_templates set
    html = regexp_replace(replace(html,
        '<p><b>Your tenancy is terminated. You must move out of the premises on or before [[Deadline]].</b>',
        '<p><b>This notice terminates your tenancy and requires you to vacate the premises described in this notice within 14 days from service hereof.</b>'),
      '<p>Served by [^<]*</p>\s*', '', 'g'),
    email_html = replace(replace(email_html,
        'you must move out on or before <b>[[Deadline]]</b>.',
        'you must move out within <b>14 days</b> after the paper notice is served.'),
        'The paper notice is being sent by [[Service_Method]] on [[Mail_Date]]; that is the official copy.',
        'The paper notice is being sent by [[Service_Method]]; that is the official copy.')
  where template_key = '2c-14-day';
  select count(*) into n from letter_templates where template_key = '2c-14-day'
    and html like '%within 14 days from service hereof%' and html not like '%[[Deadline]]%' and html not like '%Served by%'
    and email_html not like '%[[Deadline]]%' and email_html not like '%[[Mail_Date]]%';
  if n <> 1 then raise exception '14-day template did not update as expected'; end if;

  -- Notice to remedy breach or vacate.
  update letter_templates set
    html = regexp_replace(replace(replace(html,
        'You must <b>remedy this breach or move out of the premises on or before [[Deadline]]</b>.',
        'You must <b>remedy this breach or vacate the premises described in this notice within [[Notice_Days]] days from service hereof</b>.'),
        'If you remedy the breach by that date, your tenancy continues.',
        'If you remedy the breach within that time, your tenancy continues.'),
      '<p>Served by [^<]*</p>\s*', '', 'g'),
    email_html = replace(replace(email_html,
        'To keep your home, remedy it on or before <b>[[Deadline]]</b>:',
        'To keep your home, remedy it within <b>[[Notice_Days]] days</b> after the paper notice is served:'),
        'The paper notice is being sent by [[Service_Method]] on [[Mail_Date]]; that is the official copy.',
        'The paper notice is being sent by [[Service_Method]]; that is the official copy.')
  where template_key = '2c-breach-cure';
  select count(*) into n from letter_templates where template_key = '2c-breach-cure'
    and html like '%within [[Notice_Days]] days from service hereof%' and html not like '%[[Deadline]]%' and html not like '%Served by%'
    and email_html not like '%[[Deadline]]%' and email_html not like '%[[Mail_Date]]%';
  if n <> 1 then raise exception 'breach template did not update as expected'; end if;

  -- 28-day: keeps its end date; only the "Served by ... on <date>" line goes.
  update letter_templates set
    html = regexp_replace(html, '<p>Served by [^<]*</p>\s*', '', 'g'),
    email_html = replace(email_html, 'The paper notice is being sent by [[Service_Method]] on [[Mail_Date]]; that is the official copy.',
        'The paper notice is being sent by [[Service_Method]]; that is the official copy.')
  where template_key = '2c-28-day';
  select count(*) into n from letter_templates where template_key = '2c-28-day' and html not like '%Served by%' and email_html not like '%[[Mail_Date]]%';
  if n <> 1 then raise exception '28-day template did not update as expected'; end if;
end;
$$;

-- eFile check: accept "within N days from service" (no fixed date) and stop quoting a date in the complaint statement.
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
  if m is null then m := regexp_match(txt, 'unless you pay the total unpaid rent of \$([0-9,]+\.[0-9]{2})', 'i'); end if;
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
    if v_payby is null and txt ~* ('within ' || v_days || ' days from service') then
      checks := checks || jsonb_build_object('level', 'ok', 'title', 'Notice gives ' || v_days || ' days from service', 'detail', 'No fixed pay-by date: the wording Milwaukee County has accepted for years. With the stamp date ' || to_char(n.served_on, 'FMMonth FMDD') || ' as day 1, the ' || v_days || ' days end ' || to_char(v_min, 'FMDay, FMMonth FMDD, YYYY') || '.');
    elsif v_payby is null then
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
      || ', requiring payment of $' || coalesce(to_char(v_amount, 'FM999,990.00'), '?') || ' within ' || coalesce(v_days::text, '?') || ' days from service'
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
