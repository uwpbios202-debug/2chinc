-- The Human Mirror Phase 9, handoff step 23: T9.1 templates and preferences (ARCHITECTURE section 6, D-17, D-25).
-- The person's email choices already exist (Phase 3 fix 5: Settings, mirror.notification_ok). This adds the rest:
--   * mirror.email_html(kind, data): every Mirror email's words in one place. Six kinds (ARCHITECTURE 6): mirror_invite,
--     mirror_staff_invite, mirror_referral, mirror_appointment, mirror_action, mirror_security. Content never names a health, legal,
--     money or safety detail; it says what kind of thing is waiting and links to sign in (https://2ndchinc.org/mirror/sign-in/).
--     For a person in safety mode the always-sent kinds (security, invite) say only "2nd Chance Housing": no "Mirror", no organization.
--   * mirror.email_queue(email, kind, data, individual): the ONE way any Mirror email is queued. It asks mirror.notification_ok for the
--     three choice kinds (the person's choice, safety mode), skips a repeat of the same item within 12 hours, and records every attempt
--     in mirror.notifications (who, kind, when, held / queued / skipped and why; the words are not stored).
--   * THE HOLD (CLAUDE.md: the first real send of each kind asks Stephen): a kind reaches public.email_outbox (and so is sent) only
--     while it is listed in portal_settings.mirror_email_kinds_enabled, which starts EMPTY. Until Stephen turns a kind on, every email
--     of that kind is recorded as "held" and never sent; held emails are not sent later when the kind is turned on (they would be stale).
--   * /mirror/admin/email/: platform admins see each kind's exact words (normal and safety mode) and how many were held, queued or
--     skipped (counts only); only the 2nd Chance main admin (portal_admins) turns a kind on or off. Every switch is logged.
-- Nothing calls email_queue yet: the invitation (T2.6 second half) and reminders (T9.2) come next. No email is sent by this migration.
-- New table carries explicit grants (CLAUDE.md, 10/30/2026): service_role only; authenticated and anon none.

insert into portal_settings (key, value) values ('mirror_email_kinds_enabled', '') on conflict (key) do nothing;

create table mirror.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_email text not null,
  individual_id uuid references mirror.individuals(id) on delete set null,
  kind text not null check (kind in ('mirror_invite', 'mirror_staff_invite', 'mirror_referral', 'mirror_appointment', 'mirror_action', 'mirror_security')),
  ref text,
  status text not null check (status in ('held', 'queued', 'skipped')),
  reason text,
  outbox_id bigint,
  created_at timestamptz not null default now()
);
create index notifications_recent on mirror.notifications (recipient_email, kind, created_at);
alter table mirror.notifications enable row level security;
revoke all on mirror.notifications from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.notifications to service_role;

create or replace function mirror.email_kinds() returns jsonb language sql immutable as $$
  select '[{"kind":"mirror_invite","label":"Invitation to a person","choice":null},
           {"kind":"mirror_staff_invite","label":"Invitation to an organization member","choice":null},
           {"kind":"mirror_referral","label":"Updates on referrals","choice":"referral"},
           {"kind":"mirror_appointment","label":"Appointment reminders","choice":"appointment"},
           {"kind":"mirror_action","label":"Reminders about the plan","choice":"action"},
           {"kind":"mirror_security","label":"Security notices (always sent)","choice":null}]'::jsonb;
$$;

-- The words. data: first_name, organization, when (a date/time already written out), safety (true = neutral wording), reason (security).
create or replace function mirror.email_html(p_kind text, p_data jsonb) returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare
  v_first text := repair_esc(coalesce(nullif(trim(p_data ->> 'first_name'), ''), 'there'));
  v_org text := repair_esc(coalesce(nullif(trim(p_data ->> 'organization'), ''), '2nd Chance Housing'));
  v_when text := repair_esc(nullif(trim(coalesce(p_data ->> 'when', '')), ''));
  v_safe boolean := coalesce((p_data ->> 'safety')::boolean, false);
  v_link text := case when coalesce((p_data ->> 'safety')::boolean, false) then 'https://2ndchinc.org/account/' else 'https://2ndchinc.org/mirror/sign-in/' end;   -- safety mode: neutral address (site/_redirects)
  v_btn text; v_subject text; v_body text;
