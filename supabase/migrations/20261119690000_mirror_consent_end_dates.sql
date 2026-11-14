-- The Human Mirror Phase 9, handoff step 26: P2-12 an end date for sharing, with a reminder before it ends.
-- mirror.consents.expires_on existed and mirror.allowed already stops a share after it (since T2.2), but nobody could set it. Now:
--   * the person sets or clears an end date per organization and topic in Settings (mirror_my_consent_until);
--   * a coordinator records the end date a person without a sign-in gave them (mirror_consent_record_until), like the choice itself;
--   * changing how much is shared keeps the end date (mirror_my_consent_set and mirror_consent_record carry it over);
--   * Settings and the coordinator's "What they share" show the end date (mirror_my_settings, mirror_consents_recorded);
--   * 7 days before, the person gets "Sharing ending soon" (new email kind mirror_sharing, through mirror.email_queue, sent by the daily
--     mirror-reminders job). Like every kind it is OFF until Stephen turns it on (D-42). In safety mode it says only "2nd Chance Housing".
-- End dates: from tomorrow up to 5 years ahead. On the day after the end date the share simply stops (mirror.allowed, unchanged).
-- No new table. Functions below that already existed are copied from their live bodies; only the marked lines are new.

-- ---------------------------------------------------------------- the new email kind
alter table mirror.notifications drop constraint notifications_kind_check;
alter table mirror.notifications add constraint notifications_kind_check check (kind in ('mirror_invite', 'mirror_staff_invite', 'mirror_referral',
  'mirror_appointment', 'mirror_action', 'mirror_security', 'mirror_sharing'));

create or replace function mirror.email_kinds() returns jsonb language sql immutable as $$
  select '[{"kind":"mirror_invite","label":"Invitation to a person","choice":null},
           {"kind":"mirror_staff_invite","label":"Invitation to an organization member","choice":null},
           {"kind":"mirror_referral","label":"Updates on referrals","choice":"referral"},
           {"kind":"mirror_appointment","label":"Appointment reminders","choice":"appointment"},
           {"kind":"mirror_action","label":"Reminders about the plan","choice":"action"},
           {"kind":"mirror_sharing","label":"Sharing ending soon (sent to the person)","choice":null},
           {"kind":"mirror_security","label":"Security notices (always sent)","choice":null}]'::jsonb;
$$;

-- mirror.email_html: live body (20261119660000); NEW: the mirror_sharing words.
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
    when 'mirror_sharing' then                                                   -- NEW (P2-12)
      if v_safe then
        v_subject := '2nd Chance Housing: a choice you made ends soon';
        v_body := '<p>A choice you made in your 2nd Chance Housing account ends' || coalesce(' on ' || v_when, ' soon') || '. Sign in to see it or change it.</p>' || v_btn;
      else
        v_subject := 'What you share with ' || v_org || ' ends' || coalesce(' on ' || v_when, ' soon');
        v_body := '<p>As you chose, ' || v_org || ' will stop seeing some of what you share in your Human Mirror' || coalesce(' after ' || v_when, ' soon')
          || '. To keep sharing, sign in and change the end date in your Settings. To let it end, do nothing.</p>' || v_btn;
      end if;
    else raise exception 'Unknown Mirror email kind: %', p_kind using errcode = '22023';
  end case;
  return jsonb_build_object('subject', v_subject,
    'html', '<div style="font-family:Arial,sans-serif;max-width:600px;color:#1b2430"><p>Hi ' || v_first || ',</p>' || v_body
         || '<p>2nd Chance Housing</p><p style="color:#667;font-size:12px">You get this because of your account with 2nd Chance Housing Inc. '
         || case when p_kind in ('mirror_referral', 'mirror_appointment', 'mirror_action') then 'You can turn these emails off in your Settings after you sign in.' else '' end
         || '</p></div>');
end $$;

