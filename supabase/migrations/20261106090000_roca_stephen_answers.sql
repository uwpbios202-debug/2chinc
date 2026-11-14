-- Stephen's answers (10/7/2026) to the ROCA1 board-business questions:
--  1. Liens: "liens are filed when a unit is 23 months behind and filed every 24 months that they remain behind."
--     This matches Wis. Stat. § 703.165: assessments (with interest and costs of collection, and fines/penalties)
--     are a lien on the unit only "if a statement of lien is filed within 2 years after the date the assessment
--     becomes due". Filing once the oldest unpaid charge is 23 months old, and again every 24 months while the unit is
--     still behind, catches each unpaid month before its 2-year window closes. The balance threshold ($1,290 /
--     $430) and the October/January calendar windows are no longer used. (§ 703.165 also: foreclosure must be
--     brought within 3 years after the statement is recorded, after 10 days' registered-mail notice.)
--  2. Rent deductions: dues first.
--  3. Management fee: none.
--  4. No foreclosure for Unit 12 now (hold list; automation won't propose it).
--  5. Liens, satisfactions and foreclosures are decided by a BOARD vote (majority of all directors).
--  6. "Essential services" on the FY2025 budget = water, gas, light (electric) and lawn care.
--  7. Keep the By-Laws §1500(6) 12% late penalty on special assessments: § 703.165 treats fines, penalties and
--     late charges as liened "assessments" and sets no cap on them (it caps INTEREST at the rate stated in the
--     by-laws); Wisconsin's general rule that a late charge must be a reasonable estimate, not a penalty, still applies.
--  8. Fines stay separated: never billed to a tenant's lease ledger.

-- ---------------------------------------------------------------------------
-- Settings
delete from portal_settings where key = 'roca_lien_threshold';
insert into portal_settings (key, value) values
  ('roca_lien_months_behind', '23'),
  ('roca_lien_refile_months', '24'),
  ('roca_foreclosure_hold_units', '12'),
  ('roca_fines_bill_tenant', 'off')
on conflict (key) do update set value = excluded.value;
update portal_settings set value = 'dues_current,older_balance,assessments,fines_fees' where key = 'roca_deduction_order';
update portal_settings set value = 'on' where key = 'roca_assessment_penalty';
update roca_pma_terms set mgmt_fee_pct = 0, note = concat_ws(' · ', nullif(note, ''), 'No management fee (Stephen, 10/7/2026).');

-- Recorded liens: refile 24 months after recording (was 23).
update roca_liens set refile_due = (recorded_on + interval '24 months')::date, refile_alerted_at = null, updated_at = now()
 where status = 'recorded' and recorded_on is not null;

-- ---------------------------------------------------------------------------
-- Unpaid charges oldest-first: every payment and credit is applied to the oldest charge (FIFO).
create or replace function roca_unit_unpaid_charges(p_unit text, p_as_of date default current_date)
returns table (entry_id bigint, due_date date, gl_account text, description text, unpaid numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_pool numeric; c record; v_take numeric;
begin
  select coalesce(-sum(e.amount), 0) into v_pool
    from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id join condo_units u on u.id = a.unit_id
   where u.unit_number = p_unit and not a.excluded and e.entry_date <= p_as_of and e.amount < 0;
  for c in select e.id, e.entry_date, e.gl_account, e.description, e.amount
             from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id join condo_units u on u.id = a.unit_id
            where u.unit_number = p_unit and not a.excluded and e.entry_date <= p_as_of and e.amount > 0
            order by e.entry_date, e.id loop
    v_take := least(v_pool, c.amount);
    v_pool := v_pool - v_take;
    if c.amount - v_take > 0 then
      entry_id := c.id; due_date := c.entry_date; gl_account := c.gl_account; description := c.description; unpaid := c.amount - v_take;
      return next;
    end if;
  end loop;
end;
$$;
revoke all on function roca_unit_unpaid_charges(text, date) from public, anon, authenticated;

-- What a unit's lien position is today: the newest recorded statement, the unpaid charges it doesn't cover yet,
-- how old the oldest of those is, and any already past the 2-year statutory window.
create or replace function roca_unit_lien_position(p_unit text, p_today date default current_date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l roca_liens; v_cover date; v_oldest date; v_amt numeric; v_lost numeric; v_lost_from date; v_lost_to date;
begin
  select * into l from roca_liens where unit_number = p_unit and status in ('recorded', 'satisfaction_approved', 'foreclosure')
   order by coalesce(recorded_on, date '1900-01-01') desc limit 1;
  v_cover := coalesce(l.as_of, l.recorded_on);
  select min(due_date), coalesce(sum(unpaid), 0) into v_oldest, v_amt
    from roca_unit_unpaid_charges(p_unit, p_today) where v_cover is null or due_date > v_cover;
  select coalesce(sum(unpaid), 0), min(due_date), max(due_date) into v_lost, v_lost_from, v_lost_to
    from roca_unit_unpaid_charges(p_unit, p_today) where (v_cover is null or due_date > v_cover) and due_date < (p_today - interval '2 years')::date;
  return jsonb_build_object('unit', p_unit, 'balance', roca_unit_balance(p_unit, p_today),
    'last_lien', case when l.id is not null then jsonb_build_object('rod_document', l.rod_document, 'recorded_on', l.recorded_on, 'covers_through', v_cover, 'status', l.status) end,
    'uncovered_amount', v_amt, 'oldest_uncovered', v_oldest,
    'months_behind', case when v_oldest is not null then (extract(year from age(p_today, v_oldest)) * 12 + extract(month from age(p_today, v_oldest)))::int end,
    'past_statutory_window', case when v_lost > 0 then jsonb_build_object('amount', v_lost, 'from', v_lost_from, 'to', v_lost_to) end);
end;
$$;
revoke all on function roca_unit_lien_position(text, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Liens automation (replaces the 20261106070000 version).
create or replace function roca_auto_liens(p_today date, p_live boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_behind int := coalesce((select value from portal_settings where key = 'roca_lien_months_behind'), '23')::int;
  v_refile int := coalesce((select value from portal_settings where key = 'roca_lien_refile_months'), '24')::int;
  v_fc numeric := coalesce((select value from portal_settings where key = 'roca_foreclosure_threshold'), '10320')::numeric;
  v_hold text[] := string_to_array(replace(coalesce((select value from portal_settings where key = 'roca_foreclosure_hold_units'), ''), ' ', ''), ',');
  v_file jsonb := '[]'::jsonb; v_sat jsonb := '[]'::jsonb; v_fcl jsonb := '[]'::jsonb; v_lost jsonb := '[]'::jsonb; v_new jsonb := '{}'::jsonb;
  u text; p jsonb; l record; v_reason text; v_last date;
begin
  for u in select * from roca_units() loop
    p := roca_unit_lien_position(u, p_today);
    if jsonb_typeof(p->'past_statutory_window') = 'object' then v_lost := v_lost || jsonb_build_array(p); end if;
    continue when coalesce((p->>'uncovered_amount')::numeric, 0) <= 0 or roca_unit_balance(u, p_today) <= 0;
    -- Units already in foreclosure are handled in court, not by new statements.
    continue when u in (select * from roca_units_pending('lien_filing')) or exists (select 1 from roca_liens where unit_number = u and status in ('approved', 'foreclosure'));
    v_last := (p->'last_lien'->>'recorded_on')::date;
    v_reason := null;
    if v_last is not null and p_today >= (v_last + (v_refile || ' months')::interval)::date then
      v_reason := 'still behind ' || v_refile || ' months after the statement recorded ' || to_char(v_last, 'FMMM/FMDD/YYYY');
    elsif coalesce((p->>'months_behind')::int, 0) >= v_behind then
      v_reason := (p->>'months_behind') || ' months behind (oldest unpaid charge not yet under a lien: ' || to_char((p->>'oldest_uncovered')::date, 'FMMM/FMDD/YYYY') || ')';
    end if;
    if v_reason is not null then
      v_file := v_file || jsonb_build_array(jsonb_build_object('unit', u, 'amount', (p->>'uncovered_amount')::numeric, 'balance', roca_unit_balance(u, p_today),
        'oldest_uncovered', p->>'oldest_uncovered', 'reason', v_reason));
    end if;
  end loop;
  if jsonb_array_length(v_file) > 0 and p_live then
    v_new := v_new || jsonb_build_object('lien_filing', roca_resolution_propose('lien_filing', 'Record Statements of Condominium Lien',
      'RESOLVED, that ROCA1 record a Statement of Condominium Lien with the Register of Deeds against each unit listed, for its unpaid assessments not '
      || 'already under a recorded statement (a unit ' || v_behind || ' months behind, then every ' || v_refile || ' months while it remains behind; '
      || 'Wis. Stat. § 703.165 requires the statement within 2 years after each assessment is due): '
      || (select string_agg('Unit ' || (x->>'unit') || ' ' || roca_money((x->>'amount')::numeric) || ' — ' || (x->>'reason'), '; ') from jsonb_array_elements(v_file) x) || '.',
      'board_majority_all', jsonb_build_object('units', v_file, 'as_of', p_today), 'automation',
      'Rule set by Stephen 10/7/2026: file at ' || v_behind || ' months behind, refile every ' || v_refile || ' months while behind.', 'automation'));
  end if;
  -- Satisfaction: a recorded lien on a unit that now owes nothing.
  for l in select distinct unit_number from roca_liens where status = 'recorded' loop
    if roca_unit_balance(l.unit_number, p_today) <= 0 and l.unit_number not in (select * from roca_units_pending('lien_satisfaction')) then
      v_sat := v_sat || jsonb_build_array(jsonb_build_object('unit', l.unit_number));
    end if;
  end loop;
  if jsonb_array_length(v_sat) > 0 and p_live then
    v_new := v_new || jsonb_build_object('lien_satisfaction', roca_resolution_propose('lien_satisfaction', 'Satisfy paid liens',
      'RESOLVED, that ROCA1 record a Satisfaction of Lien for each unit listed, whose balance is paid in full (Wis. Stat. § 703.165): '
      || (select string_agg('Unit ' || (x->>'unit'), ', ') from jsonb_array_elements(v_sat) x) || '.',
      'board_majority_all', jsonb_build_object('units', v_sat), 'automation', null, 'automation'));
  end if;
  -- Foreclosure: association-fee balance over the action D threshold; skips units on the hold list.
  for u in select * from roca_units() loop
    if roca_unit_fee_balance(u, p_today) > v_fc and not (u = any(v_hold))
       and not exists (select 1 from roca_liens where unit_number = u and status = 'foreclosure')
       and u not in (select * from roca_units_pending('foreclosure')) then
      v_fcl := v_fcl || jsonb_build_array(jsonb_build_object('unit', u, 'amount', roca_unit_balance(u, p_today), 'fee_balance', roca_unit_fee_balance(u, p_today)));
    end if;
  end loop;
  if jsonb_array_length(v_fcl) > 0 and p_live then
    v_new := v_new || jsonb_build_object('foreclosure', roca_resolution_propose('foreclosure', 'Pursue judgment of foreclosure',
      'RESOLVED, that ROCA1 pursue a Judgment of Foreclosure against each unit listed, whose Association Fee balance exceeds ' || roca_money(v_fc)
      || ' (2/19/2025 action D; Wis. Stat. § 703.165: within 3 years after the statement of lien is recorded, after 10 days'' registered-mail notice): '
      || (select string_agg('Unit ' || (x->>'unit') || ' fees ' || roca_money((x->>'fee_balance')::numeric), '; ') from jsonb_array_elements(v_fcl) x) || '.',
      'board_majority_all', jsonb_build_object('units', v_fcl), 'automation', null, 'automation'));
  end if;
  return jsonb_build_object('months_behind_rule', v_behind, 'refile_months', v_refile, 'would_file', v_file,
    'past_statutory_window', v_lost, 'would_satisfy', v_sat, 'foreclosure_threshold', v_fc, 'foreclosure_hold', v_hold,
    'would_foreclose', v_fcl, 'proposed', v_new);
end;
$$;
revoke all on function roca_auto_liens(date, boolean) from public, anon, authenticated;

-- Staff-proposed lien business is a board vote too.
create or replace function roca_lien_propose(p_kind text, p_units text[], p_note text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_units jsonb;
begin
  perform roca_staff_check();
  if p_kind not in ('lien_filing', 'lien_satisfaction', 'foreclosure') then raise exception 'Choose filing, satisfaction or foreclosure.'; end if;
  if coalesce(array_length(p_units, 1), 0) = 0 then raise exception 'Choose at least one unit.'; end if;
  select jsonb_agg(jsonb_build_object('unit', u, 'amount', case when p_kind = 'lien_filing' then (roca_unit_lien_position(u)->>'uncovered_amount')::numeric else roca_unit_balance(u) end,
    'balance', roca_unit_balance(u), 'fee_balance', roca_unit_fee_balance(u))) into v_units from unnest(p_units) u;
  return roca_resolution_propose(p_kind,
    case p_kind when 'lien_filing' then 'Record Statements of Condominium Lien' when 'lien_satisfaction' then 'Satisfy liens' else 'Pursue judgment of foreclosure' end
      || ': Unit ' || array_to_string(p_units, ', '),
    case p_kind when 'lien_filing' then 'RESOLVED, that ROCA1 record a Statement of Condominium Lien against: '
                when 'lien_satisfaction' then 'RESOLVED, that ROCA1 record a Satisfaction of Lien for: '
                else 'RESOLVED, that ROCA1 pursue a Judgment of Foreclosure against: ' end
      || (select string_agg('Unit ' || (x->>'unit') || ' (' || roca_money((x->>'amount')::numeric) || ')', '; ') from jsonb_array_elements(v_units) x) || '.'
      || coalesce(' ' || nullif(trim(coalesce(p_note, '')), ''), ''),
    'board_majority_all', jsonb_build_object('units', v_units, 'as_of', current_date), 'manual', null, lower(auth.email()));
end;
$$;
revoke all on function roca_lien_propose(text, text[], text) from public, anon;
grant execute on function roca_lien_propose(text, text[], text) to authenticated;

-- Liens tab data: add each unit's lien position and the new settings.
create or replace function roca_liens_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return jsonb_build_object(
    'liens', coalesce((select jsonb_agg(roca_lien_json(l) order by (l.status in ('satisfied', 'released')), roca_unit_sort(l.unit_number), l.recorded_on desc nulls last) from roca_liens l), '[]'::jsonb),
    'settings', (select jsonb_object_agg(key, value) from portal_settings where key in ('roca_lien_months_behind', 'roca_lien_refile_months', 'roca_foreclosure_threshold', 'roca_foreclosure_hold_units')),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', u, 'balance', roca_unit_balance(u), 'fee_balance', roca_unit_fee_balance(u), 'has_lien', roca_unit_has_lien(u),
       'position', roca_unit_lien_position(u))) from roca_units() u), '[]'::jsonb));
end;
$$;
revoke all on function roca_liens_staff() from public, anon;
grant execute on function roca_liens_staff() to authenticated;

-- Budget: record what "essential services" means (Stephen 10/7/2026).
update roca_budgets set notes = concat_ws(' · ', nullif(notes, ''), '"Essential services" ($37,103 as printed) = water, gas, light (electric) and lawn care — Stephen, 10/7/2026.')
 where fiscal_year = 2025 and coalesce(notes, '') not like '%Essential services%';

-- Fines stay separated: no tenant billing while roca_fines_bill_tenant is off.
create or replace function roca_violation_no_tenant_billing()
returns trigger language plpgsql as $$
begin
  if new.bill_tenant and coalesce((select value from portal_settings where key = 'roca_fines_bill_tenant'), 'off') <> 'on' then
    raise exception 'Fines stay on the owner''s association account; they are not billed to tenants (Stephen, 10/7/2026).';
  end if;
  return new;
end;
$$;
drop trigger if exists condo_violations_no_tenant_billing on condo_violations;
create trigger condo_violations_no_tenant_billing before insert or update of bill_tenant on condo_violations
  for each row execute function roca_violation_no_tenant_billing();
