-- ---------------------------------------------------------------- what the pages call

-- "I'm still here": records activity for this sign-in. Never unlocks a locked screen and never revives an expired sign-in.
create or replace function public.mirror_session_touch()
returns jsonb language plpgsql volatile security definer set search_path = mirror, public as $$
declare v_sid uuid := mirror.session_id(); v_state text := mirror.session_state();
begin
  if v_state = 'ok' and v_sid is not null then
    insert into mirror.device_sessions (session_id, user_id, last_seen) values (v_sid, auth.uid(), now())
      on conflict (session_id) do update set last_seen = now();
    delete from mirror.device_sessions where last_seen < now() - interval '120 days';   -- old sign-ins: nothing left to measure
  end if;
  return jsonb_build_object('state', v_state, 'device', mirror.session_device());
end $$;

-- "Is this your own phone or computer?" Once shared, always shared for this sign-in.
create or replace function public.mirror_device_choose(p_shared boolean)
returns jsonb language plpgsql volatile security definer set search_path = mirror, public as $$
declare v_sid uuid := mirror.session_id(); v_prev boolean;
begin
  if auth.email() is null or v_sid is null then raise exception 'Please sign in.' using errcode = '42501'; end if;
  if not mirror.session_ok() then raise exception '%', mirror.session_message() using errcode = '42501'; end if;
  if p_shared is null then raise exception 'Choose "my own" or "shared".' using errcode = '22023'; end if;
  select shared into v_prev from mirror.device_sessions where session_id = v_sid;
  if v_prev is true and not p_shared then
    raise exception 'This sign-in started on a shared device. To stay signed in longer, sign out and sign in again on your own phone or computer.' using errcode = '42501';
  end if;
  insert into mirror.device_sessions (session_id, user_id, shared, chosen_at, last_seen) values (v_sid, auth.uid(), p_shared, now(), now())
    on conflict (session_id) do update set shared = excluded.shared, chosen_at = now(), last_seen = now();
  return jsonb_build_object('state', mirror.session_state(), 'device', mirror.session_device());
end $$;

revoke all on function public.mirror_session_touch(), public.mirror_device_choose(boolean) from public, anon;
grant execute on function public.mirror_session_touch(), public.mirror_device_choose(boolean) to authenticated, service_role;
