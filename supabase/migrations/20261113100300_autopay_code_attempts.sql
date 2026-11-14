-- Autopay fix: a wrong code now really counts toward the 5-try limit. Before, the error rolled back the attempt count, so the limit never triggered.
-- A wrong code is answered with {error} instead of an exception, so the count is saved. (Autopay is still off; nobody is enrolled.)

create or replace function autopay_start(p_code text, p_draw_day int, p_typed_name text, p_acks jsonb, p_version text, p_first date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_t uuid := autopay_me(); s record; v_name text; v_email text; c autopay_codes; a autopay_authorizations; v_first date; v_terms text;
  v_hdr jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb); v_words text[]; v_typed text[]; w text; ok boolean := true;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be set up by the tenant, from their own sign-in.'; end if;
  if condo_setting('autopay_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  if v_t is null then raise exception 'Autopay is for an active lease or land contract.'; end if;
  if p_version is distinct from 'autopay-2026-10-v1' then raise exception 'These terms changed. Reload the page and read them again.'; end if;
  if coalesce(p_draw_day, 0) not between 1 and 5 then raise exception 'Choose a day from the 1st to the 5th.'; end if;
  if not (coalesce(p_acks ->> 'set_up_myself', 'false') = 'true' and coalesce(p_acks ->> 'understand_return', 'false') = 'true'
          and coalesce(p_acks ->> 'keep_money', 'false') = 'true' and coalesce(p_acks ->> 'can_cancel', 'false') = 'true') then
    raise exception 'Check all four boxes to show you read and agree.';
  end if;
  select name, email into v_name, v_email from tenants where id = v_t;
  if coalesce(v_email, '') not like '%@%' then raise exception 'We need your email address on file first.'; end if;
  -- the typed name must contain the first and last name on file
  v_words := regexp_split_to_array(lower(regexp_replace(coalesce(v_name, ''), '[^A-Za-z ]', ' ', 'g')), '\s+');
  v_typed := regexp_split_to_array(lower(regexp_replace(coalesce(p_typed_name, ''), '[^A-Za-z ]', ' ', 'g')), '\s+');
  if array_length(v_words, 1) >= 2 and not (v_words[1] = any (v_typed) and v_words[array_length(v_words, 1)] = any (v_typed)) then
    raise exception 'Type your full name as it appears on your account.';
  end if;
  -- the code
  select * into c from autopay_codes where tenant_id = v_t and used_at is null and expires_at > now() order by id desc limit 1 for update;
  if c.id is null then raise exception 'That code has expired. Ask for a new one.'; end if;
  if c.attempts >= 5 then raise exception 'Too many wrong tries. Ask for a new code.'; end if;
  if c.code_hash <> autopay_hash(v_t::text || ':' || trim(coalesce(p_code, ''))) then
    update autopay_codes set attempts = attempts + 1 where id = c.id;
    return jsonb_build_object('error', case when c.attempts + 1 >= 5 then 'That code is not right. Too many wrong tries: ask for a new code.' else 'That code is not right.' end);
  end if;
  update autopay_codes set used_at = now() where id = c.id;
  select * into s from autopay_subject(v_t) limit 1;
  v_first := autopay_next_draw(p_draw_day, autopay_today() + 8);
  if p_first is distinct from v_first then raise exception 'The page is out of date. Reload it and try again.'; end if;
  v_terms := autopay_terms(trim(p_typed_name), s.amount, p_draw_day, s.label, s.is_lease, v_first);
  -- replace any unfinished setup
  perform autopay_set_actor('tenant');
  update autopay_authorizations set status = 'canceled', ended_at = now(), ended_by = 'tenant', ended_reason = 'replaced by a new setup' where tenant_id = v_t and status = 'pending';
  insert into autopay_authorizations (tenant_id, lease_id, land_contract_id, amount, draw_day, terms_version, terms_text, acks, typed_name, ip, user_agent, row_hash)
  values (v_t, s.lease_id, s.land_contract_id, s.amount, p_draw_day, p_version, v_terms, p_acks, trim(p_typed_name),
          left(coalesce(v_hdr ->> 'x-forwarded-for', v_hdr ->> 'cf-connecting-ip', ''), 80), left(coalesce(v_hdr ->> 'user-agent', ''), 300), 'pending')
  returning * into a;
  perform autopay_event(a.id, 'created', jsonb_build_object('amount', a.amount, 'draw_day', a.draw_day, 'first_draw', v_first, 'terms_version', a.terms_version, 'ip', a.ip), 'tenant');
  return jsonb_build_object('authorization_id', a.id);
end;
$$;
revoke all on function autopay_start(text, int, text, jsonb, text, date) from public, anon;
grant execute on function autopay_start(text, int, text, jsonb, text, date) to authenticated;
