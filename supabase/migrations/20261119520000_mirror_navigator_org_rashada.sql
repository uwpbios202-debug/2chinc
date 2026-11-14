-- The Human Mirror, D-20 (Stephen 11/13/2026: "is this done? If not do it please"): each Navigator business is its own Mirror
-- organization. The one Navigator on file (Preview) had none. This adds it the way mirror_admin_org_save does (kind 'navigator',
-- tied by navigator_id, active), and makes the Navigator that organization's first admin (her own business), marked as set up by
-- 2nd Chance (platform_changed_*), like a first admin added from https://2ndchinc.org/mirror/admin/ .
-- Her email is read from public.navigators, never written here. No invitation is sent (Mirror sign-in is off, D-22/D-28).
-- Safe to run twice: nothing happens if the Navigator already has an organization or membership.

insert into mirror.organizations (name, kind, navigator_id, active)
select coalesce(nullif(trim(n.business_name), ''), n.name), 'navigator', n.id, true
  from public.navigators n
 where n.id = '72d0a47d-4936-4cf3-8f2d-14d40190fb82'
   and not exists (select 1 from mirror.organizations o where o.navigator_id = n.id);

insert into mirror.organization_members (organization_id, auth_email, name, role, active, platform_changed_at, platform_changed_by)
select o.id, lower(trim(n.email)), n.name, 'org_admin', true, now(), 'info@2ndchinc.org'
  from public.navigators n
  join mirror.organizations o on o.navigator_id = n.id
 where n.id = '72d0a47d-4936-4cf3-8f2d-14d40190fb82'
on conflict (organization_id, auth_email) do nothing;
