-- Staff write an email to a unit's owner and/or tenants from https://2ndchinc.org/staff/email/ (Stephen, 10/13/2026).
-- It is queued in email_outbox (kind 'staff_message'), sent right away by outbox-flush, and so it shows in the person's
-- Communications history. Unit 6 never gets tenant mail (owner-direct, see CLAUDE.md).

create or replace function staff_mail_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select condo_session_ok() and (condo_is_staff() or exists (select 1 from portal_admins where lower(email) = lower(auth.email())));
$$;
revoke all on function staff_mail_ok() from public, anon;
grant execute on function staff_mail_ok() to authenticated;

-- Units with who would receive mail (names only, never addresses).
create or replace function staff_mail_targets()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_mail_ok() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('unit', cu.unit_number, 'address', cu.address,
      'owners', (select coalesce(jsonb_agg(o.name order by o.name), '[]'::jsonb) from condo_ownerships s join condo_owners o on o.id = s.owner_id
                 where s.unit_id = cu.id and s.is_current and coalesce(o.email, '') <> ''),
      'tenants', case when cu.unit_number = '6' then '[]'::jsonb else
                 (select coalesce(jsonb_agg(distinct t.name), '[]'::jsonb) from rental_units ru join leases l on l.unit_id = ru.id and l.status in ('active', 'future')
                  join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id
                  where ru.condo_unit_id = cu.id and coalesce(t.email, '') <> '') end)
    order by nullif(regexp_replace(cu.unit_number, '\D', '', 'g'), '')::int) from condo_units cu), '[]'::jsonb);
end $$;
revoke all on function staff_mail_targets() from public, anon;
grant execute on function staff_mail_targets() to authenticated;

-- p_who: 'owner' | 'tenant' | 'both'. Returns who it was queued for (names).
create or replace function staff_email_unit(p_unit text, p_who text, p_subject text, p_message text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_html text; r record; v_names text[] := '{}'; v_cu uuid;
begin
  if not staff_mail_ok() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_who not in ('owner', 'tenant', 'both') then raise exception 'Choose who gets the email.'; end if;
  if length(trim(coalesce(p_subject, ''))) < 3 then raise exception 'Add a subject.'; end if;
  if length(trim(coalesce(p_message, ''))) < 3 then raise exception 'Write the message.'; end if;
  if length(p_subject) > 150 or length(p_message) > 8000 then raise exception 'That is too long.'; end if;
  select id into v_cu from condo_units where unit_number = p_unit;
  if v_cu is null then raise exception 'Unknown unit.'; end if;
  if p_unit = '6' and p_who in ('tenant', 'both') then raise exception 'Unit 6 is managed by its owner: email the owner only.'; end if;

  v_html := '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p style="white-space:pre-wrap">'
    || replace(replace(replace(trim(p_message), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
    || '</p><p style="color:#5b6573;font-size:13px">2nd Chance Housing · Royal Orleans Condominium, Unit ' || p_unit
    || '. Reply to this email to reach the office.</p></div>';

  for r in
    select distinct on (lower(e)) e, nm from (
      select o.email e, o.name nm from condo_ownerships s join condo_owners o on o.id = s.owner_id
        where p_who in ('owner', 'both') and s.unit_id = v_cu and s.is_current and coalesce(o.email, '') <> ''
      union all
      select t.email, t.name from rental_units ru join leases l on l.unit_id = ru.id and l.status in ('active', 'future')
        join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id
        where p_who in ('tenant', 'both') and ru.condo_unit_id = v_cu and coalesce(t.email, '') <> ''
    ) x
  loop
    insert into email_outbox (to_email, subject, html, kind) values (r.e, trim(p_subject), v_html, 'staff_message');
    v_names := v_names || r.nm;
  end loop;
  if cardinality(v_names) = 0 then raise exception 'Nobody with an email address is on file for that choice.'; end if;
  return jsonb_build_object('queued', cardinality(v_names), 'names', to_jsonb(v_names));
end $$;
revoke all on function staff_email_unit(text, text, text, text) from public, anon;
grant execute on function staff_email_unit(text, text, text, text) to authenticated;
