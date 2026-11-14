-- Owner portal fixes, batch A (Stephen, 10/13/2026): privacy and correctness.
--   1. A vote is judged when it is cast, not when the vote closes (dues posting on the 1st no longer voids a vote).
--   2. A co-owned unit counts once in the tally.
--   3. The 14-day hearing deadline runs to the end of the day in Central time, not UTC.
--   4. A request about the inside of an owner's own unit is never emailed to the board or sent to the board as a resolution,
--      and a resolution drafted from an owner request says "an owner", never the owner's name.
--   5. owner_request_create validates urgency, location and photos on the server.
--   6. Stale "sign-in codes are texted" message removed (sign-in is email only).
--   7. condo_owner_pay_options is for owners and staff only, and says whether online payment is really ready.
-- History is untouched: only functions change, no ledger or vote rows.

-- ---------------------------------------------------------------------------
-- 1 + 2. Tally: one row per voter key (co-owners share a unit's single vote); a vote that was valid when cast
-- still counts and the unit still counts toward "eligible" even if it has since fallen out of good standing.
create or replace function roca_tally(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r roca_resolutions; n_elig int; n_yes int; n_no int; n_abs int; n_rec int; v_pass boolean; v_rule text; chair text;
begin
  select * into r from roca_resolutions where id = p_id;
  select count(*) filter (where vt.eligible or c.vote is not null),
         count(*) filter (where c.vote = 'yes'), count(*) filter (where c.vote = 'no'),
         count(*) filter (where c.vote = 'abstain'), count(*) filter (where c.vote = 'recused')
    into n_elig, n_yes, n_no, n_abs, n_rec
    from (select x.voter_key, bool_or(x.eligible) as eligible from roca_voters(p_id) x group by x.voter_key) vt
    left join roca_resolution_votes c on c.resolution_id = p_id and c.voter_key = vt.voter_key;
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

-- ---------------------------------------------------------------------------
-- 3. Hearing deadline: compared with today's date in Central time.
do $do$
declare v text := pg_get_functiondef('roca_violation_request_hearing(bigint, text)'::regprocedure);
  v_old text := $o$v.appeal_deadline < current_date$o$;
  v_new text := $n$v.appeal_deadline < (now() at time zone 'America/Chicago')::date$n$;
begin
  if position(v_old in v) = 0 then raise exception 'roca_violation_request_hearing changed: cannot patch'; end if;
  execute replace(v, v_old, v_new);
end $do$;

-- ---------------------------------------------------------------------------
-- 4. Owner requests and the board.
do $do$
declare v text := pg_get_functiondef('owner_request_notify(uuid)'::regprocedure);
  v_old text := $o$if v_board then$o$;
  v_new text := $n$if v_board and r.location <> 'my_unit' then$n$;
begin
  if position(v_old in v) = 0 then raise exception 'owner_request_notify changed: cannot patch'; end if;
  execute replace(v, v_old, v_new);
end $do$;

do $do$
declare v text := pg_get_functiondef('owner_request_staff_send_to_board(uuid)'::regprocedure);
  v_old1 text := $o$if r.resolution_id is not null then return r.resolution_id; end if;$o$;
  v_new1 text := $n$if r.resolution_id is not null then return r.resolution_id; end if;
  if r.location = 'my_unit' then raise exception 'A request about the inside of an owner''s own unit is not a board matter. Answer it from the office.'; end if;$n$;
  v_old2 text := $o$coalesce(v_owner, 'an owner') || ', urgency '$o$;
  v_new2 text := $n$'an owner' || ', urgency '$n$;
begin
  if position(v_old1 in v) = 0 or position(v_old2 in v) = 0 then raise exception 'owner_request_staff_send_to_board changed: cannot patch'; end if;
  execute replace(replace(v, v_old1, v_new1), v_old2, v_new2);
end $do$;

-- ---------------------------------------------------------------------------
-- 5. owner_request_create with server-side checks.
create or replace function owner_request_create(p_location text, p_unit text, p_category text, p_subject text, p_description text,
  p_urgency text, p_safety boolean, p_inspector boolean, p_photos text[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); r owner_requests; v_scope text; v_budget text; v_urg text := coalesce(nullif(p_urgency, ''), 'normal');
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_subject, ''))) < 3 or length(trim(coalesce(p_description, ''))) < 5 then raise exception 'Please say what needs attention and describe it.'; end if;
  if length(p_subject) > 150 or length(p_description) > 5000 then raise exception 'That is too long. Keep the title under 150 characters and the description under 5,000.'; end if;
  if v_urg not in ('emergency', 'urgent', 'normal', 'wish') then raise exception 'Choose how urgent it is.'; end if;
  if coalesce(p_location, '') not in ('6622', '6626', 'both', 'my_unit') then raise exception 'Choose where the problem is.'; end if;
  if coalesce(array_length(p_photos, 1), 0) > 6 then raise exception 'You can attach up to 6 photos.'; end if;
  select scope, budget_code into v_scope, v_budget from roca_request_categories where code = p_category;
  if v_scope is null then raise exception 'Choose what kind of problem it is.'; end if;
  if p_location = 'my_unit' or v_scope = 'unit' then
    if not exists (select 1 from condo_ownerships s join condo_units cu on cu.id = s.unit_id where s.is_current and s.owner_id = v_owner and cu.unit_number = p_unit) then
      raise exception 'Choose which of your units it is in.'; end if;
  end if;
  if exists (select 1 from unnest(coalesce(p_photos, '{}')) ph where ph not like v_owner::text || '/%' or ph like '%..%') then raise exception 'Bad photo path'; end if;
  insert into owner_requests (owner_id, location, unit_number, category, subject, description, urgency, safety, inspector_note, photos, budget_code)
  values (v_owner, case when v_scope = 'unit' then 'my_unit' else p_location end, nullif(p_unit, ''), p_category, trim(p_subject), trim(p_description),
          v_urg, coalesce(p_safety, false), coalesce(p_inspector, false), coalesce(p_photos, '{}'), v_budget)
  returning * into r;
  insert into owner_request_updates (request_id, by_role, by_email, note) values (r.id, 'owner', auth.email(), 'Request sent.');
  perform owner_request_notify(r.id);
  return jsonb_build_object('number', r.number);
