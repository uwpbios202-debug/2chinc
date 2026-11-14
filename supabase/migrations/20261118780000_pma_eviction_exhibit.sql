-- Management agreements: eviction costs tied in (Stephen, 11/11/2026). "One email and he gets everything to review."
-- 1. New section "5a. Eviction costs" in the Unit 15 agreement (still a draft): eviction costs are the Owner's, shown with receipts on the statement.
-- 2. Exhibit A = the owner's own eviction budget for that unit (eviction_sheets.owner_unit; the office template if there is none yet),
--    shown on the agreement page, in the review email and in the signed PDF. It is an estimate, not a price.
-- 3. The "ready for review" email now carries the whole agreement text and Exhibit A, plus the link.

create or replace function pma_eviction_sheet_id(p_unit text)
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce((select id from eviction_sheets where owner_unit = p_unit), (select id from eviction_sheets where is_template));
$$;
revoke all on function pma_eviction_sheet_id(text) from public, anon, authenticated;

create or replace function pma_eviction_sheet(p_unit text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('title', s.title, 'note', s.note, 'updated_at', s.updated_at, 'owner_copy', s.owner_unit is not null,
    'total', (select coalesce(sum(i.amount), 0) from eviction_sheet_items i where i.sheet_id = s.id),
    'items', coalesce((select jsonb_agg(jsonb_build_object('expense', i.expense, 'covers', i.covers, 'status', i.status, 'amount', i.amount, 'note', i.note) order by i.sort)
                       from eviction_sheet_items i where i.sheet_id = s.id), '[]'::jsonb))
    from eviction_sheets s where s.id = pma_eviction_sheet_id(p_unit);
$$;
revoke all on function pma_eviction_sheet(text) from public, anon, authenticated;

-- The agreement page gets Exhibit A too.
create or replace function pma_json(a pma_agreements)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) - 'owner_signed_ip' - 'president_signed_ip' - 'owner_signed_hash' - 'president_signed_hash'
    || jsonb_build_object('role', pma_role(a), 'view_as', autopay_view_as_session(), 'contact', pma_owner_contact(a.owner_id),
       'hash', pma_hash(a), 'eviction', pma_eviction_sheet(a.unit_number),
       'suggestions', coalesce((select jsonb_agg((to_jsonb(s) - 'by_email') || jsonb_build_object('mine', s.by_email = lower(coalesce(auth.email(), ''))) order by s.created_at) from pma_suggestions s where s.agreement_id = a.id), '[]'::jsonb),
       'changes', coalesce((select jsonb_agg(jsonb_build_object('version', c.version, 'section_key', c.section_key, 'note', c.note, 'created_at', c.created_at,
                                                                'old_body', c.old_body, 'new_body', c.new_body) order by c.id) from pma_changes c where c.agreement_id = a.id), '[]'::jsonb));
$$;
revoke all on function pma_json(pma_agreements) from public, anon, authenticated;

-- The whole agreement as email HTML: every section, the owner's address on file, and Exhibit A.
create or replace function pma_agreement_html(a pma_agreements)
returns text language sql stable security definer set search_path = public as $$
  select '<div style="border:1px solid #ccc;padding:12px 16px;margin:12px 0;font:14px/1.5 Georgia,serif">'
    || '<h2 style="margin:0 0 4px;text-align:center">PROPERTY MANAGEMENT AGREEMENT</h2><p style="text-align:center;margin:0 0 12px">Unit ' || repair_esc(a.unit_number) || ', 6622 N Bourbon St · version ' || a.version || '</p>'
    || coalesce((select string_agg('<h3 style="margin:14px 0 4px;font-size:15px">' || repair_esc(s->>'title') || '</h3><div style="white-space:pre-wrap">' || repair_esc(s->>'body') || '</div>', '' order by o)
                   from jsonb_array_elements(a.sections) with ordinality x(s, o)), '')
    || '<h3 style="margin:14px 0 4px;font-size:15px">Owner''s address for statements and notices</h3><div>Mailing address on file: ' || repair_esc(coalesce(pma_owner_contact(a.owner_id)->>'mail_to', '(none on file)'))
    || '<br>Phone on file: ' || repair_esc(coalesce(pma_owner_contact(a.owner_id)->>'phone', '(none on file)')) || '</div></div>'
    || '<h2 style="margin:18px 0 4px">Exhibit A: what an eviction costs (estimate)</h2>'
    || '<p>This is the eviction expense budget for Unit ' || repair_esc(a.unit_number) || ' that section 5a refers to. Court and Sheriff fees change; rows marked "to be entered" depend on the case.</p>'
    || coalesce(eviction_sheet_html(pma_eviction_sheet_id(a.unit_number)), '');