-- mirror.send_reminders: live body (20261119680000); NEW: the sharing-ends-soon loop. The mirror-reminders job is unchanged.
create or replace function mirror.send_reminders() returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare x record; s text; v_held int := 0; v_queued int := 0; v_skipped int := 0; v_tomorrow date := current_date + 1;
begin
  for x in
    select a.id, a.starts_at, i.id as ind, i.auth_email, i.preferred_name
      from mirror.appointments a join mirror.individuals i on i.id = a.individual_id
     where a.status = 'scheduled' and a.starts_at::date = v_tomorrow and i.auth_email is not null
  loop
    s := mirror.email_queue(x.auth_email, 'mirror_appointment',
      jsonb_build_object('first_name', x.preferred_name, 'when', trim(to_char(x.starts_at, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM')),
                         'ref', 'appt:' || x.id || ':' || to_char(x.starts_at, 'YYYY-MM-DD"T"HH24:MI')), x.ind);
    v_held := v_held + (s = 'held')::int; v_queued := v_queued + (s = 'queued')::int; v_skipped := v_skipped + (s = 'skipped')::int;
  end loop;
  for x in
    select t.id, t.due_on, i.id as ind, i.auth_email, i.preferred_name
      from mirror.action_items t join mirror.individuals i on i.id = t.individual_id
     where t.status = 'open' and t.due_on = v_tomorrow and i.auth_email is not null
  loop
    s := mirror.email_queue(x.auth_email, 'mirror_action',
      jsonb_build_object('first_name', x.preferred_name, 'when', 'due ' || trim(to_char(x.due_on, 'FMDay, FMMonth FMDD')),
                         'ref', 'action:' || x.id || ':' || x.due_on), x.ind);
    v_held := v_held + (s = 'held')::int; v_queued := v_queued + (s = 'queued')::int; v_skipped := v_skipped + (s = 'skipped')::int;
  end loop;
  -- NEW (P2-12): 7 days before a share ends, one email per person and organization.
  for x in
    select c.individual_id as ind, c.organization_id as org, c.expires_on, i.auth_email, i.preferred_name, o.name as org_name
      from mirror.consents c join mirror.individuals i on i.id = c.individual_id join mirror.organizations o on o.id = c.organization_id
     where c.revoked_at is null and c.expires_on = current_date + 7 and i.auth_email is not null
     group by c.individual_id, c.organization_id, c.expires_on, i.auth_email, i.preferred_name, o.name
  loop
    s := mirror.email_queue(x.auth_email, 'mirror_sharing',
      jsonb_build_object('first_name', x.preferred_name, 'organization', x.org_name, 'when', trim(to_char(x.expires_on, 'FMDay, FMMonth FMDD')),
                         'ref', 'share:' || x.ind || ':' || x.org || ':' || x.expires_on), x.ind);
    v_held := v_held + (s = 'held')::int; v_queued := v_queued + (s = 'queued')::int; v_skipped := v_skipped + (s = 'skipped')::int;
  end loop;
  return jsonb_build_object('held', v_held, 'queued', v_queued, 'skipped', v_skipped);
end $$;


-- ---------------------------------------------------------------- end dates
-- The active share's end date, or null (helper).
create or replace function mirror.consent_until_check(p_until date) returns void
language plpgsql stable set search_path = mirror, public set timezone = 'America/Chicago' as $$
begin
  if p_until is not null and (p_until <= current_date or p_until > current_date + interval '5 years') then
    raise exception 'Choose an end date from tomorrow up to 5 years from now, or no end date.' using errcode = '22023';
  end if;
end $$;

-- The person: set or clear the end date of what they share with one organization on one topic.
create or replace function public.mirror_my_consent_until(p_org uuid, p_category text, p_until date) returns void
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v uuid := mirror.me(); n int;
begin
  if v is null then raise exception 'Sign in to your own Mirror first.' using errcode = '42501'; end if;
  perform mirror.consent_until_check(p_until);
  update mirror.consents set expires_on = p_until
   where individual_id = v and organization_id = p_org and category = p_category and revoked_at is null
     and (expires_on is null or expires_on >= current_date);
  get diagnostics n = row_count;
  if n = 0 then raise exception 'You are not sharing that topic with that organization.' using errcode = '22023'; end if;
  perform mirror.audit(v, p_org, 'self', 'consent_until', p_category, 'consents', coalesce(p_until::text, 'no end date'));
end $$;

-- A coordinator records the end date a person without a sign-in gave them (same rules as mirror_consent_record).
create or replace function public.mirror_consent_record_until(p_individual uuid, p_org uuid, p_category text, p_until date) returns jsonb
language plpgsql security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare n int;
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals where organization_id = p_org and individual_id = p_individual and status = 'active') then
    raise exception 'This person is not actively working with your organization.' using errcode = '42501';
  end if;
  if exists (select 1 from mirror.individuals where id = p_individual and auth_email is not null) then
    raise exception 'This person can sign in, so they choose for themselves in their own Settings.' using errcode = '42501';
  end if;
  perform mirror.consent_until_check(p_until);
  update mirror.consents set expires_on = p_until
   where individual_id = p_individual and organization_id = p_org and category = p_category and revoked_at is null
     and (expires_on is null or expires_on >= current_date);
  get diagnostics n = row_count;
  if n = 0 then raise exception 'They are not sharing that topic with your organization.' using errcode = '22023'; end if;
  perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'consent_until', p_category, 'consents', coalesce(p_until::text, 'no end date'));
  return public.mirror_consents_recorded(p_individual, p_org);