end;
$$;
revoke all on function owner_request_create(text, text, text, text, text, text, boolean, boolean, text[]) from public, anon;
grant execute on function owner_request_create(text, text, text, text, text, text, boolean, boolean, text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Stale message (sign-in is by emailed code now, nothing is texted).
do $do$
declare v text := pg_get_functiondef('condo_update_my_profile(jsonb)'::regprocedure);
  v_old text := $o$Mobile phone needs all 10 digits — it is where your sign-in codes are texted$o$;
  v_new text := $n$Mobile phone needs all 10 digits, or leave it blank$n$;
begin
  if position(v_old in v) = 0 then raise exception 'condo_update_my_profile changed: cannot patch'; end if;
  execute replace(v, v_old, v_new);
end $do$;

-- ---------------------------------------------------------------------------
-- 7. Pay options: owners and staff only; owner_stripe_ready says online payment will really open (setting on, ROCA1 Stripe on, method set).
create or replace function condo_owner_pay_options()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if condo_owner_for_email(auth.email()) is null and not condo_is_staff() then raise exception 'Owners only' using errcode = '42501'; end if;
  v := coalesce((select jsonb_object_agg(key, value) from portal_settings where key like 'owner_pay_%' and value <> ''), '{}'::jsonb);
  if coalesce(v->>'owner_pay_paypal', 'off') <> 'on' then v := v - 'owner_pay_paypal_client_id' - 'owner_pay_paypal_hosted_id' - 'owner_pay_paypal_link'; end if;
  return v || jsonb_build_object('stripe_enabled', coalesce((select value from portal_settings where key = 'stripe_enabled'), 'off'),
    'owner_stripe_ready', coalesce((select value from portal_settings where key = 'owner_pay_stripe'), 'off') = 'on'
      and coalesce((select value from portal_settings where key = 'stripe_enabled_roca1'), 'off') = 'on'
      and coalesce((select value from portal_settings where key = 'stripe_pmc_roca1'), '') <> '');
end;
$$;
revoke all on function condo_owner_pay_options() from public, anon;
grant execute on function condo_owner_pay_options() to authenticated;
