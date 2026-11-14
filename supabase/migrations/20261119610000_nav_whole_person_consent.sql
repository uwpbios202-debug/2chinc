-- The Human Mirror Phase N, handoff step 18: TN.1 whole-person consent for Navigator people (closes NAVIGATOR.md gap N2).
-- Until now a Navigator person signs one housing-only consent ("only to help me find and keep a home", version nav-consent-2026-11).
-- That consent, and every one already signed, stays exactly as it is (history unchanged). Added beside it:
--   * "Sharing beyond housing": on the Navigator's screen, after the housing consent, the person chooses for each private topic of the
--     Mirror (the 7 sensitive categories of mirror.consents: health, mental_health, safety, legal, immigration, financial, documents)
--     "not shared", "can see" or "can see and change", reads the exact words, and types their own full name (must match the name on file).
--     Kept in nav_whole_consents with the words and the date; a new signing replaces the old one (the old one stays, marked replaced).
--   * Withdrawing the housing consent (nav_referral_withdraw_consent, unchanged) also ends this one (trigger), so nothing outlives it.
--   * mirror.nav_whole_consent_to_mirror(nav person, Mirror individual): copies the current choices into mirror.consents for the
--     Navigator's own Mirror organization (D-20). It is called by TN.2 when a Navigator person becomes a Mirror individual; until then the
--     choices are only recorded. "General" (identity, goals, strengths) needs no consent in the Mirror: an organization working with the
--     person sees it by default (SECURITY_PLAN 1.4), and the words say so.
-- No email is sent. New table carries explicit grants (CLAUDE.md, 10/30/2026): service_role only; authenticated and anon none.

create table public.nav_whole_consents (
  id uuid primary key default gen_random_uuid(),
  nav_referral_id uuid not null references public.nav_referrals(id) on delete cascade,
  topics jsonb not null check (jsonb_typeof(topics) = 'object'),
  consent_name text not null check (length(consent_name) between 2 and 200),
  consent_text text not null,
  version text not null default 'nav-whole-2026-11',
  recorded_by text not null,
  recorded_role text not null,
  signed_at timestamptz not null default now(),
  replaced_at timestamptz,
  withdrawn_on date
);
create unique index nav_whole_consents_current on public.nav_whole_consents (nav_referral_id) where replaced_at is null;
alter table public.nav_whole_consents enable row level security;
revoke all on public.nav_whole_consents from public, anon, authenticated, service_role;
grant select, insert, update, delete on public.nav_whole_consents to service_role;

-- The 7 topics, in the Mirror's words for the person.
create or replace function public.nav_whole_topics() returns jsonb
language sql immutable as $$
  select '[{"key":"health","label":"Physical health","mine":"my physical health"},
           {"key":"mental_health","label":"How they feel inside","mine":"how I feel inside"},
           {"key":"safety","label":"Safety","mine":"my safety"},
           {"key":"legal","label":"ID, papers and legal matters","mine":"my ID, papers and legal matters"},
           {"key":"immigration","label":"Immigration","mine":"my immigration matters"},
           {"key":"financial","label":"Money and the Daily Number","mine":"my money and my Daily Number"},
           {"key":"documents","label":"Documents","mine":"my documents"}]'::jsonb;
$$;

-- Who receives the sharing: the Navigator and their business.
create or replace function public.nav_whole_receiver(r public.nav_referrals) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select 'my Housing Navigator, ' || n.name || coalesce(' (' || nullif(trim(n.business_name), '') || ')', '') from navigators n where n.id = r.navigator_id),
                  'my Housing Navigator');
$$;

-- The exact words the person agrees to (the page shows the same sentence before they type their name).
create or replace function public.nav_whole_words(r public.nav_referrals, p_topics jsonb) returns text
language sql stable security definer set search_path = public as $$
  with t as (select x ->> 'mine' as mine, p_topics ->> (x ->> 'key') as a, ord from jsonb_array_elements(nav_whole_topics()) with ordinality e(x, ord))
  select 'Beyond housing, I agree that ' || nav_whole_receiver(r) || ' may work with me on my Human Mirror and see '
      || coalesce((select string_agg(mine || case when a = 'edit' then ' (see and change)' else ' (see)' end, ', ' order by ord) from t where a in ('view', 'edit')),
                  'none of my private topics')
      || '. Everything else private stays private: '
      || coalesce((select string_agg(mine, ', ' order by ord) from t where coalesce(a, 'none') not in ('view', 'edit')), 'nothing')
      || '. My name, my goals and my strengths are seen by an organization I work with. I can change or stop this at any time by telling my Navigator'
      || ' or the office (info@2ndchinc.org), and stopping my housing consent stops this too.';
$$;

