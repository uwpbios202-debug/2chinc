-- Unit 4 (Ashley Williams) work in lieu of rent. Decided by Stephen, 10/6/2026.
--   * Move-in work (paint, cleaning and floor preparation), one time, DONE: worth $550.
--     It was credited as two $900 credits ($1,800); corrected here to $550.
--   Nothing is deleted: the two $900 credits are reversed by new entries and stay visible, and the
--   $550 credit says what it replaces. The upcoming work is recorded on a draft agreement; its
--   credits are posted only after staff check the work (no credit is posted today).
-- Run once in the Supabase SQL editor. It stops if it has already run.
begin;

do $$
declare
  v_lease uuid; v_a bigint; v_b bigint; v_new bigint;
begin
  select l.id into v_lease from leases l join rental_units ru on ru.id = l.unit_id
   where ru.unit_number = '4' and l.status = 'active' and l.tenants_label ilike 'Ashley Williams%';
  if v_lease is null then raise exception 'Unit 4 lease not found'; end if;

  if exists (select 1 from lease_ledger_entries where lease_id = v_lease and kind = 'in_kind' and amount = -550 and entry_date = '2026-08-27') then
    raise exception 'Unit 4 work in lieu already corrected';
  end if;

  select id into v_a from lease_ledger_entries where lease_id = v_lease and kind = 'in_kind' and amount = -900 and description = 'Paint & Cleaning';
  select id into v_b from lease_ledger_entries where lease_id = v_lease and kind = 'in_kind' and amount = -900 and description = 'Floor preparation';
  if v_a is null or v_b is null then raise exception 'The two $900 credits were not found'; end if;

  -- 1. Reverse the two $900 credits (original entries stay).
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note) values
    (v_lease, 'Rent Income', '2026-08-27', 'reversal', 'Reversal', 'Reversal: Paint & Cleaning credit', 900, 'staff',
     'Reverses ledger entry ' || v_a || ' (an earlier record credited $900). The move-in work is worth $550 in total (Stephen, 10/6/2026).'),
    (v_lease, 'Rent Income', '2026-08-27', 'reversal', 'Reversal', 'Reversal: Floor preparation credit', 900, 'staff',
     'Reverses ledger entry ' || v_b || ' (an earlier record credited $900). The move-in work is worth $550 in total (Stephen, 10/6/2026).');

  -- 2. The one $550 credit for the finished move-in work.
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (v_lease, 'Rent Income', '2026-08-27', 'in_kind', 'Work in lieu of rent', 'Move-in work: paint, cleaning and floor preparation', -550, 'staff',
          'Work in lieu of rent, one time. Replaces two earlier credits of $900 each ($1,800); corrected to $550 (Stephen, 10/6/2026).')
  returning id into v_new;

  -- 3. Work log: one record for the finished work; the two old records keep their history.
  update work_logs set description = 'Paint, cleaning and floor preparation (move-in work)', value = 550, ledger_entry_id = v_new
   where lease_id = v_lease and description = 'Paint and cleaning';
  update work_logs set value = 0, description = 'Floor preparation (merged into the $550 move-in work above; it had been valued at $900)'
   where lease_id = v_lease and description = 'Floor preparation';

  -- (The upcoming jobs are set up as real agreements by supabase/people/unit4_work_system.sql.)
end $$;

commit;