end $$;

-- mirror_my_consent_set: live body; NEW: the end date of the share being replaced is kept.
create or replace function public.mirror_my_consent_set(p_org uuid, p_category text, p_access text) returns void
language plpgsql security definer set search_path = mirror, public as $$
declare v uuid := mirror.me(); had int; v_until date;
begin
  if p_category not in ('general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial', 'documents') then
    raise exception 'Unknown topic.' using errcode = '22023';
  end if;
  if p_access not in ('none', 'view', 'edit') then raise exception 'Unknown choice.' using errcode = '22023'; end if;
  if not exists (select 1 from mirror.organization_individuals where individual_id = v and organization_id = p_org and status <> 'ended') then
    raise exception 'You are not working with that organization.' using errcode = '42501';
  end if;
  select expires_on into v_until from mirror.consents                                                   -- NEW
   where individual_id = v and organization_id = p_org and category = p_category and revoked_at is null
     and expires_on >= (now() at time zone 'America/Chicago')::date order by granted_at desc limit 1;
  update mirror.consents set revoked_at = now(), revoked_by = lower(auth.email())
   where individual_id = v and organization_id = p_org and category = p_category and revoked_at is null;
  get diagnostics had = row_count;
  if p_access <> 'none' then
    insert into mirror.consents (individual_id, organization_id, category, access, granted_by, expires_on) values (v, p_org, p_category, p_access, lower(auth.email()), v_until);
    perform mirror.audit(v, p_org, 'self', 'consent_grant', p_category, 'consents', p_access);
  elsif had > 0 then
    perform mirror.audit(v, p_org, 'self', 'consent_revoke', p_category, 'consents', null);
  end if;
end $$;

-- mirror_consent_record: live body; NEW: the end date of the share being replaced is kept.
create or replace function public.mirror_consent_record(p_individual uuid, p_org uuid, p_category text, p_access text, p_method text, p_note text) returns jsonb
language plpgsql security definer set search_path = mirror, public as $$
declare v_had int; v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_until date;
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals where organization_id = p_org and individual_id = p_individual and status = 'active') then
    raise exception 'This person is not actively working with your organization.' using errcode = '42501';
  end if;
  if exists (select 1 from mirror.individuals where id = p_individual and auth_email is not null) then
    raise exception 'This person can sign in, so they choose for themselves in their own Settings.' using errcode = '42501';
  end if;
  if p_category not in ('general', 'health', 'mental_health', 'safety', 'legal', 'immigration', 'financial', 'documents') then
    raise exception 'Unknown topic.' using errcode = '22023';
  end if;
  if p_access not in ('none', 'view', 'edit') then raise exception 'Unknown choice.' using errcode = '22023'; end if;
  if p_method not in ('paper', 'spoken') then raise exception 'Say how the person agreed: on paper or out loud.' using errcode = '22023'; end if;
  if v_note is null or length(v_note) < 5 then
    raise exception 'Add a short note, for example where the signed form is kept or who was there.' using errcode = '22023';
  end if;
  select expires_on into v_until from mirror.consents                                                   -- NEW
   where individual_id = p_individual and organization_id = p_org and category = p_category and revoked_at is null
     and expires_on >= (now() at time zone 'America/Chicago')::date order by granted_at desc limit 1;
  update mirror.consents set revoked_at = now(), revoked_by = lower(auth.email())
   where individual_id = p_individual and organization_id = p_org and category = p_category and revoked_at is null;
  get diagnostics v_had = row_count;
  if p_access <> 'none' then
    insert into mirror.consents (individual_id, organization_id, category, access, granted_by, method, note, expires_on)
    values (p_individual, p_org, p_category, p_access, lower(auth.email()), p_method, v_note, v_until);
    perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'consent_grant', p_category, 'consents', p_method || ':' || p_access);
  elsif v_had > 0 then
    perform mirror.audit(p_individual, p_org, mirror.my_role(p_org), 'consent_revoke', p_category, 'consents', p_method);
  end if;
  return public.mirror_consents_recorded(p_individual, p_org);