-- What the Navigator's screen shows for one person.
create or replace function public.nav_whole_consent(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r nav_referrals; c nav_whole_consents;
begin
  if not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  select * into r from nav_referrals where id = p_id;
  select * into c from nav_whole_consents where nav_referral_id = p_id and replaced_at is null;
  return jsonb_build_object(
    'topics', nav_whole_topics(),
    'receiver', nav_whole_receiver(r),
    'full_name', trim(r.first_name || ' ' || coalesce(r.last_name, '')),
    'can_record', r.consent_on is not null and r.consent_withdrawn_on is null and r.status <> 'closed',
    'current', case when c.id is null then null else jsonb_build_object('topics', c.topics, 'signed_by', c.consent_name, 'signed_at', c.signed_at,
                 'words', c.consent_text, 'withdrawn_on', c.withdrawn_on) end);
end $$;

-- The person's choice, typed by them on the Navigator's screen.
create or replace function public.nav_whole_consent_save(p_id uuid, p_topics jsonb, p_consent_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r nav_referrals; v_role text := nav_actor_role(); v_topics jsonb := '{}'::jsonb; k text; a text; v_words text; v_full text;
begin
  if v_role is null or not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  select * into r from nav_referrals where id = p_id;
  if r.consent_on is null or r.consent_withdrawn_on is not null or r.status = 'closed' then
    raise exception 'First the person signs the housing consent (Edit details). Sharing beyond housing comes after it.';
  end if;
  for k in select x ->> 'key' from jsonb_array_elements(nav_whole_topics()) x loop
    a := coalesce(p_topics ->> k, 'none');
    if a not in ('none', 'view', 'edit') then raise exception 'Choose not shared, can see, or can see and change for each topic.' using errcode = '22023'; end if;
    v_topics := v_topics || jsonb_build_object(k, a);
  end loop;
  v_full := trim(r.first_name || ' ' || coalesce(r.last_name, ''));
  if lower(regexp_replace(trim(coalesce(p_consent_name, '')), '\s+', ' ', 'g')) <> lower(regexp_replace(v_full, '\s+', ' ', 'g')) then
    raise exception 'The person types their own full name, as on file: %.', v_full using errcode = '22023';
  end if;
  v_words := nav_whole_words(r, v_topics);
  update nav_whole_consents set replaced_at = now() where nav_referral_id = p_id and replaced_at is null;
  insert into nav_whole_consents (nav_referral_id, topics, consent_name, consent_text, recorded_by, recorded_role)
  values (p_id, v_topics, trim(p_consent_name), v_words, lower(auth.email()), v_role);
  perform nav_log('whole_consent', 'Sharing beyond housing signed by ' || trim(p_consent_name) || ': '
    || coalesce((select string_agg(x ->> 'label' || case when v_topics ->> (x ->> 'key') = 'edit' then ' (see and change)' else ' (see)' end, ', ')
                 from jsonb_array_elements(nav_whole_topics()) x where v_topics ->> (x ->> 'key') in ('view', 'edit')), 'no private topics'), p_id);
  return nav_whole_consent(p_id);
end $$;

-- Withdrawing the housing consent ends this one too.
create or replace function public.nav_whole_consent_follow_withdraw() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.consent_withdrawn_on is not null and old.consent_withdrawn_on is null then
    update nav_whole_consents set withdrawn_on = new.consent_withdrawn_on where nav_referral_id = new.id and withdrawn_on is null;
  end if;
  return new;
end $$;
create trigger nav_referrals_whole_consent_withdraw after update of consent_withdrawn_on on public.nav_referrals
  for each row execute function public.nav_whole_consent_follow_withdraw();

-- For TN.2: copy the person's current choices into the Mirror, for the Navigator's own organization. Returns how many topics are shared.
create or replace function mirror.nav_whole_consent_to_mirror(p_nav uuid, p_individual uuid) returns int
language plpgsql security definer set search_path = mirror, public as $$
declare r public.nav_referrals; c public.nav_whole_consents; v_org uuid; k text; a text; n int := 0;
begin
  select * into r from public.nav_referrals where id = p_nav;
  select * into c from public.nav_whole_consents where nav_referral_id = p_nav and replaced_at is null and withdrawn_on is null;
  if r.id is null or c.id is null or r.consent_withdrawn_on is not null then return 0; end if;
  select id into v_org from mirror.organizations where navigator_id = r.navigator_id and kind = 'navigator' and active order by created_at limit 1;
  if v_org is null then return 0; end if;
  for k, a in select key, value #>> '{}' from jsonb_each(c.topics) loop
    update mirror.consents set revoked_at = now(), revoked_by = c.recorded_by
     where individual_id = p_individual and organization_id = v_org and category = k and revoked_at is null;
    if a in ('view', 'edit') then
      insert into mirror.consents (individual_id, organization_id, category, access, granted_by, method, note)
      values (p_individual, v_org, k, a, c.recorded_by, 'online',
              left('Typed by the person on their Navigator''s screen on ' || to_char(c.signed_at at time zone 'America/Chicago', 'MM/DD/YYYY')
                   || ' (sharing beyond housing, ' || c.version || ').', 500));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

revoke all on function public.nav_whole_topics(), public.nav_whole_receiver(public.nav_referrals), public.nav_whole_words(public.nav_referrals, jsonb),
  public.nav_whole_consent_follow_withdraw(), mirror.nav_whole_consent_to_mirror(uuid, uuid) from public, anon, authenticated;
grant execute on function public.nav_whole_topics(), public.nav_whole_receiver(public.nav_referrals), public.nav_whole_words(public.nav_referrals, jsonb),
  mirror.nav_whole_consent_to_mirror(uuid, uuid) to service_role;
revoke all on function public.nav_whole_consent(uuid), public.nav_whole_consent_save(uuid, jsonb, text) from public, anon;
grant execute on function public.nav_whole_consent(uuid), public.nav_whole_consent_save(uuid, jsonb, text) to authenticated, service_role;
