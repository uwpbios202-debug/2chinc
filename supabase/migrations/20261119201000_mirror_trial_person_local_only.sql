-- LOCAL ONLY (gitignored: real email). Stephen, 11/13/2026: answer the first reflections himself. 2ndchinc@gmail.com becomes a
-- Mirror person of 2nd Chance Housing Inc too (it is also an admin there), so /mirror/my-mirror/ opens for it. Its answers are its
-- own; the person record can be deleted later (answers go with it).
insert into mirror.individuals (auth_email, preferred_name, created_by_org)
select '2ndchinc@gmail.com', 'Stephen (trial)', o.id from mirror.organizations o where o.is_platform_owner
on conflict (auth_email) where auth_email is not null do nothing;

insert into mirror.organization_individuals (organization_id, individual_id, status, started_on)
select o.id, i.id, 'active', current_date
from mirror.organizations o, mirror.individuals i
where o.is_platform_owner and i.auth_email = '2ndchinc@gmail.com'
on conflict (organization_id, individual_id) do nothing;
