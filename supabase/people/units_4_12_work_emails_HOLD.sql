-- HELD (Stephen, 10/12/2026: "we wait to send"). Run this only when Stephen says to send the Unit 4 and Unit 12 work agreement emails.
-- It queues one email to everyone on each lease (email_outbox); the daily run sends them (about 12:01 AM Central), or any signed-in
-- action that flushes the outbox. Deadlines in the text (Wed 10/14, Fri 10/16) will need updating if they have moved.
-- Check first that the agreements exist: see units_4_12_work_oct2026.sql.

begin;
do $$
declare v4 uuid; v12 uuid;
begin
  select l.id into v4 from leases l join rental_units ru on ru.id = l.unit_id where ru.unit_number = '4' and l.status = 'active' order by l.start_date desc limit 1;
  select l.id into v12 from leases l join rental_units ru on ru.id = l.unit_id where ru.unit_number = '12' and l.status = 'active' order by l.start_date desc limit 1;
  -- Emails to everyone on each lease
  perform lease_email_tenants(v4, 'Your work agreements: Unit 18 by Wednesday, hallway paint',
    '<p>Here are your two work-in-lieu-of-rent jobs.</p>'
    || '<p><b>1. Unit 18 rent-ready job: $400 credit to your October 2026 rent.</b> Floor preparation, painting and rent-ready cleaning. It must be finished by <b>8:00 PM on Wednesday, October 14, 2026</b>.</p>'
    || '<p><b>2. Hallway paint: $400 credit to your November 2026 rent.</b> This starts when we have the paint; we will tell you the day it arrives.</p>'
    || '<p>To begin, sign in at https://2ndchinc.org/resident/#work, read each agreement and type your name to accept it. Mark each task started and done as you go, and add notes or photos. The credit posts after we inspect and accept the finished work; if a job is not completed, no credit is applied and the rent stays due.</p>', 'work');
  perform lease_email_tenants(v12, 'Your work agreement: basement cleanout by Friday',
    '<p>Here is your work-in-lieu-of-rent job.</p>'
    || '<p><b>Basement cleanout: $200 credit to your October 2026 rent.</b> It must be finished by <b>8:00 PM on Friday, October 16, 2026</b>.</p>'
    || '<p>To begin, sign in at https://2ndchinc.org/resident/#work, read the agreement and type your name to accept it. Mark the task started and done, and add notes or photos. The credit posts after we inspect and accept the finished work; if the job is not completed, no credit is applied and the rent stays due.</p>', 'work');
end $$;
commit;