begin
  v_btn := '<p><a href="' || v_link || '" style="display:inline-block;background:#1f5f8b;color:#ffffff;padding:10px 18px;border-radius:6px;text-decoration:none">Sign in</a></p>'
        || '<p style="color:#555;font-size:13px">Or copy this link: ' || v_link || '</p>';
  case p_kind
    when 'mirror_invite' then
      if v_safe then
        v_subject := '2nd Chance Housing: please sign in';
        v_body := '<p>Please sign in to 2nd Chance Housing with this email address. You will get a 6-digit code by email.</p>' || v_btn;
      else
        v_subject := v_org || ' invites you to the Human Mirror';
        v_body := '<p>' || v_org || ' invited you to the Human Mirror: a private place for your whole life, your needs, your strengths and the plan you choose.'
          || ' You decide what anyone else sees.</p><p>Sign in with this email address. You will get a 6-digit code by email. Nothing is shared until you choose.</p>' || v_btn;
      end if;
    when 'mirror_staff_invite' then
      v_subject := 'You were added to ' || v_org || ' in the Human Mirror';
      v_body := '<p>You were added as a member of ' || v_org || ' in the Human Mirror. Sign in with this email address: you will get a 6-digit code by email,'
        || ' and the first time you will set up an authenticator app.</p>' || v_btn;
    when 'mirror_referral' then
      v_subject := 'An update on a referral';
      v_body := '<p>There is an update on a referral in your Human Mirror. Sign in to see it.</p>' || v_btn;
    when 'mirror_appointment' then
      v_subject := 'Reminder: an appointment' || coalesce(' on ' || v_when, '');
      v_body := '<p>You have an appointment' || coalesce(' on ' || v_when, ' coming up') || '. Sign in to your Human Mirror to see the details.</p>' || v_btn;
    when 'mirror_action' then
      v_subject := 'A step in your plan is coming up';
      v_body := '<p>A step in your plan is coming up' || coalesce(' (' || v_when || ')', '') || '. Sign in to your Human Mirror to see it.</p>' || v_btn;
    when 'mirror_security' then
      if v_safe then
        v_subject := '2nd Chance Housing: a change to your account';
        v_body := '<p>There was a change to your 2nd Chance Housing account. If it was not you, call 2nd Chance Housing at (262) 236-5443.</p>';
      else
        v_subject := 'A change to your Human Mirror sign-in';
        v_body := '<p>There was a change to your Human Mirror sign-in' || coalesce(': ' || repair_esc(nullif(trim(p_data ->> 'reason'), '')), '')
          || '. If it was not you, call 2nd Chance Housing at (262) 236-5443.</p>';
      end if;
    else raise exception 'Unknown Mirror email kind: %', p_kind using errcode = '22023';
  end case;
  return jsonb_build_object('subject', v_subject,
    'html', '<div style="font-family:Arial,sans-serif;max-width:600px;color:#1b2430"><p>Hi ' || v_first || ',</p>' || v_body
         || '<p>2nd Chance Housing</p><p style="color:#667;font-size:12px">You get this because of your account with 2nd Chance Housing Inc. '
         || case when p_kind in ('mirror_referral', 'mirror_appointment', 'mirror_action') then 'You can turn these emails off in your Settings after you sign in.' else '' end
         || '</p></div>');
end $$;

-- The one way a Mirror email is queued. Returns 'held', 'queued' or 'skipped'.
create or replace function mirror.email_queue(p_email text, p_kind text, p_data jsonb default '{}'::jsonb, p_individual uuid default null) returns text
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v_email text := lower(trim(coalesce(p_email, ''))); i mirror.individuals; v_data jsonb := coalesce(p_data, '{}'::jsonb); m jsonb; v_out bigint;
        v_ref text := nullif(p_data ->> 'ref', ''); v_reason text; v_status text;
begin
  if not exists (select 1 from jsonb_array_elements(mirror.email_kinds()) k where k ->> 'kind' = p_kind) then raise exception 'Unknown Mirror email kind: %', p_kind using errcode = '22023'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return 'skipped'; end if;
  select * into i from mirror.individuals where id = p_individual or (p_individual is null and auth_email = v_email) limit 1;
  v_data := v_data || jsonb_build_object('safety', coalesce(i.safety_sensitive, false));
  if p_kind in ('mirror_referral', 'mirror_appointment', 'mirror_action') and not mirror.notification_ok(v_email, p_kind) then
    v_reason := case when i.safety_sensitive then 'safety mode' else 'turned off by the person, or no Mirror' end;
  elsif v_ref is not null and exists (select 1 from mirror.notifications n where n.recipient_email = v_email and n.kind = p_kind and n.ref = v_ref
                                       and n.status <> 'skipped' and n.created_at > now() - interval '12 hours') then
    v_reason := 'already sent for this item in the last 12 hours';
  end if;
  if v_reason is not null then
    v_status := 'skipped';
  elsif p_kind = any (string_to_array(replace(coalesce(public.condo_setting('mirror_email_kinds_enabled', ''), ''), ' ', ''), ',')) then
    m := mirror.email_html(p_kind, v_data);
    insert into public.email_outbox (to_email, subject, html, kind) values (v_email, m ->> 'subject', m ->> 'html', p_kind) returning id into v_out;
    v_status := 'queued';
  else
    v_status := 'held'; v_reason := 'this kind is not turned on yet (Stephen turns each kind on)';
  end if;
  insert into mirror.notifications (recipient_email, individual_id, kind, ref, status, reason, outbox_id)
  values (v_email, i.id, p_kind, v_ref, v_status, v_reason, v_out);
  return v_status;
