-- LOCAL ONLY (listed in .gitignore; never commit): contains a real person's email (CLAUDE.md rule).
-- First Housing Navigator, Preview status (Stephen, 11/11/2026): she can sign in and look around; nothing can be added until Pilot.
insert into navigators (name, email, business_name, dfi_entity_id, dfi_status, dfi_checked_on, status, max_open_referrals, chk_meeting)
values ('Rashada Ford', 'r85ford30@gmail.com', 'Long Lasting Care LLC', 'L078074', 'Administratively dissolved 6/14/2026', date '2026-11-11', 'preview', 5, date '2026-11-11')
on conflict ((lower(email))) do update set status = 'preview', updated_at = now();
