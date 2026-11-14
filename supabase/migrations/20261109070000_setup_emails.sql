-- Account setup emails (Stephen, 10/11/2026): the owners' "set up your login" email and gentle-but-firm reminders to every tenant and owner who
-- has not set up yet. Sent by the setup-emails function; logged in email_log (kinds launch_owner, reminder_tenant, reminder_owner).
--
-- "Set up" means:
--   tenants (active/future lease, or active land contract): used their registration code, OR signed in after the cutoff;
--   owners (a current unit, not 2nd Chance Housing Inc itself, not staff): signed in after the cutoff.
-- The cutoff is needed because the login check (tools/check-logins.mjs) opens a test session for every login; it is set to the time of the last check
-- so that only a REAL sign-in after it counts.

insert into portal_settings (key, value) values ('setup_signin_cutoff', '2026-10-11T00:00:00Z') on conflict (key) do nothing;

create or replace function setup_status_list()
returns table (kind text, id uuid, name text, email text, unit text, set_up boolean)
language sql stable security definer set search_path = public, auth as $$
  with cut as (select coalesce(nullif((select value from portal_settings where key = 'setup_signin_cutoff'), '')::timestamptz, now()) c),
  tn as (
    select t.id, t.name, t.email from tenants_on_leases() t
    union
    select t.id, t.name, t.email from land_contract_buyers b join land_contracts c on c.id = b.contract_id and c.status = 'active' join tenants t on t.id = b.tenant_id)
  select 'tenant', tn.id, tn.name, tn.email,
         (select string_agg(distinct u.unit_number, ', ') from lease_tenants lt join leases l on l.id = lt.lease_id and l.status in ('active', 'future') join rental_units u on u.id = l.unit_id where lt.tenant_id = tn.id),
         exists (select 1 from tenant_reg_codes r where r.tenant_id = tn.id and r.used_at is not null)
           or exists (select 1 from auth.users a, cut where lower(a.email) = lower(tn.email) and a.last_sign_in_at > cut.c)
  from tn
  union all
  select 'owner', o.id, o.name, o.email, condo_unit_label(o.id),
         exists (select 1 from auth.users a, cut where lower(a.email) = lower(o.email) and a.last_sign_in_at > cut.c)
  from condo_owners o
  where condo_owner_for_email(o.email) is not null and o.name !~* '^2nd Chance'
    and not exists (select 1 from condo_staff s where lower(s.email) = lower(o.email));
$$;
revoke all on function setup_status_list() from public, anon, authenticated;
grant execute on function setup_status_list() to service_role;