end $$;

-- mirror_my_settings: live body; NEW: 'sharing_until' (topic -> end date) per organization.
create or replace function public.mirror_my_settings() returns jsonb
language plpgsql stable security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
declare v uuid := mirror.me();
begin
  return jsonb_build_object(
    'person', (select jsonb_build_object('preferred_name', i.preferred_name, 'legal_name', i.legal_name, 'birth_year', i.birth_year,
        'email', i.auth_email, 'safety_sensitive', i.safety_sensitive, 'deletion_requested_at', i.deletion_requested_at,
        'deletion_on', (i.deletion_requested_at + interval '30 days')::date)
      from mirror.individuals i where i.id = v),
    'organizations', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'name', o.name, 'kind', o.kind, 'status', oi.status, 'started_on', oi.started_on,
        'coordinator', (select m.name from mirror.organization_members m where m.id = oi.primary_member_id),
        'sharing', coalesce((select jsonb_object_agg(c.category, c.access) from mirror.consents c
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null
              and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb),
        'sharing_until', coalesce((select jsonb_object_agg(c.category, c.expires_on) from mirror.consents c          -- NEW
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null and c.expires_on >= current_date), '{}'::jsonb),
        'sharing_detail', coalesce((select jsonb_object_agg(c.category, jsonb_build_object('method', c.method, 'at', c.granted_at,
            'by', coalesce((select m.name from mirror.organization_members m where m.organization_id = o.id and m.auth_email = c.granted_by), 'you'))) from mirror.consents c
            where c.individual_id = v and c.organization_id = o.id and c.revoked_at is null and c.method <> 'online'
              and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb))
        order by (oi.status = 'ended'), o.name)
      from mirror.organization_individuals oi join mirror.organizations o on o.id = oi.organization_id
      where oi.individual_id = v), '[]'::jsonb));
end $$;

-- mirror_consents_recorded: live body; NEW: 'until' on each share.
create or replace function public.mirror_consents_recorded(p_individual uuid, p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = mirror, public set timezone = 'America/Chicago' as $$
begin
  if not mirror.coordinates(p_org) then raise exception 'Coordinators of this organization only (with your authenticator code).' using errcode = '42501'; end if;
  if not exists (select 1 from mirror.organization_individuals where organization_id = p_org and individual_id = p_individual and status = 'active') then
    raise exception 'This person is not actively working with your organization.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'can_record', (select auth_email is null from mirror.individuals where id = p_individual),
    'sharing', coalesce((select jsonb_object_agg(c.category, jsonb_build_object('access', c.access, 'method', c.method, 'note', c.note, 'at', c.granted_at,
        'until', c.expires_on,                                                                                    -- NEW
        'by', coalesce((select m.name from mirror.organization_members m where m.organization_id = p_org and m.auth_email = c.granted_by), c.granted_by)))
      from mirror.consents c where c.individual_id = p_individual and c.organization_id = p_org and c.revoked_at is null
        and (c.expires_on is null or c.expires_on >= current_date)), '{}'::jsonb));
end $$;

revoke all on function mirror.consent_until_check(date) from public, anon, authenticated;
revoke all on function public.mirror_my_consent_until(uuid, text, date), public.mirror_consent_record_until(uuid, uuid, text, date) from public, anon;
grant execute on function public.mirror_my_consent_until(uuid, text, date), public.mirror_consent_record_until(uuid, uuid, text, date) to authenticated, service_role;
