-- Owner requests, part 2 (Stephen, 10/12/2026): staff are emailed when an owner sends a request; urgent, safety and
-- housing-inspector requests also go to the board; and staff can send any request to the board as a DRAFT resolution.
-- A request is still never a charge: the board decides on the resolution (By-Laws §1500(3), §1500(5)).

alter table owner_requests add column if not exists resolution_id uuid references roca_resolutions(id);

-- Emails: the office always; the board (every current board seat with an email) when it is urgent, a safety hazard, or inspector-noted.
create or replace function owner_request_notify(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare r owner_requests; v_owner text; v_cat text; v_html text; v_board boolean; b record;
begin
  select * into r from owner_requests where id = p_id;
  select name into v_owner from condo_owners where id = r.owner_id;
  select label into v_cat from roca_request_categories where code = r.category;
  v_board := r.urgency in ('urgent', 'emergency') or r.safety or r.inspector_note;
  v_html := '<p>' || repair_esc(coalesce(v_owner, 'An owner')) || ' sent owner request <b>#' || r.number || '</b>: ' || repair_esc(r.subject) || '</p>'
    || '<p>' || repair_esc(coalesce(v_cat, '')) || ' · ' || case r.location when 'my_unit' then 'inside Unit ' || coalesce(r.unit_number, '') when 'both' then 'both buildings' else r.location end
    || ' · urgency: ' || r.urgency || case when r.safety then ' · SAFETY / HEALTH HAZARD' else '' end || case when r.inspector_note then ' · housing inspector noted' else '' end || '</p>'
    || '<p style="white-space:pre-wrap">' || repair_esc(left(r.description, 1500)) || '</p>'
    || '<p>Review it at https://2ndchinc.org/association-owners/roca1/requests/</p>';
  perform office_alert('roca_alert_email', 'owner_request', 'Owner request #' || r.number || case when v_board then ' (URGENT)' else '' end || ': ' || left(r.subject, 80), v_html);
  if v_board then
    for b in select distinct lower(o.email) as email from condo_ownerships s join condo_owners o on o.id = s.owner_id
             where s.is_current and s.board_position is not null and coalesce(o.email, '') like '%@%'
    loop
      insert into email_outbox (to_email, subject, html, kind) values (b.email, 'ROCA1 owner request #' || r.number || ' needs board attention: ' || left(r.subject, 80),
        v_html || '<p>The office will send it to the board as a resolution if it needs a vote.</p>', 'owner_request_board');
    end loop;
  end if;
end;
$$;
revoke all on function owner_request_notify(uuid) from public, anon, authenticated;

-- Same as part 1, plus the notification call.
create or replace function owner_request_create(p_location text, p_unit text, p_category text, p_subject text, p_description text,
  p_urgency text, p_safety boolean, p_inspector boolean, p_photos text[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); r owner_requests; v_scope text; v_budget text;
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_subject, ''))) < 3 or length(trim(coalesce(p_description, ''))) < 5 then raise exception 'Please say what needs attention and describe it.'; end if;
  select scope, budget_code into v_scope, v_budget from roca_request_categories where code = p_category;
  if v_scope is null then raise exception 'Choose what kind of problem it is.'; end if;
  if p_location = 'my_unit' or v_scope = 'unit' then
    if not exists (select 1 from condo_ownerships s join condo_units cu on cu.id = s.unit_id where s.is_current and s.owner_id = v_owner and cu.unit_number = p_unit) then
      raise exception 'Choose which of your units it is in.'; end if;
  end if;
  if exists (select 1 from unnest(coalesce(p_photos, '{}')) ph where split_part(ph, '/', 1)::uuid <> v_owner) then raise exception 'Bad photo path'; end if;
  insert into owner_requests (owner_id, location, unit_number, category, subject, description, urgency, safety, inspector_note, photos, budget_code)
  values (v_owner, case when v_scope = 'unit' then 'my_unit' else p_location end, nullif(p_unit, ''), p_category, trim(p_subject), trim(p_description),
          coalesce(nullif(p_urgency, ''), 'normal'), coalesce(p_safety, false), coalesce(p_inspector, false), coalesce(p_photos, '{}'), v_budget)
  returning * into r;
  insert into owner_request_updates (request_id, by_role, by_email, note) values (r.id, 'owner', auth.email(), 'Request sent.');
  perform owner_request_notify(r.id);
  return jsonb_build_object('number', r.number);
end;
$$;
revoke all on function owner_request_create(text, text, text, text, text, text, boolean, boolean, text[]) from public, anon;
grant execute on function owner_request_create(text, text, text, text, text, text, boolean, boolean, text[]) to authenticated;

