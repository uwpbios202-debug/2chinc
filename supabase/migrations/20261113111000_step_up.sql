-- Quick re-check before sensitive actions (Stephen, 10/18/2026). Even on a remembered device, changing an email or phone number
-- needs a fresh 6-digit code emailed to the address on file, entered within the last 30 minutes. The code is checked by the
-- step-up edge function, which records the check against THIS sign-in (session) only; a new device or a new sign-in must do it again.
create table if not exists step_up_codes (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  code_hash text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes',
  attempts int not null default 0,
  used_at timestamptz
);
create index if not exists step_up_codes_user_idx on step_up_codes (user_id, created_at desc);
alter table step_up_codes enable row level security;   -- service role only

create table if not exists session_stepups (
  session_id uuid primary key,
  user_id uuid not null,
  verified_at timestamptz not null default now()
);
alter table session_stepups enable row level security;   -- service role only

insert into portal_settings (key, value) values ('step_up_minutes', '30') on conflict (key) do nothing;

-- True when this sign-in passed the re-check recently.
create or replace function step_up_ok()
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_sid uuid;
begin
  if auth.uid() is null then return false; end if;
  begin v_sid := (auth.jwt() ->> 'session_id')::uuid; exception when others then return false; end;
  if v_sid is null then return false; end if;
  return exists (select 1 from session_stepups where session_id = v_sid and user_id = auth.uid()
                  and verified_at > now() - make_interval(mins => coalesce(nullif(condo_setting('step_up_minutes', '30'), '')::int, 30)));
end;
$$;
revoke all on function step_up_ok() from public, anon;
grant execute on function step_up_ok() to authenticated;

create or replace function step_up_require()
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not step_up_ok() then raise exception 'STEP_UP_REQUIRED' using errcode = 'P0001'; end if;
end;
$$;
revoke all on function step_up_require() from public, anon;
grant execute on function step_up_require() to authenticated;

create or replace function resident_contact_change(p_field text, p_new text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare t tenants; v_new text := trim(coalesce(p_new, ''));
begin
  perform resident_require_current();
  perform step_up_require();   -- a fresh emailed code first (this changes a sign-in factor)
  select * into t from tenants where id in (select resident_me()) order by created_at limit 1;
  if t.id is null then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if p_field = 'phone' then
    if length(regexp_replace(v_new, '\D', '', 'g')) <> 10 then raise exception 'Enter a 10-digit mobile number, like (414) 555-0123.'; end if;
    if regexp_replace(v_new, '\D', '', 'g') = regexp_replace(coalesce(t.phone, ''), '\D', '', 'g') then raise exception 'That''s already your number.'; end if;
  elsif p_field = 'email' then
    v_new := lower(v_new);
    if v_new !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then raise exception 'Enter a valid email address.'; end if;
    if v_new = lower(coalesce(t.email, '')) then raise exception 'That''s already your email.'; end if;
  else raise exception 'Unknown field';
  end if;
  update tenant_contact_changes set status = 'declined', note = 'Replaced by a newer request', decided_at = now()
  where status = 'pending' and field = p_field and lower(requested_by) = lower(auth.email());
  insert into tenant_contact_changes (requested_by, field, old_value, new_value)
  values (lower(auth.email()), p_field, case when p_field = 'phone' then t.phone else t.email end, v_new);
  insert into email_outbox (to_email, subject, html, kind) select value, 'Contact change to confirm — ' || t.name,
    '<p>' || repair_esc(t.name) || ' asked to change their ' || case when p_field = 'phone' then 'mobile number' else 'email' end ||
    ' from <b>' || repair_esc(coalesce(case when p_field = 'phone' then t.phone else t.email end, '—')) || '</b> to <b>' || repair_esc(v_new) ||
    '</b>. It is also a sign-in factor, so call the tenant at a number you already have to confirm, then approve it on the Messages page.</p>', 'contact_change'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function resident_contact_change(text, text) from public, anon;
grant execute on function resident_contact_change(text, text) to authenticated;

-- Owners: changing the email or the mobile number (a sign-in factor) needs the re-check first. Everything else is unchanged.
create or replace function condo_update_my_profile(p_changes jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_diff jsonb;
  v_name text;
  v_email text;
  v_update uuid;
begin
  if not condo_session_ok() then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  if exists (select 1 from condo_owners o where o.id = v_owner and (
       (p_changes ? 'email' and lower(coalesce(p_changes ->> 'email', '')) is distinct from lower(coalesce(o.email, '')))
    or (p_changes ? 'alt_email' and lower(coalesce(p_changes ->> 'alt_email', '')) is distinct from lower(coalesce(o.alt_email, '')))
    or (p_changes ? 'phone_mobile' and regexp_replace(coalesce(p_changes ->> 'phone_mobile', ''), '\D', '', 'g') is distinct from regexp_replace(coalesce(o.phone_mobile, ''), '\D', '', 'g')))) then
    perform step_up_require();
  end if;
  if jsonb_typeof(p_changes) <> 'object' then raise exception 'Expected an object' using errcode = '22023'; end if;
  if nullif(btrim(p_changes ->> 'phone_mobile'), '') is not null
     and length(regexp_replace(p_changes ->> 'phone_mobile', '\D', '', 'g')) < 10 then
    raise exception 'Mobile phone needs all 10 digits — it is where your sign-in codes are texted' using errcode = '22023';
  end if;
  v_diff := condo_apply_owner_changes(v_owner, p_changes, condo_owner_editable_fields());
  update condo_owners
    set last_confirmed_at = now(),
        last_confirmed_how = case when jsonb_array_length(v_diff) > 0 then 'updated' else 'nothing_changed' end,
        reminders_sent_in_cycle = 0
    where id = v_owner
    returning name, email into v_name, v_email;
  insert into condo_profile_updates (owner_id, owner_name, owner_email, unit_label, kind, via, changes)
    values (v_owner, v_name, v_email, condo_unit_label(v_owner),
            case when jsonb_array_length(v_diff) > 0 then 'updated' else 'nothing_changed' end, 'portal', v_diff)
    returning id into v_update;
  return jsonb_build_object('changed', jsonb_array_length(v_diff), 'confirmed_at', now(), 'update_id', v_update);
end;
$$;
revoke all on function condo_update_my_profile(jsonb) from public, anon;
grant execute on function condo_update_my_profile(jsonb) to authenticated;
