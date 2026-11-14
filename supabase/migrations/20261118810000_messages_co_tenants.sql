-- Staff messages go to every adult on the lease (Stephen, 11/11/2026): when a lease has two (or more) tenants, a message the office writes to
-- one of them (https://2ndchinc.org/resident/messages/) is also emailed to the others and kept in each one's portal Messages.
-- "On the lease" = the same active or future lease (lease_tenants). Each email names everyone it went to.

-- The other tenants on the same active/future lease(s).
create or replace function tenant_co_tenants(p_tenant uuid)
returns table (tenant_id uuid, name text, email text) language sql stable security definer set search_path = public as $$
  select distinct t.id, t.name, t.email
    from lease_tenants me join leases l on l.id = me.lease_id and l.status in ('active', 'future')
    join lease_tenants other on other.lease_id = l.id and other.tenant_id <> me.tenant_id
    join tenants t on t.id = other.tenant_id
   where me.tenant_id = p_tenant;
$$;
revoke all on function tenant_co_tenants(uuid) from public, anon, authenticated;

create or replace function messages_staff_reply(p_tenant uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t tenants; r record; v_body text := left(trim(coalesce(p_body, '')), 4000); v_names text; v_sent text[] := '{}';
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into t from tenants where id = p_tenant;
  if t.id is null then raise exception 'Tenant not found'; end if;
  if length(v_body) < 2 then raise exception 'Write the reply first.'; end if;
  select string_agg(name, ' and ' order by name) into v_names from (select t.name union select c.name from tenant_co_tenants(p_tenant) c) x;
  for r in select t.id as tenant_id, t.name, t.email union all select c.tenant_id, c.name, c.email from tenant_co_tenants(p_tenant) c loop
    insert into tenant_messages (tenant_id, from_resident, body, by_email) values (r.tenant_id, false, v_body, auth.email());
    if coalesce(r.email, '') <> '' and not (lower(r.email) = any (v_sent)) then
      v_sent := v_sent || lower(r.email);
      insert into email_outbox (to_email, subject, html, kind) values (r.email, 'Message from 2nd Chance Housing',
        tenant_email_wrap(split_part(r.name, ' ', 1), '<p>' || replace(repair_esc(v_body), E'\n', '<br>') || '</p>'
          || case when v_names like '% and %' then '<p style="color:#555;font-size:13px">Sent to everyone on the lease: ' || repair_esc(v_names) || '.</p>' else '' end
          || '<p>Reply in your resident portal: <a href="' || (select value from portal_settings where key = 'resident_url') || '#messages">Messages</a>.</p>'), 'message');
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'sent_to', v_names);
end;
$$;
revoke all on function messages_staff_reply(uuid, text) from public, anon;
grant execute on function messages_staff_reply(uuid, text) to authenticated;

-- The thread also says who else on the lease gets the message.
create or replace function messages_staff_thread(p_tenant uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update tenant_messages set read_at = now() where tenant_id = p_tenant and from_resident and read_at is null;
  return jsonb_build_object('tenant', (select jsonb_build_object('name', name, 'email', email, 'phone', phone, 'alt_phone', alt_phone,
      'emergency_name', emergency_name, 'emergency_phone', emergency_phone, 'emergency_relation', emergency_relation, 'profile_confirmed_at', profile_confirmed_at) from tenants where id = p_tenant),
    'co_tenants', coalesce((select jsonb_agg(jsonb_build_object('name', c.name, 'has_email', coalesce(c.email, '') <> '') order by c.name) from tenant_co_tenants(p_tenant) c), '[]'::jsonb),
    'messages', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from tenant_messages m where m.tenant_id = p_tenant), '[]'::jsonb));
end;
$$;
revoke all on function messages_staff_thread(uuid) from public, anon;
grant execute on function messages_staff_thread(uuid) to authenticated;
