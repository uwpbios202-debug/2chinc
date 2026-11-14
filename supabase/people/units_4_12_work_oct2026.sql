-- Work in lieu of rent, October 2026 (Stephen, 10/12/2026): Units 4 and 12.
--   Unit 4 (Ashley Williams): Unit 18 rent-ready job, now $400, due Wednesday 10/14/2026 (offsets October rent);
--     Hallway paint, now $400, starts when 2nd Chance Housing has the paint (offsets November rent).
--   Unit 12 (the tenants on the lease): basement cleanout, $200, due Friday 10/16/2026 (offsets October rent).
-- Agreements stay drafts until the tenant reads and accepts them in the portal (Work tab); the credit posts only when
-- staff inspect and accept the finished work (work_staff_accept). Nothing is credited by this script.
-- No emails or personal details are written here (the lease is found by unit number). The tenant emails are HELD in
-- units_4_12_work_emails_HOLD.sql: Stephen said wait (10/12/2026), so this script sends nothing.

begin;

do $$
declare v4 uuid; v12 uuid; w uuid;
begin
  select l.id into v4 from leases l join rental_units ru on ru.id = l.unit_id where ru.unit_number = '4' and l.status = 'active' order by l.start_date desc limit 1;
  select l.id into v12 from leases l join rental_units ru on ru.id = l.unit_id where ru.unit_number = '12' and l.status = 'active' order by l.start_date desc limit 1;
  if v4 is null or v12 is null then raise exception 'Active lease for unit 4 or 12 not found'; end if;

  -- Unit 4: Unit 18 rent-ready job -> $400, due Wednesday 10/14/2026
  update work_agreements set job_value = 400, end_date = date '2026-10-14',
    terms_html = replace(replace(terms_html, '$550.00', '$400.00'), 'If you cannot finish on time',
                         'The work must be finished by 8:00 PM on Wednesday, October 14, 2026. If you cannot finish on time')
   where lease_id = v4 and kind = 'job' and title ilike 'Unit 18 rent-ready%' and status = 'draft' and job_value = 550;

  -- Unit 4: Hallway paint -> $400, starts when the paint arrives, offsets November rent
  update work_agreements set job_value = 400, credit_month = date '2026-11-01',
    terms_html = replace(replace(terms_html, '<b>$350.00</b> to your <b>September 2026</b> rent after we inspect and accept the finished work.',
                 '<b>$400.00</b> to your <b>November 2026</b> rent after we inspect and accept the finished work. This job starts when 2nd Chance Housing has the paint; we will tell you the day it arrives.'), '$350.00', '$400.00')
   where lease_id = v4 and kind = 'job' and title = 'Hallway paint' and status = 'draft' and job_value = 350;

  -- Unit 12: basement cleanout, $200, due Friday 10/16/2026, offsets October rent
  if not exists (select 1 from work_agreements where lease_id = v12 and kind = 'job' and title ilike 'Basement cleanout%') then
    insert into work_agreements (lease_id, kind, title, scope, job_value, credit_month, status, end_date, work_location, tasks, terms_html) values
      (v12, 'job', 'Basement cleanout',
       'Clean out the basement at 6622 N. Bourbon St.: remove trash, debris and unwanted materials, then sweep and wash the floors. 2nd Chance Housing supplies the trash bags, gloves and cleaning supplies.',
       200, date '2026-10-01', 'draft', date '2026-10-16', '6622 N. Bourbon St., basement',
       '[{"key":"clean","name":"Basement cleanout","status":"todo"}]'::jsonb,
       $t$<h4>Scope</h4><ul><li>Remove trash, debris and materials that 2nd Chance Housing tells you to remove, and put them out for disposal as we direct.</li><li>Do not throw away anything that belongs to a resident. If you are not sure, leave it and ask us.</li><li>Sweep and wash the basement floors, and clear walkways and the areas around the furnace, water heater and utility rooms.</li><li>Tell us about any leak, sewer backup, mold, pests or unsafe condition you find, and do not touch it.</li></ul>
<h4>Due date</h4><p>The work must be finished by 8:00 PM on <b>Friday, October 16, 2026</b>. Working hours are between 8:00 AM and 8:00 PM so other residents are not disturbed. If you cannot finish on time, tell us as soon as possible so a new date can be agreed in writing.</p>
<h4>Pay</h4><p>2nd Chance Housing credits <b>$200.00</b> to your <b>October 2026</b> rent for the full scope of work, after we inspect and accept it. The rest of your October rent is due as usual. If the work is not completed, no credit is applied.</p>
<h4>Materials, standard and inspection</h4><p>We supply trash bags, gloves and cleaning supplies. Do not buy anything to be reimbursed without written approval and a receipt. The basement is done when the debris is removed, the floors are swept and washed, and the walkways and utility areas are clear. When you finish, tell us; within 2 business days we walk through and either accept the work or give a written list of items to fix. You fix those within 3 days at no extra charge before the credit is posted.</p>
<h4>Other terms</h4><p>This job is voluntary and separate from your lease: accepting it, declining it or ending it early has no effect on your lease, rent or housing. You are doing the job as an independent worker, not as an employee, and you are responsible for any taxes. A rent credit counts as income, and 2nd Chance Housing issues a Form 1099 if IRS rules require it. Wear gloves and sturdy shoes, lift safely, and never work near a sewer backup, standing water or mold. Stop and tell us right away about any injury, damage, leak, pest problem or unsafe condition. You are responsible for repairing damage caused by your carelessness beyond normal wear from doing the work. Either of us may end this agreement with written notice; we credit a fair share for work already completed and accepted. Any change must be in writing.</p>$t$);
  end if;
end $$;

commit;
