-- Eviction costs: everything on the list is charged to the owner, including office time (Stephen, 11/11/2026).
-- Sample figures: Notice preparation $5.00, Court appearances $100.00. Set on the office template and on every owner copy where the row is
-- still $0 (an amount someone already entered is left alone). Unit 15's agreement (still a draft) says so in section 5a.

update eviction_sheet_items i set amount = 5.00, note = 'Sample figure: $5.00 (forms, printing, office time).'
  from eviction_sheets s where s.id = i.sheet_id and (s.is_template or s.owner_unit is not null) and i.expense = 'Notice preparation' and i.amount = 0;
update eviction_sheet_items i set amount = 100.00, note = 'Sample figure: $100.00 (office time at court, parking, mileage).'
  from eviction_sheets s where s.id = i.sheet_id and (s.is_template or s.owner_unit is not null) and i.expense = 'Court appearances' and i.amount = 0;
update eviction_sheets set updated_at = now() where is_template or owner_unit is not null;

do $$
declare a pma_agreements; v_old text; v_new text;
begin
  select * into a from pma_agreements where unit_number = '15' and status = 'draft';
  if a.id is null then return; end if;
  select s->>'body' into v_old from jsonb_array_elements(a.sections) s where s->>'key' = 's5a';
  if v_old is null or position('Everything on the eviction list' in v_old) > 0 then return; end if;
  v_new := replace(replace(v_old,
    'If a tenant has to be evicted, the costs of the eviction are the Owner''s expense, like any other cost of renting the Property. They include',
    'If a tenant has to be evicted, the costs of the eviction are the Owner''s expense, like any other cost of renting the Property. Everything on the eviction list in Exhibit A is charged to the Owner, including Manager''s office time (for example notice preparation, $5.00, and each court appearance, $100.00). The list includes'),
    '5. Rent lost during an eviction and while the unit is empty is not a charge from Manager. Exhibit A shows it only so the Owner can see what an eviction can cost in total.',
    '5. Rent lost during an eviction and while the unit is empty is the Owner''s loss; Exhibit A shows it so the Owner can see what an eviction can cost in total.');
  if v_new = v_old then raise exception 'Section 5a text did not match; nothing changed.'; end if;
  update pma_agreements set
    sections = (select jsonb_agg(case when s->>'key' = 's5a' then jsonb_set(s, '{body}', to_jsonb(v_new)) else s end order by o) from jsonb_array_elements(a.sections) with ordinality x(s, o)),
    version = version + 1, updated_at = now()
  where id = a.id;
  insert into pma_changes (agreement_id, version, section_key, old_body, new_body, note, by_email)
  values (a.id, a.version + 1, 's5a', v_old, v_new, 'Everything on the eviction list is charged to the Owner, including office time (Stephen)', 'info@2ndchinc.org');
end $$;