$$;
revoke all on function pma_agreement_html(pma_agreements) from public, anon, authenticated;

-- Send for review: one email with everything (agreement text + Exhibit A + link).
create or replace function pma_staff_send(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a pma_agreements := pma_lock(p_id);
begin
  if pma_role(a) not in ('office', 'president') then raise exception 'Office staff only.' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not while viewing as someone else.'; end if;
  if a.status <> 'draft' then raise exception 'It has already been sent.'; end if;
  update pma_agreements set status = 'review', updated_at = now() where id = p_id;
  perform pma_circulate(a, a.title || ': ready for your review',
    '<p>The ' || repair_esc(a.title) || ' between ' || repair_esc(a.owner_name) || ' and ROCA1 (with its management partner, 2nd Chance Housing Inc) is ready for review. '
    || 'Everything is in this email: the full agreement, and Exhibit A, which shows what an eviction costs and how those charges are handled (section 5a).</p>'
    || '<p><b>How to review:</b> open the link at the bottom and sign in with your email. Under each section there is a "Suggest a change" button: write the wording you would like, or a question. '
    || 'Every suggestion goes to everyone, and the office answers it. When everything is agreed, you each sign online, and the signed copy is filed in the owner''s Documents, ready to print.</p>'
    || pma_agreement_html(a), 'pma_review');
end;
$$;
revoke all on function pma_staff_send(uuid) from public, anon;
grant execute on function pma_staff_send(uuid) to authenticated;

-- Unit 15 (draft): add section 5a after section 5, and point section 2's figures at it.
do $$
declare a pma_agreements; v_new jsonb;
begin
  select * into a from pma_agreements where unit_number = '15' and status = 'draft';
  if a.id is null or a.sections @> '[{"key":"s5a"}]' then return; end if;
  select jsonb_agg(s order by o) into v_new from (
    select s, o::numeric o from jsonb_array_elements(a.sections) with ordinality x(s, o)
    union all
    select jsonb_build_object('key', 's5a', 'title', '5a. Eviction costs', 'body', $t$If a tenant has to be evicted, the costs of the eviction are the Owner's expense, like any other cost of renting the Property. They include notice preparation and certified mailing, the court filing fee, service of the summons, the writ of restitution, the Sheriff's eviction fee, a locksmith, removing or storing the tenant's property, cleaning and repairs to re-rent, advertising, and utilities while the unit is empty.

1. Exhibit A (the eviction expense budget for Unit 15) lists each cost and the fees known today. It is an estimate, not a price: court and Sheriff fees change, and some costs depend on the case. The Owner can see it at any time in the owner portal under Eviction costs.
2. Manager tells the Owner before filing in court, and does not hire an attorney without the Owner's approval (section 5).
3. Each cost is shown on the Owner's statement with its receipt and is taken out of the Owner's next portion. If the portion does not cover it, the Owner deposits the rest into the Property Account (section 4).
4. Costs the court awards against the tenant in the judgment (Wis. Stat. 799.25), when collected from the tenant, are paid back to the Owner.
5. Rent lost during an eviction and while the unit is empty is not a charge from Manager. Exhibit A shows it only so the Owner can see what an eviction can cost in total.
6. Notices and court filings ask for unpaid rent only; late fees are never part of them (section 5).$t$),
      (select o::numeric + 0.5 from jsonb_array_elements(a.sections) with ordinality x(s, o) where s->>'key' = 's5')) y(s, o);
  update pma_agreements set sections = v_new, version = version + 1, updated_at = now() where id = a.id;
  insert into pma_changes (agreement_id, version, section_key, old_body, new_body, note, by_email)
  values (a.id, a.version + 1, 's5a', null, (select s->>'body' from jsonb_array_elements(v_new) s where s->>'key' = 's5a'), 'Section 5a (eviction costs) and Exhibit A added before review', 'info@2ndchinc.org');
end $$;
