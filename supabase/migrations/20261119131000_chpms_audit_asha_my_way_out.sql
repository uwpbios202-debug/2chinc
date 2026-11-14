-- CHPMS audit, 11/12/2026 (Stephen pasted two outside research answers on the two possible duplicates flagged by 20261119110000).
--
-- My Way Out: both answers and our own records agree it is ONE program (United Way Safe & Stable Homes, source S044).
--   The research entry PRG040 keeps it and takes the details only the 11/11 directory had (security deposit + up to 3 months of rent);
--   the copied entry AID-MKE-072-P1 is removed (no referral points to it; its history rows stay).
-- Asha: the answers disagreed. Checked: both of OUR Asha entries came from United Way's Asha page, so they describe the same United Way
--   program; PRG026 keeps it and takes the copied details (landlord mediation). Separately, HUD's FY2021 Wisconsin CoC award report lists
--   "The Asha Project - DVHF Joint TH-RRH" ($581,301), a different, HUD-funded program; the copied entry AID-MKE-070-P1 is rewritten as
--   that program, marked Needs Confirmation (no later HUD listing names Asha; the FY2023/FY2024 DV Bonus awards are listed under
--   Milwaukee County, and whether Asha delivers them is not confirmed). Nothing is estimated.

-- ---------- My Way Out: merge into PRG040
update chpms_programs set
  program_name = 'Safe & Stable Homes: reentry housing placement, rent help and wraparound',
  months_covered = 'Up to 3 months of rent (11/11 directory, from United Way''s My Way Out page)',
  pays_security_deposit = 'Yes (11/11 directory, from United Way''s My Way Out page)',
  eligibility_summary = 'Justice-impacted participants with children (returning citizens reuniting with family). Security deposit plus up to 3 months of rent, with case management.',
  notes = concat_ws(' ', notes, 'Audit 11/12/2026: merged with the 11/11 directory''s "Reentry Housing Assistance" (same program; United Way page https://unitedwaygmwc.org/Agencies/My-Way-Out.htm). My Way Out runs one housing program.'),
  staff_edited_at = now(), staff_edited_by = 'Audit 11/12/2026', updated_at = now()
where program_id = 'PRG040';
update chpms_program_assist set provided = true
where program_id = 'PRG040' and category in ('Emergency rental assistance', 'Security deposit assistance');
delete from chpms_programs where program_id = 'AID-MKE-072-P1' and is_local;
insert into chpms_checks (record_type, record_id, status, method, notes, by_role)
values ('program', 'PRG040', 'Verified – Limited', 'Office edit',
        'Audit 11/12: merged with the 11/11 directory''s "Reentry Housing Assistance" (AID-MKE-072-P1, removed): added up to 3 months of rent and the security deposit.', 'staff'),
       ('program', 'AID-MKE-072-P1', null, 'Office edit', 'Audit 11/12: removed as a duplicate of PRG040 (My Way Out runs one housing program).', 'staff');

-- ---------- Asha: the United Way program is PRG026
update chpms_programs set
  eligibility_summary = concat_ws(' ', eligibility_summary, '(DV/IPV survivors.) Flexible money with case management; landlord mediation.'),
  notes = concat_ws(' ', notes, 'Audit 11/12/2026: this is the program the 11/11 directory listed as "DV Housing First" (both came from United Way''s Asha page, https://www.unitedwaygmwc.org/Agencies/Asha-Family-Services.htm). Asha Family Services and The Asha Project are the same organization.'),
  staff_edited_at = now(), staff_edited_by = 'Audit 11/12/2026', updated_at = now()
where program_id = 'PRG026';
update chpms_program_assist set provided = true where program_id = 'PRG026' and category = 'Landlord mediation';

-- ---------- Asha: the copied entry becomes the HUD-funded DV Housing First program
update chpms_programs set
  program_name = 'DV Housing First: joint transitional housing and rapid re-housing (HUD Continuum of Care)',
  assistance_form = 'Transitional housing, then rapid re-housing (rent help with a housing case manager)',
  payment_goes_to = null,
  max_assistance = 'Not publicly disclosed',
  current_status = 'Needs confirmation. Last HUD listing found naming Asha is FY2021; later DV Bonus awards (FY2023 $942,275, FY2024 $1,038,640) are listed under Milwaukee County, and whether Asha delivers them is not confirmed.',
  funding_dependency = 'HUD Continuum of Care, Milwaukee WI-501. FY2021 award: "The Asha Project - DVHF Joint TH-RRH" $581,301 (HUD FY2021 Wisconsin award report).',
  eligibility_summary = 'Domestic violence survivors experiencing homelessness (Housing First: no sobriety, income or program conditions, per the DV Housing First model).',
  how_to_apply = 'Ask Asha, (414) 875-1511. Confirm with the CoC lead whether this housing is filled through Coordinated Entry (211).',
  verification_status = 'Needs Confirmation',
  notes = 'Audit 11/12/2026: a different program from Asha''s United Way flexible assistance (PRG026). Sources: https://www.hud.gov/sites/dfiles/CPD/documents/FY2021_WI_Press_Report.pdf (FY2021), https://hud.gov/sites/dfiles/CPD/documents/CoC-2023-WI_Press.pdf (FY2023), https://www.hud.gov/sites/dfiles/CPD/documents/CoC/CoC-2024-WI_Press.pdf (FY2024). Confirm with Asha or the CoC lead before referring.',
  updated_at = now()
where program_id = 'AID-MKE-070-P1' and is_local;
update chpms_program_assist set provided = category in ('Transitional housing', 'Rapid rehousing', 'Case management')
where program_id = 'AID-MKE-070-P1';
insert into chpms_program_pops (program_id, population) values ('AID-MKE-070-P1', 'Experiencing homelessness') on conflict do nothing;
insert into chpms_checks (record_type, record_id, status, method, notes, by_role)
values ('program', 'PRG026', 'Verified – Limited', 'Office edit',
        'Audit 11/12: same United Way program the 11/11 directory listed as "DV Housing First"; added landlord mediation.', 'staff'),
       ('program', 'AID-MKE-070-P1', 'Needs Confirmation', 'Office edit',
        'Audit 11/12: rewritten as Asha''s HUD CoC DV Housing First joint TH-RRH program (FY2021 award $581,301); current funding not confirmed.', 'staff');

do $$ begin
  if exists (select 1 from chpms_programs where program_id = 'AID-MKE-072-P1') then raise exception 'Audit: duplicate not removed'; end if;
  if (select count(*) from chpms_programs where org_id = 'ORG023') <> 2 or (select count(*) from chpms_programs where org_id = 'ORG051') <> 1 then
    raise exception 'Audit: unexpected program counts'; end if;
end $$;
