-- Breach notices built from the lease itself. Staff pick the provision the tenant broke
-- (from the lease agreement's own clauses, Rules and Regulations and Parking Agreement);
-- the notice then quotes that lease language, states the remedy, and states the
-- consequence the lease gives, next to the cure period the lease type requires (5 days,
-- 30 for a lease over a year; Section 8 tenancies are copied to the housing authority).
-- Staff still describe what happened (what, where, when) and can edit the remedy.

create table if not exists lease_breach_types (
  code text primary key,
  category text not null,            -- Rules | Lease | Parking
  title text not null,
  provision_ref text not null,       -- where it is in the lease
  lease_quote text not null,         -- the lease's own words
  remedy text not null,              -- what the tenant must do to cure
  consequence text not null,         -- what the lease says follows
  prompt text,                       -- hint for describing what happened
  sort int not null default 0,
  active boolean not null default true
);
alter table lease_breach_types enable row level security;

insert into lease_breach_types (code, category, title, provision_ref, lease_quote, remedy, consequence, prompt, sort) values
  ('smoking', 'Rules', 'Smoking on the property', 'Rules and Regulations, Smoking', 'No smoking is allowed on the property at any time unless otherwise indicated in writing by Landlord.', 'Stop all smoking on the property, including in the unit, and pay for any damage the smoking caused.', 'You are responsible for any damage from smoking. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'Where and when the smoking happened, and who saw or smelled it.', 10),
  ('noise', 'Rules', 'Noise and odors', 'Rules and Regulations, Noises & Odors', 'Tenant will not make or permit noises or acts that will disturb the right or comfort of other tenants and/or neighbors.', 'Keep radios, TVs, instruments and other devices at a level that does not disturb other tenants or neighbors, starting now.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'The dates, times and what the noise or odor was, and who complained.', 20),
  ('guests', 'Rules', 'Overnight guests over 13 nights', 'Rules and Regulations, Guests; Lease, Use of Premises and Guests', 'No guest shall remain overnight in the property for more than thirteen (13) nights in total in any twelve (12) month period without the prior written consent of Landlord.', 'Have the guest leave, or ask the Landlord for written consent. The guest may not stay overnight again without that consent.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction." Anyone living there who is not on the rental agreement is an unauthorized occupant.', 'Who the guest is and how many nights they have stayed.', 30),
  ('guest_alone', 'Rules', 'Guest on the property when the tenant is not there', 'Rules and Regulations, Guests', 'No guest shall remain on the property unless Tenant is also present.', 'Do not leave guests on the property without you there.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'Who was there, when, and who saw it.', 40),
  ('unauthorized_occupant', 'Lease', 'Unauthorized occupant / business or childcare', 'Lease, Use of Premises and Guests; Rules and Regulations, Use of the Property', 'The property is to be used as a personal residence only and is for the individuals listed on the rental agreement only. The property shall not be used to operate any form of business for any reason, including but not limited to, a child-care facility.', 'Stop the business or childcare use, and have anyone not named on the rental agreement move out, or ask the Landlord for written approval.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'Who is living there or what business is operated, and how you know.', 50),
  ('criminal', 'Lease', 'Criminal activity', 'Lease, Criminal Activity Prohibited', 'Tenant, any member of Tenant''s household, guest, or invitee, shall not engage in or allow others to engage in any criminal activity, including drug-related criminal activity, in the Premises or on the property.', 'End the activity immediately and keep it from happening again. Staff: confirm with counsel whether this should be a cure notice or a notice without a right to cure.', 'Criminal activity is a breach of the rental agreement and can lead to termination of the tenancy and eviction.', 'What happened, when, where, and the police report number if there is one.', 60),
  ('unlawful_use', 'Lease', 'Unlawful use or disturbing neighbors', 'Lease, Use of Premises and Guests', 'Neither party may: (1) make or knowingly permit use of the Premises for any unlawful purpose; (2) engage in activities which unduly disturb neighbors or tenants; and/or (3) do, use, or keep in or about the Premises anything which would adversely affect coverage under a standard fire and extended insurance policy.', 'Stop the activity and remove anything that is unlawful or that puts the building''s fire insurance at risk.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What the activity was, when, and who reported it.', 70),
  ('hazardous_items', 'Rules', 'Hazardous or prohibited items', 'Rules and Regulations, Use of the Property', 'Tenant shall not keep any hazardous items on or inside of property including, but not limited to, paint, lacquer, turpentine, paint thinner, acetone, gasoline, motor oil, pesticides, herbicides, kerosene, propane, lighter fluid or any other hazardous, flammable or combustible items.', 'Remove the items from the property right away. Candles, space heaters, pools, trampolines, fireworks and air or BB guns also need the Landlord''s prior written consent.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction." Fire and safety violations can also affect the building''s insurance.', 'Which items were seen, where, and when.', 80),
  ('sales', 'Rules', 'Sales or car washes on the property', 'Rules and Regulations, Use of the Property', 'No rummage sales, or sales of any kind, may be held on the property without the prior written consent of Landlord. No car washes, for profit or otherwise, may be held on the property without the prior written consent of Landlord.', 'Stop the sale or car wash. Ask for the Landlord''s written consent before any future one.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What was sold or washed, and when.', 90),
  ('garbage', 'Rules', 'Garbage, recycling and litter', 'Rules and Regulations, Appearance & Upkeep of Property', 'Neither garbage nor recyclable materials shall be kept on the porch, common areas, or grounds.', 'Clean up and put garbage and recycling in the proper receptacles now, and arrange for large items to be removed under local rules.', 'Charges the Landlord has because of this are the tenant''s responsibility. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What was left where, and when it was seen.', 100),
  ('personal_property', 'Rules', 'Belongings in common areas or on the grounds', 'Rules and Regulations, Appearance & Upkeep of Property', 'Personal property shall not be kept in common areas or on the grounds and will be immediately removed and disposed of by landlord. Any costs incurred by Landlord to remove Tenant''s property will be the tenant''s responsibility.', 'Remove your belongings from the common areas and grounds right away.', 'The Landlord may remove and dispose of the property, and the tenant pays the cost. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What was left where, and when it was seen.', 110),
  ('window_coverings', 'Rules', 'Window coverings', 'Rules and Regulations, Appearance & Upkeep of Property', 'Tenant shall use only appropriate window coverings, such as drapes or blinds. Rugs, towels, blankets, or sheets are not allowed.', 'Replace the coverings with drapes or blinds.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'Which windows and what is covering them.', 120),
  ('signs', 'Rules', 'Signs or advertisements', 'Rules and Regulations, Appearance & Upkeep of Property', 'Tenant shall not allow any sign, advertisement, or notice to be placed inside or outside the rental unit or on the property without the prior written consent of Landlord.', 'Take the sign down, or get the Landlord''s written consent.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What the sign says and where it is.', 130),
  ('alterations', 'Rules', 'Alterations or painting without consent', 'Rules and Regulations, Modifications to Property; Lease, Maintenance', 'Tenant is prohibited from making any alterations, additions, or improvements to the inside or outside of the property, including but not limited to, painting, varnishing, wallpapering, or installing any fixtures, without the prior written consent of Landlord.', 'Stop the work and restore the property to its original condition, or ask for written consent.', 'The Landlord may remove the work immediately, and the tenant pays all costs to return the property to its original condition. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What was changed, where, and when it was found.', 140),
  ('damage', 'Rules', 'Damage to the property', 'Rules and Regulations, Damage to the Property', 'If the property is damaged as a result of the intentional acts, negligence, carelessness, or misuse by Tenant, Tenant will be responsible for the repair costs incurred by Landlord. Tenant must reimburse Landlord for any repair costs within fifteen (15) days of demand.', 'Report the damage in writing and reimburse the Landlord''s repair costs within fifteen (15) days of this demand.', 'The tenant pays the repair costs, and the cost can be deducted from the security deposit. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What was damaged, how, when, and the repair cost if known.', 150),
  ('locks', 'Rules', 'Locks or keys', 'Rules and Regulations, Changing Locks', 'Tenant will not install additional or different locks or gates on any doors or windows in the property without the prior written consent of Landlord. ... Tenant shall not give any keys to the property to any person other than those listed on the rental agreement without the prior written consent of Landlord.', 'Give the Landlord a key to every lock within twenty-four (24) hours, and do not give keys to anyone not on the rental agreement.', 'The tenant pays any repair costs the Landlord has to get into the property. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'Which lock was changed or whose keys, and when it was found.', 160),
  ('plumbing', 'Rules', 'Misuse of plumbing / unreported leaks', 'Rules and Regulations, Plumbing', 'Tenant will be responsible for the cost of any and all plumbing repairs resulting from the improper use of the plumbing facilities by Tenant. Tenant will immediately report to Landlord in writing if any pipes or faucets are leaking or if any toilet continues to run.', 'Stop putting prohibited items in toilets, sinks or disposals, and report any leak or running toilet in writing right away.', 'The tenant pays for plumbing repairs caused by improper use. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What happened, which fixture, and the plumber''s findings if any.', 170),
  ('waterbed', 'Rules', 'Waterbed or liquid-filled furniture', 'Rules and Regulations, Waterbeds', 'No furniture filled with liquid, including but not limited to waterbeds, is allowed on the property without the prior written approval of Landlord.', 'Remove the liquid-filled furniture, or get the Landlord''s written approval.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What the furniture is and where.', 180),
  ('loitering', 'Rules', 'Loitering in common areas', 'Rules and Regulations, Loitering', 'Tenant will not loiter, congregate, or play in common areas of the building, including but not limited to the hallways, stairways, basement, garages, storage areas, and driveways.', 'Stop gathering or playing in the common areas.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'Who, where and when.', 190),
  ('grilling', 'Rules', 'Grilling', 'Rules and Regulations, Grilling', 'No grilling is allowed within ten (10) feet of the property. No grilling is allowed on any balcony or porch. Only covered grills are allowed to be used - no fire pits or bonfires allowed.', 'Move the grill at least ten feet from the property, off any balcony or porch, and remove grilling materials from common areas. Do not store gas grills, tanks, charcoal or lighter fluid indoors.', 'Grilling violations are a fire and safety risk. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'Where the grill was and when.', 200),
  ('sublet', 'Rules', 'Subletting or assigning the unit', 'Rules and Regulations, Subletting / Assignment', 'Tenant is not allowed to sublet or assign the rental unit, or any part of it, without the prior written consent of Landlord.', 'End the sublet or assignment and have the other person leave, or ask for the Landlord''s written consent.', 'The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'Who is staying and how you know.', 210),
  ('utilities', 'Lease', 'Utilities not maintained', 'Lease, Responsibility for Utilities', 'Tenant must maintain utilities for the Premises until the end of the lease term or until the last day that Tenant is responsible for rent.', 'Restore the utility service in your name right away and keep it on.', 'The tenant is responsible for the cost of all utilities. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'Which utility, and the date it was shut off.', 220),
  ('heat', 'Lease', 'Heat not kept at a reasonable level', 'Lease, Maintenance', 'Whichever party is obligated to provide heat for the Premises they shall maintain a reasonable level of heat to prevent damage to the Premises and the building in which it is located.', 'Turn the heat on and keep it at a level that prevents damage to the unit and building.', 'The tenant is liable for damage caused by the unit not being heated. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'The date, temperature and any damage seen.', 230),
  ('cleanliness', 'Lease', 'Unit not kept clean, safe and sanitary', 'Lease, Maintenance; Rules and Regulations, Appearance & Upkeep', 'Tenant agrees to keep the rental unit in a clean, safe, and sanitary condition and not litter the property.', 'Clean the unit and bring it back to a clean, safe and sanitary condition by the date below.', 'The tenant is liable for damage from neglect, which can come out of the security deposit. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'What you saw at the inspection, with photo dates.', 240),
  ('absence', 'Lease', 'Absent more than two weeks without notice', 'Lease, Possession and Abandonment', 'If Tenant is absent from the Premises for two (2) successive weeks without notifying Landlord in writing of this absence, Landlord may deem the Premises abandoned unless rent has been paid for the full period of the absence.', 'Contact the Landlord in writing now to confirm that you are still living in the unit.', 'The Landlord may treat the premises as abandoned. The Rules and Regulations say a violation is "a material breach of Tenant''s rental agreement and may result in termination of tenancy and eviction."', 'How long the unit has appeared empty and what you saw.', 250),
  ('parking_delinquent', 'Parking', 'Parking while the account is past due', 'Parking Agreement, section 3 (Assignment of Parking Rights)', 'If rent or any required payment is due on the 1st day of the month and is not paid in full, the Unit Occupant is deemed delinquent as of 12:01 a.m. on the 2nd day of the month, and all parking privileges are immediately revoked without further notice.', 'Bring the account to a zero balance and remove any vehicle that has no parking privilege.', 'Any vehicle remaining on the property after revocation is considered unauthorized and will be towed at the Unit Occupant''s expense by the Association''s designated towing provider.', 'The vehicle, plate and date.', 260),
  ('parking_vehicle', 'Parking', 'Prohibited or inoperable vehicle', 'Parking Agreement, sections 5 and 9 (Vehicle Eligibility; Vehicle Condition)', 'Prohibited vehicles include, but are not limited to: trailers of any kind; boats or recreational vehicles; vehicles requiring Class C or higher licensing; unregistered or improperly licensed vehicles; inoperable vehicles.', 'Remove the vehicle or bring it into compliance (current registration, operable, in good condition).', 'A non-compliant vehicle will be towed (an inoperable one after 72 hours or sooner if deemed necessary), at the occupant''s expense.', 'The vehicle, plate, what is wrong and the date.', 270),
  ('parking_storage', 'Parking', 'Vehicle stored or parked outside the stall', 'Parking Agreement, sections 6 and 7 (Storage and Abandonment; Parking Position)', 'Vehicles not moved for seven (7) consecutive days are considered stored. Storage without written approval is prohibited and will result in towing.', 'Move the vehicle, and park fully inside your assigned stall lines without blocking sidewalks, dumpsters or access lanes.', 'Stored or mis-parked vehicles will be towed.', 'The vehicle, plate, where it was and for how long.', 280),
  ('parking_conduct', 'Parking', 'Car repairs, washing or fluid stains in the lot', 'Parking Agreement, sections 10 and 11 (Maintenance and Conduct; Cleanliness)', 'The following are prohibited and will result in enforcement action: vehicle repairs or maintenance; oil changes; car washing; cooking, sleeping, or loitering in vehicles.', 'Stop the activity and clean any oil, fluid, garbage or debris from the stall.', 'Failure to maintain cleanliness will result in fines and/or enforcement.', 'What was done and when.', 290),
  ('parking_firelane', 'Parking', 'Parking in a fire lane', 'Parking Agreement, section 12 (Fire Lanes and Roadways)', 'All roadways are designated fire lanes. Parking, stopping, or standing for more than three (3) minutes is prohibited.', 'Never park or stand in the roadways.', 'Violations will result in immediate towing without notice.', 'The vehicle, plate, where and when.', 300),
  ('parking_snow', 'Parking', 'Vehicle left in the lot during snow removal', 'Parking Agreement, section 13 (Snow Removal Compliance)', 'During snow events of two (2) inches or more, vehicles must be removed from the parking lot.', 'Move your vehicle out of the lot during snow events of two inches or more and keep it out until the lot is cleared.', 'Vehicles that are not moved can be towed.', 'The date of the snowfall and the vehicle.', 310)
on conflict (code) do update set category = excluded.category, title = excluded.title, provision_ref = excluded.provision_ref,
  lease_quote = excluded.lease_quote, remedy = excluded.remedy, consequence = excluded.consequence, prompt = excluded.prompt, sort = excluded.sort;

create or replace function breach_catalog()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('code', code, 'category', category, 'title', title, 'provision', provision_ref,
      'lease_quote', lease_quote, 'remedy', remedy, 'consequence', consequence, 'prompt', prompt) order by sort) from lease_breach_types where active), '[]'::jsonb);
end;
$$;
revoke all on function breach_catalog() from public, anon;
grant execute on function breach_catalog() to authenticated;

-- The breach-cure notice: quote the lease line after the breach, and the consequence after the remedy.
update letter_templates set html = replace(replace(html,
    '<p>You have broken your rental agreement ([[Provision]]): [[Breach]]</p>', '<p>You have broken your rental agreement ([[Provision]]): [[Breach]]</p>[[QUOTE]]'),
    'To remedy it: [[Cure]]</p>', 'To remedy it: [[Cure]]</p>[[CONSEQ]]')
  where legacy_id = '2c-breach-cure' and html not like '%[[QUOTE]]%';

-- notice_build: same as 20261030, plus the lease quote and consequence for breach-cure notices
-- (p_details: provision, breach, cure, lease_quote, consequence).
create or replace function notice_build(p_template text, p_lease uuid, p_mail_on date, p_details jsonb, p_sender_email text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  l leases; r jsonb; d jsonb := coalesce(p_details, '{}'::jsonb); v_mail date := coalesce(p_mail_on, current_date);
  v_days int; v_deadline date; v_given date; v_title text; v_statute text; v_extra jsonb; v_html text; v_email text; v_subject text;
  v_prior date; v_reason text; v_due numeric; v_cur numeric; v_month date; v_warn text := ''; v_end date; v_txt text := ''; v_short text := ''; v_quote text := ''; v_conseq text := '';
  money_ text := 'FM$999,990.00'; v_fmt text := 'FMDay, FMMonth FMDD, YYYY';
  v_service text := coalesce((select value from portal_settings where key = 'notice_service'), 'certified_mail');
  v_mm boolean;
begin
  if p_template = '2c-pay-or-vacate' then
    return pay_or_vacate_notice(p_lease, v_mail, p_sender_email) || jsonb_build_object('warning',
      case when (select federal_program from leases where id = p_lease) is not null then 'Section 8 / federal tenancy: send a copy of this notice to the housing authority.' else '' end);
  end if;
  select * into l from leases where id = p_lease;
  if l.id is null then raise exception 'Lease not found'; end if;
  r := lease_notice_rules(l.id);
  v_mm := l.lease_type = 'at_will';
  v_given := notice_deadline(v_mail, 1);
  if l.federal_program is not null then
    v_warn := 'Section 8 / federal tenancy: send a copy of this notice to the housing authority.';
  end if;

  if p_template = '2c-breach-cure' then
    if length(trim(coalesce(d->>'breach', ''))) < 10 then raise exception 'Describe the breach: what happened, where and when.'; end if;
    if length(trim(coalesce(d->>'cure', ''))) < 5 then raise exception 'Say what the tenant must do to remedy it.'; end if;
    v_days := (r->>'breach_cure_days')::int;
    v_deadline := notice_deadline(v_mail, v_days);
    v_title := case v_days when 5 then 'FIVE-DAY NOTICE TO REMEDY BREACH OR VACATE' else 'THIRTY-DAY NOTICE TO REMEDY BREACH OR VACATE' end;
    v_statute := case when r->>'lease_kind' = 'fixed_over_1_year' then 'Wis. Stat. § 704.17(3)' when v_mm then 'Wis. Stat. § 704.17(1p)(b)' else 'Wis. Stat. § 704.17(2)(b)' end;
    v_txt := case when r->>'lease_kind' = 'fixed_over_1_year' then '' else
      '<p>If, within one year of this notice, you break your rental agreement again, the landlord may end your tenancy with a 14-day notice without giving you a chance to remedy it.</p>' end;
    if nullif(trim(coalesce(d->>'lease_quote', '')), '') is not null then
      v_quote := '<p>Your lease says: &ldquo;' || repair_esc(trim(d->>'lease_quote')) || '&rdquo;</p>';
    end if;
    if nullif(trim(coalesce(d->>'consequence', '')), '') is not null then
      v_conseq := '<p><b>If it is not remedied:</b> ' || repair_esc(trim(d->>'consequence')) || '</p>';
    end if;
    v_extra := jsonb_build_object('Provision', coalesce(nullif(trim(d->>'provision'), ''), 'your lease and its rules'), 'Breach', trim(d->>'breach'), 'Cure', trim(d->>'cure'),
      'Repeat_Text', '[[REPEAT]]');

  elsif p_template = '2c-14-day' then
    v_reason := coalesce(d->>'reason', 'rent');
    if v_reason not in ('rent', 'breach') then raise exception 'Choose unpaid rent or a breach.'; end if;
    if r->>(case v_reason when 'rent' then 'nonpayment_14_day' else 'breach_14_day' end) = 'no' then
      raise exception '%', case when l.federal_program is not null and v_reason = 'rent' then 'This is a federally covered tenancy: unpaid rent needs the 30-day notice, not a 14-day notice.'
                                else 'A lease longer than one year can''t be ended with a 14-day notice. Use the 30-day notice.' end;
    end if;
    v_prior := coalesce(nullif(d->>'prior_notice_on', '')::date, notice_prior_within_year(l.id, v_reason, v_mail));
    if v_prior is not null and v_prior < v_mail - 365 then v_prior := null; end if;
    if not v_mm and v_prior is null then
      raise exception 'A lease of a year or less can only get a 14-day notice within a year of an earlier % notice. None is on file: send the 5-day notice instead, or enter the earlier notice''s date.',
        case v_reason when 'rent' then 'pay-or-vacate' else 'breach' end;
    end if;
    v_days := 14;
    v_deadline := notice_deadline(v_mail, 14);
    v_title := 'FOURTEEN-DAY NOTICE TO VACATE';
    v_statute := 'Wis. Stat. § 704.17' || case when v_mm then '(1p)' || case v_reason when 'rent' then '(a)' else '(b)' end else '(2)' || case v_reason when 'rent' then '(a)' else '(b)' end end;
    if v_reason = 'rent' then
      v_due := lease_rent_due(l.id, v_mail);
      if v_due <= 0 then raise exception 'This lease has no unpaid rent.'; end if;
      v_month := date_trunc('month', v_mail)::date;
      v_cur := least(v_due, greatest((select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id and kind = 'charge'
        and gl_account in ('Rent Income', 'Rent Charge') and date_trunc('month', entry_date) = v_month), 0));
      v_txt := 'You are in default in the payment of rent. Unpaid rent: <b>' || to_char(v_due, money_) || '</b> (' || to_char(v_month, 'FMMonth YYYY') || ': ' ||
        to_char(v_cur, money_) || '; earlier months: ' || to_char(v_due - v_cur, money_) || ').';
      v_short := 'Rent of ' || to_char(v_due, money_) || ' is unpaid.';
    else
      if length(trim(coalesce(d->>'breach', ''))) < 10 then raise exception 'Describe the breach: what happened, where and when.'; end if;
      v_txt := 'You have broken your rental agreement: ' || repair_esc(trim(d->>'breach'));
      v_short := 'It is for a violation of your rental agreement.';
    end if;
    v_extra := jsonb_build_object('Reason_Text', '[[REASON]]', 'Reason_Short', '[[SHORT]]',
      'Prior_Text', case when v_prior is null then '' else '[[PRIOR]]' end);

  elsif p_template = '2c-28-day' then
    if not v_mm then raise exception 'Only a month-to-month tenancy is ended with a 28-day notice. A lease for a term ends on its end date: use the Notice of Nonrenewal (Renewals page).'; end if;
    if l.federal_program is not null and length(trim(coalesce(d->>'reason', ''))) < 10 then
      raise exception 'Section 8 / federal tenancy: state the cause for ending it (the HAP contract requires good cause).';
    end if;
    -- First month-end that is at least 28 days after the notice is given (given day = day 1).
    v_end := (date_trunc('month', v_given + 27) + interval '1 month' - interval '1 day')::date;
    if nullif(d->>'end_on', '') is not null then
      if (d->>'end_on')::date < v_end then raise exception 'The tenancy can end no earlier than %.', to_char(v_end, 'FMMM/FMDD/YYYY'); end if;
      if (d->>'end_on')::date <> (date_trunc('month', (d->>'end_on')::date) + interval '1 month' - interval '1 day')::date then raise exception 'A month-to-month tenancy ends on the last day of a month.'; end if;
      v_end := (d->>'end_on')::date;
    end if;
    v_days := 28; v_deadline := v_end;
    v_title := '28-DAY NOTICE TERMINATING MONTH-TO-MONTH TENANCY';
    v_statute := 'Wis. Stat. § 704.19';
    v_extra := jsonb_build_object('Termination_Date', to_char(v_end, v_fmt),
      'Reason_Text', case when nullif(trim(d->>'reason'), '') is null then '' else '[[REASON]]' end);
    v_txt := case when nullif(trim(d->>'reason'), '') is null then '' else '<p>Reason: ' || repair_esc(trim(d->>'reason')) || '</p>' end;
  else
    raise exception 'Unknown notice %.', p_template;
  end if;

  v_extra := v_extra || jsonb_build_object('_keep_signature', true, 'Tenant_First_Name', '[[FIRST]]',
    'Notice_Title', v_title, 'Notice_Statute', v_statute, 'Notice_Days', v_days::text,
    'Notice_Date', to_char(v_mail, 'FMMonth FMDD, YYYY'), 'Mail_Date', to_char(v_mail, 'FMMonth FMDD, YYYY'),
    'Deadline', to_char(v_deadline, v_fmt), 'Service_Method', case v_service when 'personal' then 'personal delivery' else 'certified mail' end);
  v_html := letter_fill((select html from letter_templates where legacy_id = p_template), l.id, v_extra);
  select letter_fill(email_html, l.id, v_extra), letter_fill(email_subject, l.id, v_extra - '_keep_signature') into v_email, v_subject from letter_templates where legacy_id = p_template;
  -- Parts built here from escaped values go in unescaped.
  v_html := replace(replace(replace(replace(v_html, '[[REPEAT]]', v_txt), '[[REASON]]', v_txt), '[[SHORT]]', v_short),
    '[[PRIOR]]', coalesce('<p>You were given a ' || case v_reason when 'rent' then 'notice for unpaid rent' else 'notice for breaking your rental agreement' end ||
      ' on ' || to_char(v_prior, 'FMMonth FMDD, YYYY') || ', less than one year ago.</p>', ''));
  v_html := replace(replace(v_html, '[[QUOTE]]', v_quote), '[[CONSEQ]]', v_conseq);
  v_email := replace(replace(v_email, '[[SHORT]]', v_short), '[[REASON]]', v_txt);

  return jsonb_build_object('template_id', (select id from letter_templates where legacy_id = p_template), 'template_name', (select name from letter_templates where legacy_id = p_template),
    'subject', case p_template when '2c-breach-cure' then case v_days when 5 then 'Five-Day' else 'Thirty-Day' end || ' Notice to Remedy Breach or Vacate'
      when '2c-14-day' then 'Fourteen-Day Notice to Vacate' else '28-Day Notice Terminating Tenancy' end, 'html', v_html, 'email_subject', v_subject, 'email_html', v_email,
    'days', v_days, 'deadline', v_deadline, 'prior_notice_on', v_prior, 'federal_program', l.federal_program, 'warning', v_warn);
end;
$$;
revoke all on function notice_build(text, uuid, date, jsonb, text) from public, anon, authenticated;

-- Unit 8 (Sir Grant) is a Section 8 tenancy: 30-day notices, copies to the housing authority,
-- and a stated cause for ending it.
update leases set federal_program = 'section8'
  where id = '64708ef0-7b8d-5681-a08d-2f9d3484c111' and federal_program is null;