end $$;

-- The admin page: each kind, its words (normal and safety mode), on or off, counts for 30 days.
create or replace function public.mirror_admin_email_kinds() returns jsonb
language plpgsql stable security definer set search_path = mirror, public as $$
declare v_on text[] := string_to_array(replace(coalesce(public.condo_setting('mirror_email_kinds_enabled', ''), ''), ' ', ''), ',');
        v_sample jsonb := '{"first_name":"Alex","organization":"Example Organization","when":"Tuesday, December 1 at 10:00 AM","reason":"a new authenticator app was set up"}';
begin
  if not coalesce(mirror.is_platform_admin(), false) then raise exception '2nd Chance platform admins only (with your authenticator code).' using errcode = '42501'; end if;
  return jsonb_build_object(
    'can_switch', exists (select 1 from public.portal_admins where lower(email) = lower(auth.email())),
    'kinds', (select jsonb_agg(k || jsonb_build_object('enabled', (k ->> 'kind') = any (coalesce(v_on, '{}')),
        'preview', mirror.email_html(k ->> 'kind', v_sample),
        'preview_safety', case when k ->> 'kind' in ('mirror_invite', 'mirror_security') then mirror.email_html(k ->> 'kind', v_sample || '{"safety":true}') end,
        'held', (select count(*) from mirror.notifications n where n.kind = k ->> 'kind' and n.status = 'held' and n.created_at > now() - interval '30 days'),
        'queued', (select count(*) from mirror.notifications n where n.kind = k ->> 'kind' and n.status = 'queued' and n.created_at > now() - interval '30 days'),
        'skipped', (select count(*) from mirror.notifications n where n.kind = k ->> 'kind' and n.status = 'skipped' and n.created_at > now() - interval '30 days')))
      from jsonb_array_elements(mirror.email_kinds()) k));
end $$;

-- Turn one kind on or off: the 2nd Chance main admin only (portal_admins, with the authenticator code). Logged.
create or replace function public.mirror_admin_email_kind_set(p_kind text, p_enabled boolean) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v_on text[] := coalesce(string_to_array(replace(coalesce(public.condo_setting('mirror_email_kinds_enabled', ''), ''), ' ', ''), ','), '{}');
begin
  if not coalesce(mirror.is_platform_admin(), false) or not exists (select 1 from public.portal_admins where lower(email) = lower(auth.email())) then
    raise exception 'Only the 2nd Chance main admin turns an email kind on or off.' using errcode = '42501';
  end if;
  if not exists (select 1 from jsonb_array_elements(mirror.email_kinds()) k where k ->> 'kind' = p_kind) then raise exception 'Unknown email kind.' using errcode = '22023'; end if;
  v_on := array_remove(v_on, p_kind); v_on := array_remove(v_on, '');
  if coalesce(p_enabled, false) then v_on := v_on || p_kind; end if;
  update public.portal_settings set value = array_to_string(v_on, ',') where key = 'mirror_email_kinds_enabled';
  perform mirror.audit(null, null, 'platform_admin', 'edit', 'organization', 'portal_settings', 'mirror_email_kinds_enabled',
                       p_kind || case when coalesce(p_enabled, false) then ' turned on' else ' turned off' end);
  return public.mirror_admin_email_kinds();
end $$;

revoke all on function mirror.email_kinds(), mirror.email_html(text, jsonb), mirror.email_queue(text, text, jsonb, uuid) from public, anon, authenticated;
grant execute on function mirror.email_kinds(), mirror.email_html(text, jsonb), mirror.email_queue(text, text, jsonb, uuid) to service_role;
revoke all on function public.mirror_admin_email_kinds(), public.mirror_admin_email_kind_set(text, boolean) from public, anon;
grant execute on function public.mirror_admin_email_kinds(), public.mirror_admin_email_kind_set(text, boolean) to authenticated, service_role;
