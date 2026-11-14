-- Email a unit (https://2ndchinc.org/staff/email/): simple formatting and attachments (Stephen, 11/1/2026).
-- Formatting a staff member can type: **bold**, *italic*, [link text](https://address), a line starting with "- " for a bullet, and
-- a bare https:// address becomes a link. Everything else is escaped as before, so no HTML can be injected.
-- Attachments: up to 5 files, about 4 MB in all, sent as base64 in email_outbox.attachments (outbox-flush already passes them to Resend).
-- No new table, so no new grants are needed.

create or replace function email_format(p text)
returns text
language plpgsql immutable set search_path = public as $$
declare t text; ln text; out text := ''; para text := ''; in_list boolean := false;
begin
  t := replace(replace(replace(replace(trim(coalesce(p, '')), E'\r', ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  t := regexp_replace(t, '\*\*([^*]+?)\*\*', '<strong>\1</strong>', 'g');
  t := regexp_replace(t, '(^|[^*\w])\*([^*\s][^*\n]*?)\*', '\1<em>\2</em>', 'g');
  t := regexp_replace(t, '\[([^\]]+)\]\((https?://[^\s)"'']+)\)', '<a href="\2" style="color:#1a5fb4">\1</a>', 'g');
  t := regexp_replace(t, '(^|[\s(])(https?://[^\s<)"'']*[^\s<)"''.,;:!?])', '\1<a href="\2" style="color:#1a5fb4">\2</a>', 'g');
  foreach ln in array string_to_array(t, E'\n') loop
    if ln ~ '^\s*-\s+\S' then
      if para <> '' then out := out || '<p style="margin:0 0 12px">' || para || '</p>'; para := ''; end if;
      if not in_list then out := out || '<ul style="margin:0 0 12px;padding-left:22px">'; in_list := true; end if;
      out := out || '<li style="margin:0 0 4px">' || regexp_replace(ln, '^\s*-\s+', '') || '</li>';
    elsif trim(ln) = '' then
      if in_list then out := out || '</ul>'; in_list := false; end if;
      if para <> '' then out := out || '<p style="margin:0 0 12px">' || para || '</p>'; para := ''; end if;
    else
      if in_list then out := out || '</ul>'; in_list := false; end if;
      para := para || case when para = '' then '' else '<br>' end || ln;
    end if;
  end loop;
  if in_list then out := out || '</ul>'; end if;
  if para <> '' then out := out || '<p style="margin:0 0 12px">' || para || '</p>'; end if;
  return out;
end $$;
revoke all on function email_format(text) from public, anon;
grant execute on function email_format(text) to authenticated, service_role;

drop function if exists staff_email_unit(text, text, text, text);

-- p_who: 'owner' | 'tenant' | 'both'. p_attachments: [{filename, content (base64)}]. Returns who it was queued for (names).
create or replace function staff_email_unit(p_unit text, p_who text, p_subject text, p_message text, p_attachments jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_html text; r record; v_names text[] := '{}'; v_cu uuid; a jsonb; v_att jsonb := '[]'::jsonb; v_total int := 0; v_fn text; v_list text := '';
begin
  if not staff_mail_ok() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_who not in ('owner', 'tenant', 'both') then raise exception 'Choose who gets the email.'; end if;
  if length(trim(coalesce(p_subject, ''))) < 3 then raise exception 'Add a subject.'; end if;
  if length(trim(coalesce(p_message, ''))) < 3 then raise exception 'Write the message.'; end if;
  if length(p_subject) > 150 or length(p_message) > 8000 then raise exception 'That is too long.'; end if;
  select id into v_cu from condo_units where unit_number = p_unit;
  if v_cu is null then raise exception 'Unknown unit.'; end if;
  if p_unit = '6' and p_who in ('tenant', 'both') then raise exception 'Unit 6 is managed by its owner: email the owner only.'; end if;

  if p_attachments is not null and jsonb_typeof(p_attachments) = 'array' and jsonb_array_length(p_attachments) > 0 then
    if jsonb_array_length(p_attachments) > 5 then raise exception 'Attach at most 5 files.'; end if;
    for a in select * from jsonb_array_elements(p_attachments) loop
      v_fn := trim(regexp_replace(coalesce(a->>'filename', ''), '[^A-Za-z0-9 ._()-]', '', 'g'));
      if v_fn = '' or length(v_fn) > 120 or lower(v_fn) !~ '\.(pdf|png|jpe?g|docx?|xlsx?|csv|txt)$' then
        raise exception 'That file type is not allowed. Use PDF, picture, Word, Excel, CSV or text files.'; end if;
      if coalesce(a->>'content', '') !~ '^[A-Za-z0-9+/]+={0,2}$' then raise exception 'A file could not be read.'; end if;
      v_total := v_total + length(a->>'content');
      v_att := v_att || jsonb_build_array(jsonb_build_object('filename', v_fn, 'content', a->>'content'));
      v_list := v_list || case when v_list = '' then '' else ', ' end || v_fn;
    end loop;
    if v_total > 5600000 then raise exception 'The files are too big (4 MB in all).'; end if;
  end if;

  v_html := '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430">' || email_format(p_message)
    || case when v_list <> '' then '<p style="color:#5b6573;font-size:13px;margin:0 0 12px">Attached: ' || replace(replace(replace(v_list, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</p>' else '' end
    || '<p style="color:#5b6573;font-size:13px">2nd Chance Housing · Royal Orleans Condominium, Unit ' || p_unit
    || '. Reply to this email to reach the office.</p></div>';

  for r in
    select distinct on (lower(e)) e, nm from (
      select o.email e, o.name nm from condo_ownerships s join condo_owners o on o.id = s.owner_id
        where p_who in ('owner', 'both') and s.unit_id = v_cu and s.is_current and coalesce(o.email, '') <> ''
      union all
      select t.email, t.name from rental_units ru join leases l on l.unit_id = ru.id and l.status in ('active', 'future')
        join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id
        where p_who in ('tenant', 'both') and ru.condo_unit_id = v_cu and coalesce(t.email, '') <> ''
    ) x
  loop
    insert into email_outbox (to_email, subject, html, kind, attachments)
    values (r.e, trim(p_subject), v_html, 'staff_message', case when jsonb_array_length(v_att) > 0 then v_att else null end);
    v_names := v_names || r.nm;
  end loop;
  if cardinality(v_names) = 0 then raise exception 'Nobody with an email address is on file for that choice.'; end if;
  return jsonb_build_object('queued', cardinality(v_names), 'names', to_jsonb(v_names));
end $$;
revoke all on function staff_email_unit(text, text, text, text, jsonb) from public, anon;
grant execute on function staff_email_unit(text, text, text, text, jsonb) to authenticated;
