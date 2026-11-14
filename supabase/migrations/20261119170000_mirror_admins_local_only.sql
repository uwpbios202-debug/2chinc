-- LOCAL ONLY (gitignored, never committed: real email addresses). Applied from this PC with sh tools/deploy.sh db.
-- Stephen, 11/13/2026: two Mirror admins for 2nd Chance Housing Inc so he can check the Mirror sign-in live:
-- info@2ndchinc.org (Microsoft 365, down 11/12 evening) and 2ndchinc@gmail.com. Both are already on the site's sign-in list
-- (staff / owner), so the Mirror switch stays off. As members they must enter an authenticator code in the Mirror (D-13).
insert into mirror.organization_members (organization_id, auth_email, name, role, joined_at)
select o.id, v.email, v.name, 'org_admin', now()
from mirror.organizations o
cross join (values ('info@2ndchinc.org', '2nd Chance Housing Office'), ('2ndchinc@gmail.com', '2nd Chance Housing')) v(email, name)
where o.is_platform_owner
on conflict (organization_id, auth_email) do update set active = true, role = 'org_admin';
