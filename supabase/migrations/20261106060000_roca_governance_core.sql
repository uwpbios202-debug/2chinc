-- ROCA1 governance core (Stephen, 10/7/2026): "assessments and liens and violations can be either manually added or
-- added as a result of an automation from a deliberated process and then those are taken out [of the rent]."
--
-- A deliberated process = a RESOLUTION that is voted on and adopted. On adoption the resolution's payload is carried
-- out automatically by roca_exec_<kind>(resolution id) — each module (special assessments, liens, violations, budget,
-- owner distributions) defines its own executor. Automations (lien evaluation, budget shortfall, fines whose appeal
-- window passed) only ever PROPOSE resolutions or act on ones already adopted; people decide.
--
-- Who decides (sources in the ROCA1 governing documents and mine/6622 N bourbon/budget):
--   * board_majority_all   By-Laws 2020 §1500(5): special assessments "upon the majority vote of all the Directors";
--                          budget adoption §1500(1). Directors = current seats in condo_board_terms.
--   * board_hearing        Rules & Regulations 2024 §10 (grievance hearings): majority of the board; the Chairperson
--                          (President) votes only to break a tie; members involved in the dispute recuse themselves.
--   * members_majority     more than 50% of member votes entitled to be cast (By-Laws §1500(3) budget petition).
--   * members_75pct        Declaration ¶12: at least 75% of the votes entitled to be cast.
--   * members_consent      Action by Written Consent of the Class A members in good standing (how the 1/16/2025 and
--                          2/19/2025 actions were adopted): every eligible member consents.
-- Members: one vote per residential unit (Declaration ¶7, 0.06% each). In good standing = zero or credit balance and
-- no recorded lien (Rules 2024 §11: delinquent $0.01 or more may not vote unless a $0.00 balance is recorded).

create table if not exists roca_resolutions (
  id uuid primary key default gen_random_uuid(),
  number text unique,                                   -- e.g. 2026-07; set when voting opens
  kind text not null check (kind in ('budget', 'special_assessment', 'violation_decision', 'fine_waiver', 'lien_filing',
                                     'lien_satisfaction', 'foreclosure', 'rule', 'other')),
  title text not null,
  body text,                                            -- the resolution text ("RESOLVED, that ...")
  threshold text not null check (threshold in ('board_majority_all', 'board_hearing', 'members_majority', 'members_75pct', 'members_consent')),
  status text not null default 'draft' check (status in ('draft', 'voting', 'adopted', 'rejected', 'withdrawn')),
  payload jsonb not null default '{}'::jsonb,           -- what the executor does on adoption (kind-specific)
  origin text not null default 'manual' check (origin in ('manual', 'automation', 'historical')),
  origin_note text,
  voting_closes_on date,
  proposed_by text, proposed_at timestamptz not null default now(),
  voting_opened_at timestamptz,
  decided_at timestamptz, decided_by text, tally jsonb,
  executed_at timestamptz, execution_result jsonb, execution_error text,
  source_document text,                                 -- signed action / minutes on file
  rod_document text,                                    -- Register of Deeds document number, when one is recorded
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists roca_resolutions_status_idx on roca_resolutions (status, proposed_at desc);
create index if not exists roca_resolutions_kind_idx on roca_resolutions (kind, proposed_at desc);

create table if not exists roca_resolution_votes (
  resolution_id uuid not null references roca_resolutions(id) on delete cascade,
  voter_key text not null,                              -- 'seat:President' | 'unit:13'
  voter_name text,
  owner_id uuid references condo_owners(id),
  vote text not null check (vote in ('yes', 'no', 'abstain', 'recused')),
  via text not null check (via in ('portal', 'staff', 'paper', 'email', 'meeting')),
  note text,
  voted_at timestamptz not null default now(),
  recorded_by text,
  primary key (resolution_id, voter_key)
);

create table if not exists roca_automation_runs (
  id bigint generated always as identity primary key,
  run_on date not null,
  mode text not null,                                   -- 'live' | 'off' (dry run: nothing posted or emailed)
  result jsonb,
  error text,
  run_by text,
  created_at timestamptz not null default now()
);

alter table roca_resolutions enable row level security;
alter table roca_resolution_votes enable row level security;
alter table roca_automation_runs enable row level security;
-- No policies: everything goes through the functions below.

insert into portal_settings (key, value) values
  ('roca_alert_email', ''),                               -- staff alerts for board business (blank = office_alert default)
  ('roca_vote_days', '14')                                -- default voting window
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Helpers
create or replace function roca_unit_sort(p_unit text)
returns int language sql immutable as $$ select coalesce(nullif(regexp_replace(coalesce(p_unit, ''), '\D', '', 'g'), '')::int, 9999); $$;

-- Association balance of a unit (all of its non-excluded ledger accounts — Unit 18 has two).
create or replace function roca_unit_balance(p_unit text, p_as_of date default current_date)
returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(condo_account_balance(a.id, p_as_of)), 0)::numeric(12,2)
  from condo_ledger_accounts a join condo_units u on u.id = a.unit_id
  where u.unit_number = p_unit and not a.excluded;
