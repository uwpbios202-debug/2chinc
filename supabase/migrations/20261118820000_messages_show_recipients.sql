-- Staff Messages: every office message shows who it went TO, as proof (Stephen, 11/11/2026).
-- One office message to a lease is stored once per tenant (same created_at, body and sender). For each office message the thread now lists
-- every tenant it went to, the email address used, when it was emailed (email_outbox), and the delivery result from the mail service
-- (email_log: delivered / opened / bounced). Works for messages already sent too. Portal-only recipients (no email on file) are listed as such.

create or replace function messages_staff_thread(p_tenant uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update tenant_messages set read_at = now() where tenant_id = p_tenant and from_resident and read_at is null;
  return jsonb_build_object('tenant', (select jsonb_build_object('name', name, 'email', email, 'phone', phone, 'alt_phone', alt_phone,
      'emergency_name', emergency_name, 'emergency_phone', emergency_phone, 'emergency_relation', emergency_relation, 'profile_confirmed_at', profile_confirmed_at) from tenants where id = p_tenant),
    'co_tenants', coalesce((select jsonb_agg(jsonb_build_object('name', c.name, 'has_email', coalesce(c.email, '') <> '') order by c.name) from tenant_co_tenants(p_tenant) c), '[]'::jsonb),
    'messages', coalesce((select jsonb_agg(to_jsonb(m) || case when m.from_resident then '{}'::jsonb else jsonb_build_object('to', (
        select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'email', o.to_email, 'emailed_at', o.sent_at, 'email_error', o.error,
                 'status', lg.status, 'delivered_at', lg.delivered_at, 'opened_at', lg.first_opened_at, 'bounced_at', lg.bounced_at, 'bounce_reason', lg.bounce_reason)
                 order by (m2.tenant_id = p_tenant) desc, t.name), '[]'::jsonb)
          from tenant_messages m2 join tenants t on t.id = m2.tenant_id
          left join lateral (select * from email_outbox o where o.kind = 'message' and o.created_at = m2.created_at and lower(o.to_email) = lower(t.email) order by o.id limit 1) o on true
          left join lateral (select * from email_log l where lower(l.to_email) = lower(o.to_email) and o.sent_at is not null
                               and l.sent_at between o.sent_at - interval '1 minute' and o.sent_at + interval '5 minutes' order by l.sent_at limit 1) lg on true
         where not m2.from_resident and m2.created_at = m.created_at and m2.body = m.body and coalesce(m2.by_email, '') = coalesce(m.by_email, ''))) end
      order by m.created_at) from tenant_messages m where m.tenant_id = p_tenant), '[]'::jsonb));
end;
$$;
revoke all on function messages_staff_thread(uuid) from public, anon;
grant execute on function messages_staff_thread(uuid) to authenticated;
