-- One-time load of Royal Orleans units, owners and ownership history into the
-- owner-portal tables (schema: supabase/migrations/*_condo_owner_portal.sql).
-- Built from the "Royal Orleans Owners" artifact as of 2026-10-03, with Unit 18
-- corrected to Dolly Williams from 8/2016 (Stephen, 10/3/2026).
-- CONTAINS OWNER PERSONAL DATA: lives in lease/data/ (gitignored). Never
-- commit it to git.
--
-- Locally: npx supabase db reset loads it automatically (see ROADMAP.md).
-- Production (later): run once in the live project's SQL editor.
begin;

do $$ begin
  if exists (select 1 from condo_owners) then
    raise exception 'condo_owners already has rows; this seed only runs on an empty portal';
  end if;
end $$;

insert into condo_units (unit_number, address, pin, size_sqft, bedrooms, bathrooms, fee_allocation_pct, occupancy) values
  ('1',  '6626 North Bourbon Street - 1',  '1450451000', 760, '2 Bed', '1 Bath', 6.25, 'owner'),
  ('2',  '6626 North Bourbon Street - 2',  '1450452000', 760, '2 Bed', '1 Bath', 0,    'tenant'),
  ('3',  '6626 North Bourbon Street - 3',  '1450453000', 760, '2 Bed', '1 Bath', 6.25, 'tenant'),
  ('4',  '6626 North Bourbon Street - 4',  '1450454000', 760, '2 Bed', '1 Bath', 6.25, 'tenant'),
  ('5',  '6626 North Bourbon Street - 5',  '1450455000', 760, '2 Bed', '1 Bath', 6.25, 'tenant'),
  ('6',  '6626 North Bourbon Street - 6',  '1450456000', 760, '2 Bed', '1 Bath', 0,    'tenant'),
  ('7',  '6626 North Bourbon Street - 7',  '1450457000', 760, '2 Bed', '1 Bath', 0,    'owner'),
  ('8',  '6626 North Bourbon Street - 8',  '1450458000', 760, '2 Bed', '1 Bath', 0,    'tenant'),
  ('11', '6622 North Bourbon Street - 11', '1450459000', 970, '2 Bed', '1 Bath', 0,    'tenant'),
  ('12', '6622 North Bourbon Street - 12', '1450460000', 760, '2 Bed', '1 Bath', 0,    'tenant'),
  ('13', '6622 North Bourbon Street - 13', '1450461000', 760, '2 Bed', '1 Bath', 0,    'owner'),
  ('14', '6622 North Bourbon Street - 14', '1450462000', 900, '2 Bed', '1 Bath', 6.25, 'tenant'),
  ('15', '6622 North Bourbon Street - 15', '1450463000', 760, '2 Bed', '1 Bath', 6.25, 'vacant'),
  ('16', '6622 North Bourbon Street - 16', '1450464000', 760, '2 Bed', '1 Bath', 0,    'tenant'),
  ('17', '6622 North Bourbon Street - 17', '1450465000', 760, '2 Bed', '1 Bath', 0,    'vacant'),
  ('18', '6622 North Bourbon Street - 18', '1450466000', 900, '2 Bed', '1 Bath', 6.25, 'vacant');

insert into condo_owners (name, email, alt_email, phone_mobile, communications_preference,
  mailing_line1, mailing_city, mailing_state, mailing_zip,
  alt_line1, alt_city, alt_state, alt_zip,
  emergency_name, emergency_phone, staff_notes, buildium_ids) values
  ('Mark Postler', 'markpostler13@gmail.com', null, '(414) 760-0318', 'Mailing',
    '6622 North Bourbon Street - 13', 'Milwaukee', 'WI', '53224', null, null, null, null, null, null, null,
    '{2777899,2780127,2803864}'),
  ('2nd Chance Housing Inc', 'info@2ndchinc.org', null, '(262) 236-5443', 'Mailing',
    '6626 N Bourbon St', 'Milwaukee', 'WI', '53224', null, null, null, null, null, null,
    'Buildium note (unit 5 record): Looking forward to working together. Need the tenants information to enter in the system',
    '{2778252,2780123}'),
  ('Leon Frontczak', 'frontczakleon@gmail.com', null, '(414) 501-8375', 'Mailing',
    '6626 North Bourbon Street - 1', 'Milwaukee', 'WI', '53224', null, null, null, null, null, null, null, '{2779839}'),
  ('JAMES E SIMMONS', 'Jamessimmons459@gmail.com', null, '(414) 553-4419', 'Mailing',
    '6626 North Bourbon Street - 2', 'Milwaukee', 'WI', '53224', null, null, null, null, null, null, null, '{2783826}'),
  ('Dorotea Hogans-Blaylock', 'Dhogansb@gmail.com', null, '(414) 651-2474', 'Email',
    '6622 North Bourbon Street - 16', 'Milwaukee', 'WI', '53224', null, null, null, null,
    'Monica Hogans', '(414) 651-2466', 'Buildium note: 6214 W PORT AVE UNIT 16', '{2784017}'),
  ('Richard R Lewis', 'royalorleansone@gmail.com', null, '(414) 333-1728', 'Mailing',
    '6622 North Bourbon Street - 12', 'Milwaukee', 'WI', '53224', null, null, null, null, null, null,
    E'12-22-2005 Lien $1,444.50\n04-08-2015 Lien $4,450.00', '{2786658}'),
  ('Doni A Palmer-Stanback', 'palmerds19812018@gmail.com', null, '(414) 554-4189', 'Email',
    '6626 North Bourbon Street - 7', 'Milwaukee', 'WI', '53224', null, null, null, null,
    'Marious Jones', '(414) 739-7710', null, '{2786980}'),
  ('John Wamser', 'Wamserjf@gmail.com', 'mrsrojasdelvlle@gmail.com', '(414) 217-0005', 'Mailing',
    '6626 North Bourbon Street - 6', 'Milwaukee', 'WI', '53224', null, null, null, null, null, null, null, '{2799509}'),
  ('Frederick J Haney', 'itsyourmove.realtors@gmail.com', null, '(414) 554-3188', 'Mailing',
    '6626 North Bourbon Street - 8', 'Milwaukee', 'WI', '53224',
    '9422 North Goldendale Drive', 'Brown Deer', 'WI', '53223', null, null, null, '{2823879}'),
  ('Yawdcour LLC', null, null, '(414) 909-3279', 'Mailing',
    '6622 North Bourbon Street - 11', 'Milwaukee', 'WI', '53224', null, null, null, null, null, null, null, '{2911661}'),
  -- Unit 18 owner per Stephen's decision (incoming/Unit18_record.md). Buildium
  -- rental-owner record 5876550 has email + mobile only, so the mailing address
  -- defaults to the unit address like everyone else.
  ('Dolly Williams', 'marygates2749@yahoo.com', null, '(414) 301-2457', 'Mailing',
    '6622 North Bourbon Street - 18', 'Milwaukee', 'WI', '53224', null, null, null, null, null, null,
    'Owner of Unit 18 since 8/2016. Buildium mislabeled her association account (Mark Postler 2016-2022, 2nd Chance Housing from 5/24/2022); corrected 10/3/2026.',
    '{5876550}');

-- Ownership history: (unit, owner's Buildium id, start, current, dues, board seat, Buildium account #)
insert into condo_ownerships (unit_id, owner_id, start_date, is_current, fee, board_position, buildium_account)
select u.id, o.id, v.start_date::date, v.is_current, v.fee, v.board_position, v.account
from (values
  ('1',  '2779839', '2019-12-01', true,  215, null,        '01441165'),
  ('2',  '2783826', '2014-06-01', false, 170, null,        null),
  ('2',  '2777899', '2020-07-01', false, 215, null,        null),
  ('2',  '2778252', '2022-05-24', true,  215, 'President', '02047300'),
  ('3',  '2777899', '2017-11-01', false, 215, null,        null),
  ('3',  '2778252', '2022-05-24', true,  215, 'Treasurer', '02047299'),
  ('4',  '2778252', '2016-12-01', true,  215, null,        '01440163'),
  ('5',  '2780123', '2019-12-01', true,  215, null,        '01441302'),
  ('6',  '2799509', '2019-12-01', true,  215, null,        '01451191'),
  ('7',  '2786980', '2004-04-01', true,  215, 'Secretary', '01444549'),
  ('8',  '2823879', '2006-01-01', true,  215, null,        '01444425'),
  ('11', '2911661', '2017-08-01', false, 215, null,        null),
  ('11', '2778252', '2022-05-24', true,  215, null,        '02047301'),
  ('12', '2786658', '2004-05-01', true,  215, null,        '01444428'),
  ('13', '2803864', '2009-12-01', true,  215, null,        '01453793'),
  ('14', '2777899', '2019-12-01', false, 215, null,        null),
  ('14', '2778252', '2022-05-24', true,  215, null,        '02047297'),
  ('15', '2780127', '2019-12-01', true,  215, null,        '01441303'),
  ('16', '2784017', '2014-12-01', true,  215, null,        '01443087'),
  ('17', '2777899', '2021-04-05', true,  215, null,        '01760382'),
  -- Dolly Williams from 8/2016 (Stephen 10/3/2026). Buildium printed the 2016-2022
  -- account under Mark Postler and 2022 on under 2nd Chance Housing; both were wrong.
  ('18', '5876550', '2016-08-01', true,  215, null,        '02047298')
) as v(unit_number, buildium_id, start_date, is_current, fee, board_position, account)
join condo_units u on u.unit_number = v.unit_number
join condo_owners o on v.buildium_id = any(o.buildium_ids);

-- Staff who can open /owners/staff.html. Each needs a mobile number for the
-- texted sign-in code. FILL IN the phone numbers before applying.
insert into condo_staff (email, name, phone_mobile) values
  ('mkepropertymanager@gmail.com', 'Albert Harris', '(414) 909-3279'),
  ('stephen@selassiefest.com', 'Stephen Henry', '(262) 344-7075');

-- Sanity checks: 16 units, 12 owners, 22 ownerships, 16 current.
do $$ begin
  if (select count(*) from condo_units) <> 16 then raise exception 'expected 16 units'; end if;
  if (select count(*) from condo_owners) <> 12 then raise exception 'expected 12 owners'; end if;
  if (select count(*) from condo_ownerships) <> 22 then raise exception 'expected 22 ownerships'; end if;
  if (select count(*) from condo_ownerships where is_current) <> 16 then raise exception 'expected 16 current ownerships'; end if;
end $$;

commit;