$$;
revoke all on function roca_unit_balance(text, date) from public, anon, authenticated;

-- The account new charges for a unit go on: the billing account, else the current owner's account, else the newest.
create or replace function roca_unit_account(p_unit text)
returns uuid
language sql stable security definer set search_path = public as $$
  select a.id from condo_ledger_accounts a join condo_units u on u.id = a.unit_id
  left join condo_ownerships s on s.id = a.ownership_id
  where u.unit_number = p_unit and not a.excluded
  order by a.billing_account desc, coalesce(s.is_current, false) desc, a.imported_at desc limit 1;
$$;
revoke all on function roca_unit_account(text) from public, anon, authenticated;

-- Has a recorded, unsatisfied lien? (roca_liens comes with the liens module; until then: no.)
create or replace function roca_unit_has_lien(p_unit text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v boolean := false;
begin
  if to_regclass('public.roca_liens') is not null then
    execute 'select exists (select 1 from roca_liens where unit_number = $1 and status = ''recorded'')' into v using p_unit;
  end if;
  return v;
end;
$$;
revoke all on function roca_unit_has_lien(text) from public, anon, authenticated;

-- Everyone entitled to vote on a resolution, with whether they are eligible and why not.
create or replace function roca_voters(p_id uuid)
returns table (voter_key text, voter_name text, owner_id uuid, email text, eligible boolean, reason text)
language plpgsql stable security definer set search_path = public as $$
declare r roca_resolutions;
begin
  select * into r from roca_resolutions where id = p_id;
  if r.threshold in ('board_majority_all', 'board_hearing') then
    return query
      select 'seat:' || b.position, o.name, o.id, o.email, true, null::text
      from condo_board_terms b join condo_owners o on o.id = b.owner_id
      where (b.start_date is null or b.start_date <= current_date) and (b.end_date is null or b.end_date >= current_date)
      order by case b.position when 'President' then 1 when 'Treasurer' then 2 when 'Secretary' then 3 else 4 end;
  else
    return query
      select 'unit:' || u.unit_number, o.name, o.id, o.email,
             roca_unit_balance(u.unit_number) <= 0 and not roca_unit_has_lien(u.unit_number),
             case when roca_unit_has_lien(u.unit_number) then 'lien recorded'
                  when roca_unit_balance(u.unit_number) > 0 then 'balance ' || to_char(roca_unit_balance(u.unit_number), 'FM$999,990.00') end
      from condo_units u
      join condo_ownerships s on s.unit_id = u.id and s.is_current
      join condo_owners o on o.id = s.owner_id
      where u.unit_number ~ '^\d+$'
      order by roca_unit_sort(u.unit_number);
  end if;
end;
$$;
revoke all on function roca_voters(uuid) from public, anon, authenticated;

-- Count the votes against the resolution's threshold.
create or replace function roca_tally(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r roca_resolutions; n_elig int; n_yes int; n_no int; n_abs int; n_rec int; v_pass boolean; v_rule text; chair text;
begin
  select * into r from roca_resolutions where id = p_id;
  select count(*) filter (where eligible) into n_elig from roca_voters(p_id);
  select count(*) filter (where v.vote = 'yes'), count(*) filter (where v.vote = 'no'), count(*) filter (where v.vote = 'abstain'), count(*) filter (where v.vote = 'recused')
    into n_yes, n_no, n_abs, n_rec
    from roca_resolution_votes v join roca_voters(p_id) e on e.voter_key = v.voter_key and e.eligible
    where v.resolution_id = p_id;
  if r.threshold = 'board_majority_all' then
    v_pass := n_yes * 2 > n_elig; v_rule := 'majority of all ' || n_elig || ' directors';
  elsif r.threshold = 'board_hearing' then
    -- Majority of the directors not recused; the Chairperson (President) votes only to break a tie.
    select v.vote into chair from roca_resolution_votes v where v.resolution_id = p_id and v.voter_key = 'seat:President';
    if chair in ('yes', 'no') then
      if (n_yes - (chair = 'yes')::int) = (n_no - (chair = 'no')::int) then v_pass := chair = 'yes';
      else v_pass := (n_yes - (chair = 'yes')::int) > (n_no - (chair = 'no')::int); end if;
    else v_pass := n_yes > n_no; end if;
    v_rule := 'board hearing: majority of directors voting, Chairperson breaks a tie';
  elsif r.threshold = 'members_majority' then
    v_pass := n_yes * 2 > n_elig; v_rule := 'more than 50% of ' || n_elig || ' member votes';
  elsif r.threshold = 'members_75pct' then
    v_pass := n_yes * 4 >= n_elig * 3; v_rule := 'at least 75% of ' || n_elig || ' member votes';
  else
    v_pass := n_elig > 0 and n_yes = n_elig; v_rule := 'written consent of all ' || n_elig || ' members in good standing';
  end if;
  return jsonb_build_object('eligible', n_elig, 'yes', n_yes, 'no', n_no, 'abstain', n_abs, 'recused', n_rec, 'passes', coalesce(v_pass, false), 'rule', v_rule);
end;
$$;
revoke all on function roca_tally(uuid) from public, anon, authenticated;

create or replace function roca_row(r roca_resolutions)
returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(r) || jsonb_build_object(
    'live_tally', case when r.status = 'voting' then roca_tally(r.id) else r.tally end,
    'votes', coalesce((select jsonb_agg(jsonb_build_object('voter_key', v.voter_key, 'voter_name', v.voter_name, 'vote', v.vote, 'via', v.via, 'note', v.note, 'voted_at', v.voted_at, 'recorded_by', v.recorded_by) order by v.voter_key)
                       from roca_resolution_votes v where v.resolution_id = r.id), '[]'::jsonb),
    'voters', case when r.status in ('draft', 'voting') then coalesce((select jsonb_agg(jsonb_build_object('voter_key', x.voter_key, 'voter_name', x.voter_name, 'eligible', x.eligible, 'reason', x.reason)) from roca_voters(r.id) x), '[]'::jsonb) end);
$$;
revoke all on function roca_row(roca_resolutions) from public, anon, authenticated;

-- Carry out an adopted resolution through its kind's executor, if that module is installed.
create or replace function roca_resolution_execute(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; v_fn regprocedure; v_res jsonb;
begin
  select * into r from roca_resolutions where id = p_id for update;
  if r.status <> 'adopted' then raise exception 'Only an adopted resolution can be carried out.'; end if;
  if r.executed_at is not null then return r.execution_result; end if;
  v_fn := to_regprocedure('public.roca_exec_' || r.kind || '(uuid)');
  if v_fn is null then
    update roca_resolutions set execution_result = jsonb_build_object('note', 'Nothing to carry out automatically for this kind.'), executed_at = now(), updated_at = now() where id = p_id;
    return jsonb_build_object('note', 'Nothing to carry out automatically for this kind.');
  end if;
  begin
    execute format('select %s($1)', v_fn::regproc) into v_res using p_id;
    update roca_resolutions set executed_at = now(), execution_result = v_res, execution_error = null, updated_at = now() where id = p_id;
  exception when others then
    update roca_resolutions set execution_error = sqlerrm, updated_at = now() where id = p_id;
    v_res := jsonb_build_object('error', sqlerrm);
  end;
  return v_res;
end;
$$;
revoke all on function roca_resolution_execute(uuid) from public, anon, authenticated;

-- Create a draft. Modules and automations call this (no sign-in check); the staff wrapper below checks sign-in.
create or replace function roca_resolution_propose(p_kind text, p_title text, p_body text, p_threshold text, p_payload jsonb,
  p_origin text, p_origin_note text, p_by text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into roca_resolutions (kind, title, body, threshold, payload, origin, origin_note, proposed_by)
  values (p_kind, p_title, p_body, p_threshold, coalesce(p_payload, '{}'::jsonb), coalesce(p_origin, 'manual'), p_origin_note, p_by)
  returning id into v_id;
  if p_origin = 'automation' then
    perform office_alert('roca_alert_email', 'roca_resolution', 'Board business proposed: ' || p_title,
      '<p>The system proposed a resolution for the board/members to decide: <b>' || repair_esc(p_title) || '</b>.</p>'
      || case when p_origin_note is not null then '<p>' || repair_esc(p_origin_note) || '</p>' else '' end
      || '<p>Nothing happens until it is opened for a vote and adopted. Review it at https://2ndchinc.org/association-owners/roca1/board/</p>');
  end if;
  return v_id;
end;
$$;
revoke all on function roca_resolution_propose(text, text, text, text, jsonb, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Staff
create or replace function roca_staff_check()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
end;
$$;
revoke all on function roca_staff_check() from public, anon, authenticated;

create or replace function roca_resolutions_staff_list(p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return coalesce((select jsonb_agg(roca_row(r) order by (r.status = 'voting') desc, (r.status = 'draft') desc, coalesce(r.decided_at, r.proposed_at) desc)
    from roca_resolutions r where p_status is null or r.status = p_status), '[]'::jsonb);
end;
$$;
revoke all on function roca_resolutions_staff_list(text) from public, anon;
grant execute on function roca_resolutions_staff_list(text) to authenticated;

create or replace function roca_resolution_save(p_id uuid, p_kind text, p_title text, p_body text, p_threshold text, p_payload jsonb, p_source_document text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions;
begin
  perform roca_staff_check();
  if length(coalesce(trim(p_title), '')) < 3 then raise exception 'Give the resolution a title.'; end if;
  if p_id is null then
    r.id := roca_resolution_propose(p_kind, trim(p_title), p_body, p_threshold, p_payload, 'manual', null, lower(auth.email()));
    update roca_resolutions set source_document = nullif(trim(coalesce(p_source_document, '')), '') where id = r.id;
  else
    update roca_resolutions set kind = p_kind, title = trim(p_title), body = p_body, threshold = p_threshold, payload = coalesce(p_payload, '{}'::jsonb),
      source_document = nullif(trim(coalesce(p_source_document, '')), ''), updated_at = now()
    where id = p_id and status = 'draft' returning id into r.id;
    if r.id is null then raise exception 'Only a draft can be edited. Withdraw it and start a new one.'; end if;
  end if;
  select * into r from roca_resolutions where id = r.id;
  return roca_row(r);
end;
$$;
revoke all on function roca_resolution_save(uuid, text, text, text, text, jsonb, text) from public, anon;
grant execute on function roca_resolution_save(uuid, text, text, text, text, jsonb, text) to authenticated;

-- Open voting: number it, set the closing day, email every eligible voter.
create or replace function roca_resolution_open(p_id uuid, p_closes_on date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; v_num text; v record; v_close date;
begin
  perform roca_staff_check();
  v_close := coalesce(p_closes_on, current_date + coalesce((select value from portal_settings where key = 'roca_vote_days'), '14')::int);
  select to_char(current_date, 'YYYY') || '-' || lpad((count(*) + 1)::text, 2, '0') into v_num
    from roca_resolutions where number like to_char(current_date, 'YYYY') || '-%';
  update roca_resolutions set status = 'voting', number = coalesce(number, v_num), voting_opened_at = now(), voting_closes_on = v_close, updated_at = now()
   where id = p_id and status = 'draft' returning * into r;
  if r.id is null then raise exception 'Only a draft can be opened for a vote.'; end if;
  for v in select distinct on (email) * from roca_voters(p_id) where eligible and email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (v.email,
      'ROCA1 resolution ' || r.number || ' — your vote: ' || r.title,
      '<p>Dear ' || repair_esc(coalesce(v.voter_name, 'Member')) || ',</p><p>Resolution <b>' || r.number || ' — ' || repair_esc(r.title) || '</b> is open for a vote until <b>'
      || to_char(v_close, 'FMMonth FMDD, YYYY') || '</b>.</p>'
      || case when r.body is not null then '<blockquote style="border-left:3px solid #ccc;padding-left:10px">' || replace(repair_esc(r.body), E'\n', '<br>') || '</blockquote>' else '' end
      || '<p>Vote in the owner portal: https://2ndchinc.org/association-owners/roca1/#board</p><p>Royal Orleans Condominium Association – Addition 1 (ROCA1)</p>', 'roca_vote');
  end loop;
  return roca_row(r);
end;
$$;
revoke all on function roca_resolution_open(uuid, date) from public, anon;
grant execute on function roca_resolution_open(uuid, date) to authenticated;

create or replace function roca_vote_store(p_id uuid, p_voter text, p_vote text, p_via text, p_note text, p_by text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v record;
begin
  if not exists (select 1 from roca_resolutions where id = p_id and status = 'voting') then raise exception 'This resolution is not open for a vote.'; end if;
  select * into v from roca_voters(p_id) where voter_key = p_voter;
  if v.voter_key is null then raise exception 'That voter isn''t entitled to vote on this resolution.'; end if;
  if not v.eligible then raise exception 'Unit not in good standing (%): its vote can''t be accepted.', v.reason; end if;
  insert into roca_resolution_votes (resolution_id, voter_key, voter_name, owner_id, vote, via, note, recorded_by)
  values (p_id, p_voter, v.voter_name, v.owner_id, p_vote, p_via, nullif(trim(coalesce(p_note, '')), ''), p_by)
  on conflict (resolution_id, voter_key) do update set vote = excluded.vote, via = excluded.via, note = excluded.note, voted_at = now(), recorded_by = excluded.recorded_by;
end;
$$;
revoke all on function roca_vote_store(uuid, text, text, text, text, text) from public, anon, authenticated;

-- Staff record a vote cast at a meeting, on paper or by email.
create or replace function roca_vote_record(p_id uuid, p_voter text, p_vote text, p_via text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions;
begin
  perform roca_staff_check();
  perform roca_vote_store(p_id, p_voter, p_vote, coalesce(p_via, 'staff'), p_note, lower(auth.email()));
  select * into r from roca_resolutions where id = p_id;
  return roca_row(r);
end;
$$;
revoke all on function roca_vote_record(uuid, text, text, text, text) from public, anon;
grant execute on function roca_vote_record(uuid, text, text, text, text) to authenticated;

-- Close: count, adopt or reject, and carry out what was adopted. Staff may close early once the outcome is settled.
create or replace function roca_resolution_close(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; t jsonb; v_by text := coalesce(lower(auth.email()), 'automation'); v record;
begin
  if auth.uid() is not null then perform roca_staff_check(); end if;
  t := roca_tally(p_id);
  update roca_resolutions set status = case when (t->>'passes')::boolean then 'adopted' else 'rejected' end, tally = t, decided_at = now(), decided_by = v_by, updated_at = now()
   where id = p_id and status = 'voting' returning * into r;
  if r.id is null then raise exception 'Only a resolution open for a vote can be closed.'; end if;
  if r.status = 'adopted' then perform roca_resolution_execute(r.id); end if;
  for v in select distinct on (email) * from roca_voters(p_id) where email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (v.email,
      'ROCA1 resolution ' || r.number || ' ' || r.status || ': ' || r.title,
      '<p>Resolution <b>' || r.number || ' — ' || repair_esc(r.title) || '</b> was <b>' || r.status || '</b> (' || (t->>'yes') || ' yes, ' || (t->>'no') || ' no; ' || repair_esc(t->>'rule') || ').</p><p>ROCA1</p>', 'roca_vote');
  end loop;
  select * into r from roca_resolutions where id = p_id;
  return roca_row(r);
end;
$$;
revoke all on function roca_resolution_close(uuid) from public, anon;
grant execute on function roca_resolution_close(uuid) to authenticated;

create or replace function roca_resolution_withdraw(p_id uuid, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions;
begin
  perform roca_staff_check();
  update roca_resolutions set status = 'withdrawn', decided_at = now(), decided_by = lower(auth.email()),
    origin_note = concat_ws(' · ', origin_note, 'Withdrawn: ' || nullif(trim(coalesce(p_note, '')), '')), updated_at = now()
   where id = p_id and status in ('draft', 'voting') returning * into r;
  if r.id is null then raise exception 'Only a draft or an open resolution can be withdrawn.'; end if;
  return roca_row(r);
end;
$$;
revoke all on function roca_resolution_withdraw(uuid, text) from public, anon;
grant execute on function roca_resolution_withdraw(uuid, text) to authenticated;

-- Retry carrying out an adopted resolution whose execution failed.
create or replace function roca_resolution_retry(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return roca_resolution_execute(p_id);
end;
$$;
revoke all on function roca_resolution_retry(uuid) from public, anon;
grant execute on function roca_resolution_retry(uuid) to authenticated;

-- Record a resolution adopted before this system (signed action on file). Optionally carry it out.
create or replace function roca_resolution_record_adopted(p_kind text, p_title text, p_body text, p_threshold text, p_payload jsonb,
  p_decided_on date, p_source_document text, p_rod_document text, p_execute boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions;
begin
  if auth.uid() is not null then perform roca_staff_check(); end if;
  insert into roca_resolutions (kind, title, body, threshold, payload, status, origin, origin_note, proposed_by, decided_at, decided_by, source_document, rod_document, number)
  values (p_kind, p_title, p_body, p_threshold, coalesce(p_payload, '{}'::jsonb), 'adopted', 'historical', 'Adopted before this system; recorded from the signed document on file.',
    coalesce(lower(auth.email()), 'import'), p_decided_on::timestamptz, coalesce(lower(auth.email()), 'import'), p_source_document, p_rod_document,
    to_char(p_decided_on, 'YYYY') || '-H' || lpad((select count(*) + 1 from roca_resolutions where number like to_char(p_decided_on, 'YYYY') || '-H%')::text, 2, '0'))
  returning * into r;
  if coalesce(p_execute, false) then perform roca_resolution_execute(r.id);
  else update roca_resolutions set executed_at = now(), execution_result = jsonb_build_object('note', 'Historical: already carried out at the time.') where id = r.id; end if;
  select * into r from roca_resolutions where id = r.id;
  return roca_row(r);
end;
$$;
revoke all on function roca_resolution_record_adopted(text, text, text, text, jsonb, date, text, text, boolean) from public, anon;
grant execute on function roca_resolution_record_adopted(text, text, text, text, jsonb, date, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Owners and directors (owner portal)
create or replace function roca_my_voter_keys()
returns table (resolution_id uuid, voter_key text)
language sql stable security definer set search_path = public as $$
  select r.id, v.voter_key from roca_resolutions r cross join lateral roca_voters(r.id) v
  where r.status in ('voting', 'adopted', 'rejected') and v.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok();
$$;
revoke all on function roca_my_voter_keys() from public, anon, authenticated;

create or replace function roca_resolutions_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'open', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'kind', r.kind, 'title', r.title, 'body', r.body, 'closes_on', r.voting_closes_on,
        'threshold', r.threshold, 'tally', roca_tally(r.id),
        'my_votes', (select jsonb_agg(jsonb_build_object('voter_key', x.voter_key, 'label', replace(replace(x.voter_key, 'seat:', ''), 'unit:', 'Unit '), 'eligible', x.eligible, 'reason', x.reason,
                       'vote', (select vote from roca_resolution_votes vv where vv.resolution_id = r.id and vv.voter_key = x.voter_key)))
                     from roca_voters(r.id) x where x.owner_id = v_owner)) order by r.voting_closes_on)
      from roca_resolutions r where r.status = 'voting' and exists (select 1 from roca_voters(r.id) x where x.owner_id = v_owner)), '[]'::jsonb),
    'decided', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'kind', r.kind, 'title', r.title, 'body', r.body, 'status', r.status,
        'decided_at', r.decided_at, 'tally', r.tally) order by r.decided_at desc)
      from roca_resolutions r where r.status in ('adopted', 'rejected') and r.decided_at > now() - interval '3 years'), '[]'::jsonb));
end;
$$;
revoke all on function roca_resolutions_mine() from public, anon;
grant execute on function roca_resolutions_mine() to authenticated;

create or replace function roca_vote_mine(p_id uuid, p_voter text, p_vote text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from roca_voters(p_id) x where x.voter_key = p_voter and x.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()) then
    raise exception 'That vote isn''t yours to cast.' using errcode = '42501'; end if;
  if p_vote not in ('yes', 'no', 'abstain', 'recused') then raise exception 'Choose yes, no, abstain or recused.'; end if;
  perform roca_vote_store(p_id, p_voter, p_vote, 'portal', p_note, lower(auth.email()));
  return roca_resolutions_mine();
end;
$$;
revoke all on function roca_vote_mine(uuid, text, text, text) from public, anon;
grant execute on function roca_vote_mine(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Automation: one entry point. Each module adds roca_auto_<name>(p_today date, p_live boolean) returning jsonb;
-- this runs every one it finds, in name order. Off (dry run) unless automation_mode = 'live'.
create or replace function roca_automation_run(p_today date default current_date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_live boolean := coalesce((select value from portal_settings where key = 'automation_mode'), 'off') = 'live';
  f record; v_out jsonb := '{}'::jsonb; v_res jsonb;
begin
  if auth.uid() is not null then perform roca_staff_check(); end if;
  -- Close votes whose window ended.
  if v_live then
    for f in select id from roca_resolutions where status = 'voting' and voting_closes_on < p_today loop
      perform roca_resolution_close(f.id);
    end loop;
  end if;
  for f in select p.oid::regprocedure as fn, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'roca\_auto\_%' and pg_get_function_identity_arguments(p.oid) = 'p_today date, p_live boolean'
           order by p.proname loop
    begin
      execute format('select %s($1, $2)', f.fn::regproc) into v_res using p_today, v_live;
      v_out := v_out || jsonb_build_object(f.proname, v_res);
    exception when others then
      v_out := v_out || jsonb_build_object(f.proname, jsonb_build_object('error', sqlerrm));
    end;
  end loop;
  insert into roca_automation_runs (run_on, mode, result, run_by) values (p_today, case when v_live then 'live' else 'off' end, v_out, coalesce(lower(auth.email()), 'scheduler'));
  return jsonb_build_object('mode', case when v_live then 'live' else 'off (dry run: nothing posted or emailed)' end, 'results', v_out);
end;
$$;
revoke all on function roca_automation_run(date) from public, anon;
grant execute on function roca_automation_run(date) to authenticated;
