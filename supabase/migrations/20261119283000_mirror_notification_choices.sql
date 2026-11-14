-- The Human Mirror, Phase 3 analysis finding 5 (Stephen, 11/13/2026): T3.6 promised "notification choices" in Settings; none existed.
-- The Mirror sends no emails yet (Phase 9), so these are the person's choices for later, said plainly on the page.
--  * Three choices, one per email kind a person will get (prompt Part 10; ARCHITECTURE section 6): referral updates (mirror_referral),
--    appointment reminders (mirror_appointment), reminders about the person's plan (mirror_action). Each on or off. Default on (D-25).
--  * Sign-in codes and security notices (mirror_security) are always sent: they are how the person gets in and learns of changes.
--  * Safety mode stops every one of the three, whatever the choice (shown on the page).
--  * Stored in mirror.profiles.notification_prefs (row per sign-in email, made on first save). Own Mirror only (mirror.me():
--    sign-in, fresh session, no View as). Every change is logged (the person's own action; not shown in "Who looked").
--  * mirror.notification_ok(email, kind) is the one place Phase 9 asks before sending a Mirror email to a person.
-- No table is created, so no new grants are needed (CLAUDE.md, 10/30/2026 rule). mirror.profiles stays service_role only.

create or replace function mirror.notification_defaults() returns jsonb language sql immutable as $$
  select '{"referral": true, "appointment": true, "action": true}'::jsonb
$$;

-- The person's choices (defaults filled in), whether safety mode is stopping them, and what is always sent.
create or replace function public.mirror_my_notifications() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); i mirror.individuals; p jsonb;
begin
  select * into i from mirror.individuals where id = v;
  select notification_prefs into p from mirror.profiles where auth_email = i.auth_email;
  return jsonb_build_object(
    'choices', mirror.notification_defaults() || coalesce((select jsonb_object_agg(k, val) from jsonb_each(coalesce(p, '{}'::jsonb)) e(k, val)
                                                          where mirror.notification_defaults() ? k), '{}'::jsonb),
    'safety_mode', i.safety_sensitive,
    'always', jsonb_build_array('sign_in', 'security'));
end $$;

-- Save one or more choices: p = {"referral": true|false, "appointment": ..., "action": ...}. Unknown keys or non-true/false refused.
create or replace function public.mirror_my_notifications_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); v_email text; k text; val jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' or p = '{}'::jsonb then raise exception 'Nothing to save.' using errcode = '22023'; end if;
  for k, val in select * from jsonb_each(p) loop
    if not mirror.notification_defaults() ? k then raise exception 'Unknown email choice.' using errcode = '22023'; end if;
    if jsonb_typeof(val) <> 'boolean' then raise exception 'Choose on or off.' using errcode = '22023'; end if;
  end loop;
  select auth_email into v_email from mirror.individuals where id = v;
  insert into mirror.profiles (auth_email, notification_prefs) values (v_email, p)
  on conflict (auth_email) do update set notification_prefs = mirror.profiles.notification_prefs || excluded.notification_prefs, updated_at = now();
  perform mirror.audit(v, null, 'self', 'notifications', 'general', 'profiles', (select string_agg(k2 || '=' || (p ->> k2), ',' order by k2) from jsonb_object_keys(p) k2));
  return public.mirror_my_notifications();
end $$;

-- Phase 9 asks this before queueing any Mirror email to a person. Security kinds always go; the three choice kinds go only while the
-- person has not turned them off and safety mode is off. An address with no Mirror person gets only security kinds.
create or replace function mirror.notification_ok(p_email text, p_kind text) returns boolean
language plpgsql stable security definer set search_path = mirror, public as $$
declare i mirror.individuals; pr jsonb; k text := case p_kind when 'mirror_referral' then 'referral' when 'mirror_appointment' then 'appointment'
                                                          when 'mirror_action' then 'action' end;
begin
  if p_kind = 'mirror_security' then return true; end if;
  if k is null then return false; end if;   -- not a kind a person chooses: never sent through this check
  select * into i from mirror.individuals where auth_email = lower(p_email);
  if not found or i.safety_sensitive then return false; end if;
  select notification_prefs into pr from mirror.profiles where auth_email = i.auth_email;
  return coalesce(((mirror.notification_defaults() || coalesce(pr, '{}'::jsonb)) ->> k)::boolean, false);
end $$;

revoke all on function mirror.notification_defaults(), mirror.notification_ok(text, text) from public, anon, authenticated;
grant execute on function mirror.notification_defaults(), mirror.notification_ok(text, text) to service_role;
revoke all on function public.mirror_my_notifications(), public.mirror_my_notifications_set(jsonb) from public, anon;
grant execute on function public.mirror_my_notifications(), public.mirror_my_notifications_set(jsonb) to authenticated, service_role;