-- Same as part 1, plus the resolution link.
create or replace function owner_requests_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'owner', o.name, 'owner_email', o.email, 'owner_phone', o.phone_mobile,
        'location', r.location, 'unit', r.unit_number, 'category', c.label, 'subject', r.subject, 'description', r.description, 'urgency', r.urgency, 'safety', r.safety,
        'inspector_note', r.inspector_note, 'photos', r.photos, 'status', r.status, 'priority_id', r.priority_id, 'budget_code', r.budget_code, 'estimate', r.estimate,
        'response', r.response, 'created_at', r.created_at, 'resolution_id', r.resolution_id,
        'resolution', (select jsonb_build_object('number', x.number, 'status', x.status) from roca_resolutions x where x.id = r.resolution_id),
        'updates', coalesce((select jsonb_agg(jsonb_build_object('at', u.at, 'by', u.by_role, 'email', u.by_email, 'note', u.note, 'internal', u.internal) order by u.at)
                   from owner_request_updates u where u.request_id = r.id), '[]'::jsonb))
        order by (r.status in ('done', 'declined', 'withdrawn')), case r.urgency when 'emergency' then 0 when 'urgent' then 1 when 'normal' then 2 else 3 end, r.created_at desc)
        from owner_requests r join condo_owners o on o.id = r.owner_id join roca_request_categories c on c.code = r.category), '[]'::jsonb),
    'priorities', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'rank', p.rank_label, 'title', p.title, 'estimate', p.estimate, 'status', p.status, 'urgent', p.urgent)
        order by p.sort) from roca_repair_priorities p), '[]'::jsonb));
end;
$$;
revoke all on function owner_requests_staff_list() from public, anon;
grant execute on function owner_requests_staff_list() to authenticated;

-- Staff: draft a board resolution from a request. Nothing is charged or decided; the board votes on it in the board area.
create or replace function owner_request_staff_send_to_board(p_id uuid)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare r owner_requests; v_owner text; v_cat text; v_res uuid; b record; v_loc text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from owner_requests where id = p_id;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.resolution_id is not null then return r.resolution_id; end if;
  select name into v_owner from condo_owners where id = r.owner_id;
  select label into v_cat from roca_request_categories where code = r.category;
  v_loc := case r.location when 'my_unit' then 'inside Unit ' || coalesce(r.unit_number, '') when 'both' then 'both buildings' else r.location || ' N Bourbon St' end;
  v_res := roca_resolution_propose('other', 'Owner request #' || r.number || ': ' || r.subject,
    'RESOLVED, that the Board take up owner request #' || r.number || ' (' || coalesce(v_cat, 'repair') || ', ' || v_loc || '): ' || r.subject || E'.\n\n' || r.description
      || E'\n\nSubmitted by ' || coalesce(v_owner, 'an owner') || ', urgency ' || r.urgency || case when r.safety then ', reported as a safety or health hazard' else '' end
      || case when r.inspector_note then ', noted by a housing inspector' else '' end
      || coalesce(E'\nBudget code ' || r.budget_code, '') || coalesce(E'\nEstimate $' || to_char(r.estimate, 'FM999,999,990.00'), '')
      || E'\n\nThis resolution only records the Board''s decision on the request. Any special assessment to an owner needs its own vote (By-Laws §1500(3), §1500(5)).',
    'board_majority_all', jsonb_build_object('owner_request_id', r.id, 'owner_request_number', r.number), 'manual', 'Drafted from owner request #' || r.number, auth.email());
  update owner_requests set resolution_id = v_res, status = case when status = 'new' then 'reviewing' else status end, updated_at = now() where id = p_id;
  insert into owner_request_updates (request_id, by_role, by_email, note) values (p_id, 'staff', auth.email(), 'Sent to the board for a decision.');
  for b in select distinct lower(o.email) as email from condo_ownerships s join condo_owners o on o.id = s.owner_id
           where s.is_current and s.board_position is not null and coalesce(o.email, '') like '%@%'
  loop
    insert into email_outbox (to_email, subject, html, kind) values (b.email, 'For the board: owner request #' || r.number || ' ' || left(r.subject, 80),
      '<p>A resolution was drafted from owner request #' || r.number || ': <b>' || repair_esc(r.subject) || '</b>.</p><p>Nothing is decided until it is opened for a vote. Review it at https://2ndchinc.org/association-owners/roca1/board/</p>', 'owner_request_board');
  end loop;
  return v_res;
end;
$$;
revoke all on function owner_request_staff_send_to_board(uuid) from public, anon;
grant execute on function owner_request_staff_send_to_board(uuid) to authenticated;
