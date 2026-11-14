-- Menards receipts (Stephen, 11/8/2026): no Anthropic account for 2nd Chance, so receipts are now read on the staff member's own
-- computer or phone (free text reader in the page; Menards PDFs are read directly). The text that was read is kept with the receipt.
-- The menards-read function is removed, and so is its cost line.

delete from system_cost_items where name = 'Claude API (Menards receipts)';

create or replace function menards_receipt_save(p jsonb)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid := (p->>'id')::uuid; b jsonb; v_keep uuid[] := '{}'; v_bid uuid;
begin
  perform menards_staff_only();
  if v_id is null then raise exception 'Receipt id missing'; end if;
  insert into menards_receipts (id, created_by) values (v_id, lower(auth.email())) on conflict (id) do nothing;
  update menards_receipts set
    store = nullif(trim(p->>'store'), ''),
    purchased_on = nullif(p->>'purchased_on', '')::date,
    receipt_no = nullif(trim(p->>'receipt_no'), ''),
    for_what = nullif(trim(p->>'for_what'), ''),
    subtotal = nullif(p->>'subtotal', '')::numeric,
    tax = nullif(p->>'tax', '')::numeric,
    total = nullif(p->>'total', '')::numeric,
    paid_with = nullif(trim(p->>'paid_with'), ''),
    items = coalesce(p->'items', items),
    files = coalesce((select array_agg(x) from jsonb_array_elements_text(p->'files') x where x like v_id::text || '/%'), files),
    ai_read = case when p ? 'read_text' and coalesce(p->>'read_text', '') <> '' then jsonb_build_object('text', left(p->>'read_text', 20000)) else ai_read end,
    ai_read_at = case when p ? 'read_text' and coalesce(p->>'read_text', '') <> '' then coalesce(ai_read_at, now()) else ai_read_at end,
    notes = nullif(trim(p->>'notes'), ''),
    updated_at = now()
  where id = v_id;
  for b in select * from jsonb_array_elements(coalesce(p->'rebates', '[]'::jsonb)) loop
    v_bid := nullif(b->>'id', '')::uuid;
    if v_bid is null or not exists (select 1 from menards_rebates where id = v_bid and receipt_id = v_id) then
      insert into menards_rebates (receipt_id) values (v_id) returning id into v_bid;
    end if;
    update menards_rebates set
      rebate_number = nullif(trim(b->>'rebate_number'), ''),
      description = nullif(trim(b->>'description'), ''),
      amount = coalesce(nullif(b->>'amount', '')::numeric, 0),
      mail_by = nullif(b->>'mail_by', '')::date,
      mail_to = nullif(trim(b->>'mail_to'), ''),
      status = coalesce(nullif(b->>'status', ''), 'to_mail'),
      mailed_on = nullif(b->>'mailed_on', '')::date,
      received_on = nullif(b->>'received_on', '')::date,
      check_amount = nullif(b->>'check_amount', '')::numeric,
      notes = nullif(trim(b->>'notes'), ''),
      updated_at = now()
    where id = v_bid;
    v_keep := v_keep || v_bid;
  end loop;
  delete from menards_rebates where receipt_id = v_id and not (id = any (v_keep));
  return v_id;
end;
$$;
revoke all on function menards_receipt_save(jsonb) from public, anon;
grant execute on function menards_receipt_save(jsonb) to authenticated;
