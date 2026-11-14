-- Unit 4 (Ashley Williams) work in lieu of rent. Decided by Stephen, 10/6/2026. Run AFTER migration 20261105060000_work_jobs.
--   * Lawn care and snow removal: a standing monthly job, $205 a month credited against rent (perpetual).
--   * Hallway paint: $350, offsets September 2026 rent once the work is inspected and accepted.
--   * Unit 18 rent-ready job (floor preparation, painting, cleaning): $550, offsets October 2026 rent once accepted.
-- Safe to run twice: it adds each agreement only once.
begin;

do $$
declare v_lease uuid;
begin
  select l.id into v_lease from leases l join rental_units ru on ru.id = l.unit_id
   where ru.unit_number = '4' and l.status = 'active' and l.tenants_label ilike 'Ashley Williams%';
  if v_lease is null then raise exception 'Unit 4 lease not found'; end if;

  -- 1. Lawn care and snow removal: switch the standing agreement on ($205 a month, from the next rent cycle).
  update work_agreements set kind = 'monthly', status = 'active', monthly_credit = 205, start_date = coalesce(start_date, date '2026-11-01'),
         title = 'Lawn care and snow removal (monthly, $205 rent credit)'
   where lease_id = v_lease and title ilike 'Landscaping & snow removal%';
  if not found and not exists (select 1 from work_agreements where lease_id = v_lease and kind = 'monthly') then
    insert into work_agreements (lease_id, kind, title, scope, monthly_credit, status, start_date, equipment_terms) values
      (v_lease, 'monthly', 'Lawn care and snow removal (monthly, $205 rent credit)',
       'Lawn mowing, trimming and seasonal yard care; snow and ice removal from walks, steps, entrances and parking areas at 6622 and 6626 N. Bourbon St. Tenant supplies the labor only. 2nd Chance Housing supplies, maintains and repairs all equipment and supplies (mower, trimmer, snow blower, shovels, salt, fuel).',
       205, 'active', date '2026-11-01', 'Equipment and supplies are owned, maintained, repaired and replaced by 2nd Chance Housing. Tenant reports any damage or malfunction immediately and does not operate equipment that is unsafe.');
  end if;

  -- 2. Hallway paint: a one-time job worth $350 that offsets September rent.
  if not exists (select 1 from work_agreements where lease_id = v_lease and title = 'Hallway paint') then
    insert into work_agreements (lease_id, kind, title, scope, job_value, credit_month, status, work_location, tasks, terms_html) values
      (v_lease, 'job', 'Hallway paint',
       'Paint the hallway at 6626 N. Bourbon St. 2nd Chance Housing supplies the paint and materials.', 350, date '2026-09-01', 'draft', '6626 N. Bourbon St., hallway',
       '[{"key":"hall","name":"Paint the hallway","status":"todo"}]'::jsonb,
       $t$<h4>Scope</h4><ul><li>Patch nail holes and small dents with spackle, then sand smooth.</li><li>Paint the hallway walls, using only the color and paint supplied or approved by 2nd Chance Housing.</li><li>Protect floors, fixtures, outlets and windows with drop cloths and tape, and remove the tape when done.</li><li>Clean up all paint debris and leftover materials.</li></ul>
<h4>Pay</h4><p>2nd Chance Housing credits <b>$350.00</b> to your <b>September 2026</b> rent after we inspect and accept the finished work. If the work is not completed, no credit is applied and the rent stays due.</p>
<h4>Materials, standard and inspection</h4><p>We supply the paint, primer, spackle, drop cloths and trash bags. You supply basic hand tools. The hallway is done when the paint is even, with no drips or missed spots, no paint on floors, fixtures or outlets, and no debris left behind. Tell us when you finish; we walk through within 2 business days and either accept it or give you a written list to fix.</p>
<h4>Other terms</h4><p>This job is voluntary and separate from your lease. It does not change your lease or your rent. A rent credit counts as income, and 2nd Chance Housing issues a Form 1099 if IRS rules require it. Use ventilation when painting, follow product labels, and use a stable ladder. If the building was built before 1978, do not sand or scrape painted surfaces until we confirm lead-safe practices are in place. Stop and tell us right away about any injury, damage, leak, pest problem or unsafe condition.</p>$t$);
  end if;

  -- 3. Unit 18 rent-ready job: $550, offsets October rent.
  if not exists (select 1 from work_agreements where lease_id = v_lease and title ilike 'Unit 18 rent-ready%') then
    insert into work_agreements (lease_id, kind, title, scope, job_value, credit_month, status, work_location, tasks, terms_html) values
      (v_lease, 'job', 'Unit 18 rent-ready job (floor preparation, painting, cleaning)',
       'Bring Unit 18 (a 2-bedroom, 1-bath, 960 sq ft apartment) to rent-ready condition: floor preparation, painting and rent-ready cleaning. 2nd Chance Housing supplies the paint, primer, spackle, cleaning products, drop cloths and trash bags.',
       550, date '2026-10-01', 'draft', 'Unit 18, 6622 N. Bourbon St., Milwaukee, WI 53224',
       '[{"key":"floor","name":"A. Floor preparation","status":"todo"},{"key":"paint","name":"B. Painting","status":"todo"},{"key":"clean","name":"C. Rent-ready cleaning","status":"todo"}]'::jsonb,
       $t$<h4>A. Floor preparation</h4><ul><li>Remove old flooring, carpet, padding, tack strips, staples and nails as directed by 2nd Chance Housing.</li><li>Scrape, sweep and vacuum the subfloor so it is free of debris, adhesive ridges and dust.</li><li>Report any soft spots, water damage, holes or mold to us before continuing.</li><li>Leave the floor ready for new flooring to be installed by others (installation is not included unless added in writing).</li></ul>
<h4>B. Painting</h4><ul><li>Patch nail holes and small dents with spackle, then sand smooth.</li><li>Paint the walls in all rooms, plus ceilings and trim if we agree.</li><li>Protect floors, fixtures, outlets and windows with drop cloths and tape; remove the tape when done.</li><li>Use only the colors and paint supplied or approved by 2nd Chance Housing.</li></ul>
<h4>C. Rent-ready cleaning</h4><ul><li>Kitchen: cabinets inside and out, counters, sink and faucet.</li><li>Bathroom: toilet, tub or shower, sink, mirror, vanity and floor.</li><li>All rooms: windows and sills, blinds, light fixtures, switch plates, outlets, doors and baseboards.</li><li>Remove all trash, paint debris and leftover materials from the unit and common areas.</li></ul>
<p>Any work outside this list needs written approval from 2nd Chance Housing before it starts, or it will not be credited.</p>
<h4>Timeline, access and keys</h4><p>Working hours are between 8:00 AM and 8:00 PM so other residents are not disturbed. We give you a key to Unit 18 for this job only. Keep the unit locked when you are not working, do not let anyone else in without our approval, and return the key when you finish or when asked. No one may live, sleep or store belongings in the unit. If you cannot finish on time, tell us as soon as possible so a new date can be agreed in writing.</p>
<h4>Pay</h4><p>2nd Chance Housing credits <b>$550.00</b> to your <b>October 2026</b> rent for the full scope of work, after we inspect and accept it. The rest of your October rent is due as usual. If the work is not completed, no credit is applied.</p>
<h4>Materials, standard and inspection</h4><p>We supply paint, primer, spackle, cleaning products, drop cloths and trash bags. You supply basic hand tools unless we agree to supply them. Do not buy anything to be reimbursed without written approval and a receipt. The unit is rent-ready when a new resident could move in without further cleaning or painting: even paint coverage with no drips or missed spots, no paint on floors, fixtures or outlets, and every surface free of dust, grime and debris. When you finish, tell us; within 2 business days we walk through the unit and either accept the work or give a written list of items to fix. You fix those within 3 days at no extra charge before the credit is posted.</p>
<h4>Other terms</h4><p>This job is voluntary and separate from your lease: accepting it, declining it or ending it early has no effect on your lease, rent or housing. You are doing the job as an independent worker, not as an employee, and you are responsible for any taxes. A rent credit counts as income, and 2nd Chance Housing issues a Form 1099 if IRS rules require it. Use ventilation when painting, follow product labels, and use a stable ladder. If the building was built before 1978, do not sand, scrape or dry-sweep painted surfaces until we confirm lead-safe practices are in place. Stop and tell us right away about any injury, damage, leak, pest problem or unsafe condition. You are responsible for repairing damage caused by your carelessness beyond normal wear from doing the work. Either of us may end this agreement with written notice; we credit a fair share for work already completed and accepted, and you return the key and unused materials. Any change must be in writing.</p>$t$);
  end if;
end $$;

commit;
