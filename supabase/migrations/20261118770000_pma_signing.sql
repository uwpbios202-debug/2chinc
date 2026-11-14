-- Property Management Agreements signed online (Stephen, 11/11/2026). First one: Unit 15, Mark Postler.
-- The owner and the ROCA1 president (Albert Harris, who also signs for 2nd Chance Housing Inc, the management partner) review the
-- agreement online. Either may suggest new wording for any section (or ask a question); every suggestion and every change is emailed
-- to the owner, the president and the office ("circulated"). The office accepts (as written or edited) or declines each suggestion.
-- When nothing is open, the office clicks "Ready to sign": the text is locked; owner and president each sign by typing their name.
-- Any later change (Reopen) clears both signatures. When both have signed, the edge function `pma-pdf` makes the signed PDF and files
-- it in the owner's Documents (owner-docs bucket + condo_documents, unit-only), where the owner can open and print it at any time.
-- Pages: owner portal https://2ndchinc.org/association-owners/roca1/#pma ; office and president https://2ndchinc.org/staff/pma/ .
-- "View as" sessions can read but can never sign or suggest as someone else (autopay_view_as_session()).
-- The owner's mailing address and phone are NOT stored here: the page and the PDF read them from the owner record.

create table if not exists pma_agreements (
  id uuid primary key default gen_random_uuid(),
  unit_number text not null,
  owner_id uuid not null references condo_owners(id),
  owner_name text not null,
  title text not null,
  president_name text not null default 'Albert Harris',
  president_title text not null default 'President of ROCA1, and for 2nd Chance Housing Inc, management partner',
  president_email text,
  sections jsonb not null,                     -- [{key, title, body}] plain text; blank line = new paragraph
  version int not null default 1,
  status text not null default 'draft' check (status in ('draft', 'review', 'ready', 'signed', 'void')),
  owner_signed_name text, owner_signed_at timestamptz, owner_signed_email text, owner_signed_ip text, owner_signed_hash text,
  president_signed_name text, president_signed_at timestamptz, president_signed_email text, president_signed_ip text, president_signed_hash text,
  signed_at timestamptz,
  pdf_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists pma_suggestions (
  id uuid primary key default gen_random_uuid(),
  agreement_id uuid not null references pma_agreements(id) on delete cascade,
  section_key text not null,
  proposed text,                               -- null/empty = a comment or question only
  comment text,
  by_email text not null,
  by_name text not null,
  by_role text not null check (by_role in ('owner', 'president', 'office')),
  status text not null default 'open' check (status in ('open', 'accepted', 'declined', 'answered', 'withdrawn')),
  response text,
  resolved_by text,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists pma_changes (
  id bigint generated always as identity primary key,
  agreement_id uuid not null references pma_agreements(id) on delete cascade,
  version int not null,
  section_key text,
  old_body text,
  new_body text,
  note text,
  by_email text,
  created_at timestamptz not null default now()
);
alter table pma_agreements enable row level security;
alter table pma_suggestions enable row level security;
alter table pma_changes enable row level security;
-- New tables need explicit grants (10/30/2026): pages reach them only through the functions below.
revoke all on table pma_agreements, pma_suggestions, pma_changes from public, anon, authenticated;
grant all on table pma_agreements, pma_suggestions, pma_changes to service_role;

-- Who is the caller for this agreement: 'president' (staff session, the president's email), 'office' (other staff), 'owner', or null.
create or replace function pma_role(a pma_agreements)
returns text language sql stable security definer set search_path = public as $$
  select case
    when condo_session_ok() and condo_is_staff() and lower(coalesce(a.president_email, '')) = lower(auth.email()) then 'president'
    when condo_session_ok() and condo_is_staff() then 'office'
    when condo_session_ok() and condo_owner_for_email(auth.email()) = a.owner_id then 'owner'
  end;
$$;
revoke all on function pma_role(pma_agreements) from public, anon, authenticated;

create or replace function pma_hash(a pma_agreements)
returns text language sql immutable set search_path = public as $$
  select encode(sha256(convert_to(a.sections::text || '|' || a.version, 'UTF8')), 'hex');
$$;
revoke all on function pma_hash(pma_agreements) from public, anon, authenticated;

-- Email the owner, the president and the office (each once), except the person who acted.
create or replace function pma_circulate(a pma_agreements, p_subject text, p_body text, p_kind text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare v_office text := coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org');
  v_owner_email text := (select email from condo_owners where id = a.owner_id); v_me text := lower(coalesce(auth.email(), ''));
  r record;
begin
  for r in select distinct on (lower(e)) e, link from (values
      (v_owner_email, 'https://2ndchinc.org/association-owners/roca1/#pma'),
      (a.president_email, 'https://2ndchinc.org/staff/pma/'),
      (v_office, 'https://2ndchinc.org/staff/pma/')) x(e, link)
    where coalesce(e, '') <> '' and lower(e) <> v_me loop
    insert into email_outbox (to_email, subject, html, kind) values (r.e, p_subject,
      p_body || '<p>Open the agreement: <a href="' || r.link || '">' || r.link || '</a> (sign in with your email).</p><p>2nd Chance Housing, for ROCA1</p>', p_kind);
  end loop;
end;
$$;
revoke all on function pma_circulate(pma_agreements, text, text, text) from public, anon, authenticated;

create or replace function pma_owner_contact(p_owner uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('mail_to', roca_owner_mail_to(p_owner), 'phone', (select phone_mobile from condo_owners where id = p_owner));
$$;
revoke all on function pma_owner_contact(uuid) from public, anon, authenticated;

-- One agreement as the caller may see it.
create or replace function pma_json(a pma_agreements)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) - 'owner_signed_ip' - 'president_signed_ip' - 'owner_signed_hash' - 'president_signed_hash'
    || jsonb_build_object('role', pma_role(a), 'view_as', autopay_view_as_session(), 'contact', pma_owner_contact(a.owner_id),
       'hash', pma_hash(a),
       'suggestions', coalesce((select jsonb_agg((to_jsonb(s) - 'by_email') || jsonb_build_object('mine', s.by_email = lower(coalesce(auth.email(), ''))) order by s.created_at) from pma_suggestions s where s.agreement_id = a.id), '[]'::jsonb),
       'changes', coalesce((select jsonb_agg(jsonb_build_object('version', c.version, 'section_key', c.section_key, 'note', c.note, 'created_at', c.created_at,
                                                                'old_body', c.old_body, 'new_body', c.new_body) order by c.id) from pma_changes c where c.agreement_id = a.id), '[]'::jsonb));
$$;
revoke all on function pma_json(pma_agreements) from public, anon, authenticated;

-- Owner portal: the owner's agreements (not drafts).
create or replace function pma_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not condo_session_ok() or condo_owner_for_email(auth.email()) is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(pma_json(a) order by a.created_at desc) from pma_agreements a
                    where a.owner_id = condo_owner_for_email(auth.email()) and a.status in ('review', 'ready', 'signed')), '[]'::jsonb);
end;
$$;
revoke all on function pma_mine() from public, anon;
grant execute on function pma_mine() to authenticated;

-- Staff page (office and president): every agreement.
create or replace function pma_staff_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(pma_json(a) order by a.created_at desc) from pma_agreements a where a.status <> 'void'), '[]'::jsonb);
end;
$$;
revoke all on function pma_staff_list() from public, anon;
grant execute on function pma_staff_list() to authenticated;

create or replace function pma_lock(p_id uuid)
returns pma_agreements language plpgsql volatile security definer set search_path = public as $$
declare a pma_agreements;
begin
  select * into a from pma_agreements where id = p_id for update;
  if a.id is null then raise exception 'That agreement isn''t on file.'; end if;
  return a;
end;
$$;
revoke all on function pma_lock(uuid) from public, anon, authenticated;

-- Office: send the draft out for review (emails owner and president).
create or replace function pma_staff_send(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a pma_agreements := pma_lock(p_id);
begin
  if pma_role(a) not in ('office', 'president') then raise exception 'Office staff only.' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not while viewing as someone else.'; end if;
  if a.status <> 'draft' then raise exception 'It has already been sent.'; end if;
  update pma_agreements set status = 'review', updated_at = now() where id = p_id;
  perform pma_circulate(a, a.title || ': ready for your review',
    '<p>The ' || repair_esc(a.title) || ' between ' || repair_esc(a.owner_name) || ' and ROCA1 (with its management partner, 2nd Chance Housing Inc) is ready for review online.</p>'
    || '<p>Read it section by section. If you would like different wording, press "Suggest a change" under that section; every suggestion goes to everyone, and the office answers it. '
    || 'When everything is agreed, the office sets it Ready to sign and you each sign online. The signed copy is then filed in the owner''s Documents, ready to print.</p>', 'pma_review');
end;
$$;
revoke all on function pma_staff_send(uuid) from public, anon;
grant execute on function pma_staff_send(uuid) to authenticated;

-- Owner, president or office: suggest new wording for a section, or ask a question (proposed empty).
create or replace function pma_suggest(p_id uuid, p_section text, p_proposed text, p_comment text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a pma_agreements := pma_lock(p_id); v_role text := pma_role(a); v_sec jsonb; v_name text;
begin
  if v_role is null then raise exception 'You can''t comment on this agreement.' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not while viewing as someone else: suggestions are made by the person themselves.'; end if;
  if a.status <> 'review' then raise exception 'This agreement is not open for changes right now. Ask the office to reopen it.'; end if;
  select s into v_sec from jsonb_array_elements(a.sections) s where s->>'key' = p_section;
  if v_sec is null then raise exception 'Pick a section.'; end if;
  if length(trim(coalesce(p_proposed, ''))) = 0 and length(trim(coalesce(p_comment, ''))) = 0 then raise exception 'Write the new wording or a comment.'; end if;
  if trim(coalesce(p_proposed, '')) = trim(v_sec->>'body') then raise exception 'The wording is the same as now. Change it, or leave it empty and write a comment.'; end if;
  v_name := case v_role when 'owner' then a.owner_name when 'president' then a.president_name
                 else coalesce((select name from condo_staff where lower(email) = lower(auth.email()) limit 1), 'Office') end;
  insert into pma_suggestions (agreement_id, section_key, proposed, comment, by_email, by_name, by_role)
  values (p_id, p_section, nullif(left(trim(coalesce(p_proposed, '')), 8000), ''), nullif(left(trim(coalesce(p_comment, '')), 2000), ''),
          lower(auth.email()), v_name, case when v_role = 'president' then 'president' when v_role = 'owner' then 'owner' else 'office' end);
  perform pma_circulate(a, a.title || ': ' || v_name || ' suggested a change',
    '<p><b>' || repair_esc(v_name) || '</b> ' || case when length(trim(coalesce(p_proposed, ''))) > 0 then 'suggested new wording for' else 'commented on' end
    || ' <b>' || repair_esc(v_sec->>'title') || '</b>.</p>'
    || case when length(trim(coalesce(p_comment, ''))) > 0 then '<p style="border-left:3px solid #ccc;padding-left:10px;white-space:pre-wrap">' || repair_esc(left(trim(p_comment), 2000)) || '</p>' else '' end
    || case when length(trim(coalesce(p_proposed, ''))) > 0 then '<p><b>Suggested wording:</b></p><p style="background:#f4f4f4;padding:8px;white-space:pre-wrap">' || repair_esc(left(trim(p_proposed), 8000)) || '</p>' else '' end
    || '<p>The office will answer it. Nothing changes in the agreement until it is accepted.</p>', 'pma_suggestion');
end;
$$;
revoke all on function pma_suggest(uuid, text, text, text) from public, anon;
grant execute on function pma_suggest(uuid, text, text, text) to authenticated;

-- The person who made a suggestion may withdraw it while it is open.
create or replace function pma_withdraw(p_suggestion uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare s pma_suggestions;
begin
  select * into s from pma_suggestions where id = p_suggestion for update;
  if s.id is null or s.status <> 'open' or s.by_email <> lower(auth.email()) or autopay_view_as_session() then raise exception 'You can''t withdraw that.'; end if;
  update pma_suggestions set status = 'withdrawn', resolved_by = lower(auth.email()), resolved_at = now() where id = p_suggestion;
end;
$$;
revoke all on function pma_withdraw(uuid) from public, anon;
grant execute on function pma_withdraw(uuid) to authenticated;

-- Change a section's text (internal): logs it, bumps the version, clears signatures.
create or replace function pma_apply_change(p_id uuid, p_section text, p_body text, p_note text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a pma_agreements := pma_lock(p_id); v_old text;
begin
  select s->>'body' into v_old from jsonb_array_elements(a.sections) s where s->>'key' = p_section;
  if v_old is null then raise exception 'Pick a section.'; end if;
  if trim(coalesce(p_body, '')) = '' then raise exception 'The section can''t be empty.'; end if;
  update pma_agreements set
    sections = (select jsonb_agg(case when s->>'key' = p_section then jsonb_set(s, '{body}', to_jsonb(left(trim(p_body), 8000))) else s end order by o)
                  from jsonb_array_elements(a.sections) with ordinality x(s, o)),
    version = version + 1, updated_at = now(),
    owner_signed_name = null, owner_signed_at = null, owner_signed_email = null, owner_signed_ip = null, owner_signed_hash = null,
    president_signed_name = null, president_signed_at = null, president_signed_email = null, president_signed_ip = null, president_signed_hash = null
  where id = p_id;
  insert into pma_changes (agreement_id, version, section_key, old_body, new_body, note, by_email) values (p_id, a.version + 1, p_section, v_old, left(trim(p_body), 8000), p_note, lower(auth.email()));
end;
$$;
revoke all on function pma_apply_change(uuid, text, text, text) from public, anon, authenticated;

-- Office: accept a suggestion (as written, or with the office's edited wording) or decline it, with an optional reply.
create or replace function pma_staff_resolve(p_suggestion uuid, p_action text, p_body text, p_reply text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare s pma_suggestions; a pma_agreements; v_title text; v_body text;
begin
  select * into s from pma_suggestions where id = p_suggestion for update;
  if s.id is null or s.status <> 'open' then raise exception 'That suggestion is not open.'; end if;
  a := pma_lock(s.agreement_id);
  if pma_role(a) not in ('office', 'president') then raise exception 'Office staff only.' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not while viewing as someone else.'; end if;
  if a.status <> 'review' then raise exception 'Reopen the agreement first.'; end if;
  select x->>'title' into v_title from jsonb_array_elements(a.sections) x where x->>'key' = s.section_key;
  if p_action = 'accept' then
    v_body := coalesce(nullif(trim(coalesce(p_body, '')), ''), s.proposed);
    if v_body is null then raise exception 'A comment has no wording to accept. Answer it with Reply.'; end if;
    perform pma_apply_change(a.id, s.section_key, v_body, 'Suggestion by ' || s.by_name || ' accepted' || case when v_body <> coalesce(s.proposed, '') then ' with changes' else '' end);
    update pma_suggestions set status = 'accepted', response = nullif(left(trim(coalesce(p_reply, '')), 2000), ''), resolved_by = lower(auth.email()), resolved_at = now() where id = s.id;
  elsif p_action in ('decline', 'reply') then
    update pma_suggestions set status = case when p_action = 'reply' or s.proposed is null then 'answered' else 'declined' end, response = nullif(left(trim(coalesce(p_reply, '')), 2000), ''), resolved_by = lower(auth.email()), resolved_at = now() where id = s.id;
  else raise exception 'Unknown action.'; end if;
  perform pma_circulate(a, a.title || ': ' || case when p_action = 'accept' then 'change accepted' when s.proposed is null then 'question answered' else 'suggestion declined' end,
    '<p>' || repair_esc(s.by_name) || '''s ' || case when s.proposed is null then 'comment' else 'suggestion' end || ' on <b>' || repair_esc(v_title) || '</b> was '
    || case when p_action = 'accept' then 'accepted' when s.proposed is null then 'answered' else 'declined' end || '.</p>'
    || case when length(trim(coalesce(p_reply, ''))) > 0 then '<p style="border-left:3px solid #ccc;padding-left:10px;white-space:pre-wrap">' || repair_esc(left(trim(p_reply), 2000)) || '</p>' else '' end
    || case when p_action = 'accept' then '<p><b>The section now reads:</b></p><p style="background:#f4f4f4;padding:8px;white-space:pre-wrap">' || repair_esc(v_body) || '</p>' else '' end, 'pma_resolved');
end;
$$;
revoke all on function pma_staff_resolve(uuid, text, text, text) from public, anon;
grant execute on function pma_staff_resolve(uuid, text, text, text) to authenticated;

-- Office: edit a section directly (circulated to everyone).
create or replace function pma_staff_edit(p_id uuid, p_section text, p_body text, p_note text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a pma_agreements := pma_lock(p_id); v_title text;
begin
  if pma_role(a) not in ('office', 'president') then raise exception 'Office staff only.' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not while viewing as someone else.'; end if;
  if a.status not in ('draft', 'review') then raise exception 'Reopen the agreement first.'; end if;
  select x->>'title' into v_title from jsonb_array_elements(a.sections) x where x->>'key' = p_section;
  perform pma_apply_change(p_id, p_section, p_body, coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Edited by the office'));
  if a.status = 'review' then
    perform pma_circulate(a, a.title || ': the office changed ' || coalesce(v_title, 'a section'),
      '<p>The office changed <b>' || repair_esc(coalesce(v_title, '')) || '</b>.</p>'
      || case when length(trim(coalesce(p_note, ''))) > 0 then '<p style="border-left:3px solid #ccc;padding-left:10px">' || repair_esc(left(trim(p_note), 2000)) || '</p>' else '' end
      || '<p><b>It now reads:</b></p><p style="background:#f4f4f4;padding:8px;white-space:pre-wrap">' || repair_esc(left(trim(p_body), 8000)) || '</p>', 'pma_changed');
  end if;
end;
$$;
revoke all on function pma_staff_edit(uuid, text, text, text) from public, anon;
grant execute on function pma_staff_edit(uuid, text, text, text) to authenticated;

-- Office: lock the text for signing (nothing open), or reopen it for changes (clears signatures).
create or replace function pma_staff_status(p_id uuid, p_to text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a pma_agreements := pma_lock(p_id);
begin
  if pma_role(a) not in ('office', 'president') then raise exception 'Office staff only.' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not while viewing as someone else.'; end if;
  if p_to = 'ready' then
    if a.status <> 'review' then raise exception 'Only an agreement under review can be set Ready to sign.'; end if;
    if exists (select 1 from pma_suggestions where agreement_id = p_id and status = 'open') then raise exception 'Answer every open suggestion first.'; end if;
    update pma_agreements set status = 'ready', updated_at = now() where id = p_id;
    perform pma_circulate(a, a.title || ': ready to sign',
      '<p>All changes are settled and the text is final (version ' || a.version || '). Please read it once more and sign online: type your full name and press Sign.</p>'
      || '<p>When both ' || repair_esc(a.owner_name) || ' and ' || repair_esc(a.president_name) || ' have signed, the signed PDF is filed in the owner''s Documents, ready to print.</p>', 'pma_ready');
  elsif p_to = 'review' then
    if a.status <> 'ready' then raise exception 'Only an agreement waiting for signatures can be reopened.'; end if;
    update pma_agreements set status = 'review', updated_at = now(),
      owner_signed_name = null, owner_signed_at = null, owner_signed_email = null, owner_signed_ip = null, owner_signed_hash = null,
      president_signed_name = null, president_signed_at = null, president_signed_email = null, president_signed_ip = null, president_signed_hash = null
    where id = p_id;
    perform pma_circulate(a, a.title || ': reopened for changes',
      '<p>The office reopened the agreement for changes. Any signature already given is cleared; everyone signs again once the text is final.</p>', 'pma_reopened');
  else raise exception 'Unknown status.'; end if;
end;
$$;
revoke all on function pma_staff_status(uuid, text) from public, anon;
grant execute on function pma_staff_status(uuid, text) to authenticated;

-- Sign: the owner (as owner) or the president (for ROCA1 and 2nd Chance). Typed full name + consent to sign electronically.
create or replace function pma_sign(p_id uuid, p_name text, p_consent boolean)
returns text language plpgsql volatile security definer set search_path = public as $$
declare a pma_agreements := pma_lock(p_id); v_role text := pma_role(a); v_ip text; v_hash text := pma_hash(a); v_need text;
begin
  if autopay_view_as_session() then raise exception 'Not while viewing as someone else: only the person can sign.'; end if;
  if a.status <> 'ready' then raise exception 'This agreement is not ready to sign yet.'; end if;
  if not coalesce(p_consent, false) then raise exception 'Tick the box to agree to sign electronically.'; end if;
  v_ip := left(coalesce(split_part(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ',', 1), ''), 60);
  if v_role = 'owner' then
    v_need := a.owner_name;
    if a.owner_signed_at is not null then raise exception 'You have already signed.'; end if;
  elsif v_role = 'president' then
    v_need := a.president_name;
    if a.president_signed_at is not null then raise exception 'You have already signed.'; end if;
  else raise exception 'Only % (the owner) and % (President) can sign this agreement.', a.owner_name, a.president_name using errcode = '42501'; end if;
  if lower(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g')) <> lower(v_need) then raise exception 'Type your full name exactly as shown: %', v_need; end if;
  if v_role = 'owner' then
    update pma_agreements set owner_signed_name = v_need, owner_signed_at = now(), owner_signed_email = lower(auth.email()), owner_signed_ip = v_ip, owner_signed_hash = v_hash, updated_at = now() where id = p_id;
  else
    update pma_agreements set president_signed_name = v_need, president_signed_at = now(), president_signed_email = lower(auth.email()), president_signed_ip = v_ip, president_signed_hash = v_hash, updated_at = now() where id = p_id;
  end if;
  select * into a from pma_agreements where id = p_id;
  if a.owner_signed_at is not null and a.president_signed_at is not null then
    update pma_agreements set status = 'signed', signed_at = now() where id = p_id;
    perform pma_circulate(a, a.title || ': signed by both',
      '<p>' || repair_esc(a.owner_name) || ' and ' || repair_esc(a.president_name) || ' have both signed. The signed PDF is being filed in the owner''s Documents, where it can be opened and printed at any time.</p>', 'pma_signed');
    return 'signed';
  end if;
  perform pma_circulate(a, a.title || ': ' || v_need || ' signed',
    '<p>' || repair_esc(v_need) || ' signed the agreement. Waiting for ' || repair_esc(case when v_role = 'owner' then a.president_name else a.owner_name end) || ' to sign.</p>', 'pma_signed_one');
  return 'waiting';
end;
$$;
revoke all on function pma_sign(uuid, text, boolean) from public, anon;
grant execute on function pma_sign(uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Unit 15 (Mark Postler): the agreement drafted 11/9-11/11/2026, as a draft (the office sends it for review).
do $$
declare v_owner uuid; v_pres text;
begin
  if exists (select 1 from pma_agreements where unit_number = '15' and status <> 'void') then return; end if;
  select o.id into v_owner from condo_ownerships co join condo_units cu on cu.id = co.unit_id join condo_owners o on o.id = co.owner_id
   where cu.unit_number = '15' and co.end_date is null limit 1;
  if v_owner is null then return; end if;
  select email into v_pres from condo_staff where name = 'Albert Harris' limit 1;
  insert into pma_agreements (unit_number, owner_id, owner_name, title, president_email, sections) values ('15', v_owner, 'Mark Postler',
    'Property Management Agreement, Unit 15', v_pres, jsonb_build_array(
    jsonb_build_object('key', 'bylaws', 'title', 'ROCA1 ByLaws this Agreement follows', 'body', $t$Page 6: "manage all non owner/Tenant occupied (leased) units;"

Page 24: No unit may be leased "unless the Association is given no less than fifteen (15) days prior written notice of the terms thereof, together with the name and address of the proposed ... lessee," and "the Association shall at all times have the first right and option to purchase or lease such unit upon the same terms." Signing this Agreement is the Owner's written notice to ROCA1 that Unit 15 will be leased on the terms below.$t$),
    jsonb_build_object('key', 's1', 'title', '1. The parties and the property', 'body', $t$This Property Management Agreement ("Agreement") is made on the date both parties have signed it, between Mark Postler ("Owner") and ROCA1 and its management partner, 2nd Chance Housing Inc ("Manager").

Owner gives Manager the exclusive right to rent, lease, operate and manage Unit 15, 6622 N Bourbon St, Milwaukee, Milwaukee County, Wisconsin 53224 ("Property"), a 2-bedroom, 1-bath unit of about 960 sq ft.$t$),
    jsonb_build_object('key', 's2', 'title', '2. The figures', 'body', $t$Monthly rent: $950.00, due on the 1st of each month.
Security deposit: $1,900.00 (two months' rent, the ROCA1 rule).
Lease term: month to month, or annual (12 months) when a housing agency requires it.
Tenant late fee: $75.00, charged on the 2nd if rent is not paid in full. Late fees the tenant pays belong to the Owner, like the rent.
Payment processing and administrative fee: 3.5% of every tenant payment, however the tenant pays, to cover Stripe's charges and administrative costs. No other management fee.
Leasing / renewal fee: 0.0%.
Collection fee: 3.0% of bad debts collected by Manager.
Insurance settlement fee: 3.0% of any gross insurance settlement amount.
Repairs needing the Owner's OK first: over $300.00 for any one item (emergencies excepted, see section 6).
Association dues for Unit 15: $215.00 a month today (set by the ROCA1 budget).$t$),
    jsonb_build_object('key', 's3', 'title', '3. Collecting rent', 'body', $t$1. Manager collects all rent, late fees and security deposits for the Property. Tenants pay into ROCA1's account (the "Property Account"). The Owner does not collect rent from the tenant.
2. The Owner does not give Manager, ROCA1 or anyone else access to the Owner's own bank account, and Manager will never ask for it.
3. The security deposit stays in the Property Account while the tenant lives there. It is not paid to the Owner. At move-out Manager returns it, less lawful deductions with an itemized statement, within 21 days as Wisconsin law requires (Wis. Admin. Code ATCP 134.06).$t$),
    jsonb_build_object('key', 's4', 'title', '4. How the Owner is paid: the Owner withdraws the Owner''s portion at the bank', 'body', $t$Each time a tenant's rent payment clears:
1. First, what Unit 15 owes ROCA1 is paid from it, in the order of the ROCA1 Rules & Regulations (2024, section 11): fines and fees, special assessments, the current month's association dues, then any older balance. Each amount is posted to the Owner's association account as paid.
2. Next, the 3.5% payment processing and administrative fee (section 2) is taken out.
3. The rest is the Owner's portion. Within 5 business days after the payment clears, Manager gives the Owner a printed statement (by hand or by U.S. Mail): the rent received, what was paid to ROCA1 and for what, any fee taken, and the amount of the Owner's portion.
4. The Owner then withdraws that amount from the Property Account at the bank, at the Owner's convenience, and no more than the statement shows. The Owner's portion stays in the Property Account until the Owner withdraws it.
5. When Unit 15 owes ROCA1 more than the rent covers, the Owner deposits the Owner's part into the Property Account at the bank, using the Owner's ROCA1 deposit card, and gives Manager the deposit receipt or tells Manager the amount and date.

Example: the tenant pays $950.00 and Unit 15 owes only this month's $215.00 dues. ROCA1 keeps $215.00 (the Owner's dues are paid), the 3.5% fee is $33.25, and the Owner's statement shows a portion of $701.75, which the Owner withdraws at the bank.

6. If a tenant's payment is later reversed (bounced, refunded or disputed) after the Owner withdrew the portion, the Owner deposits that part back, or Manager takes it out of the Owner's next portion, with a statement showing why.
7. Approved repair costs (section 6) are either taken out of the Owner's next portion, with a copy of the invoice with the statement, or billed to the Owner by mail, as the Owner prefers.$t$),
    jsonb_build_object('key', 's5', 'title', '5. Leases, notices and legal action', 'body', $t$Manager prepares leases on Manager's lease form (Manager or an attorney is named as drafter), and negotiates, signs as agent of the Owner, renews and ends leases. Manager may sign and serve notices as the Owner's agent and, as the law allows, start and pursue legal action to end tenancies, evict, recover possession and recover rent owed, and settle or reinstate tenancies. Notices and court filings ask for unpaid rent only; late fees are never part of a notice, a demand amount or a court filing. Manager hires an attorney only with the Owner's approval.$t$),
    jsonb_build_object('key', 's6', 'title', '6. Maintenance and repairs', 'body', $t$Manager arranges the repairs needed to keep the Property in good repair and hires contractors as needed. Manager gets the Owner's approval, by phone or in writing, before spending more than $300.00 on any one item, except emergency repairs needed to protect the Property from damage or to keep services the lease promises (for example heat in winter). Manager tells the Owner about any emergency repair promptly; if the Owner cannot be reached in time, Manager may go ahead with it.$t$),
    jsonb_build_object('key', 's7', 'title', '7. Advertising, utilities and service contracts', 'body', $t$Manager may advertise the Property by any reasonable means and show it at reasonable times with reasonable notice. Manager gets the Owner's approval before spending money on advertising. Manager may enter into utility and service contracts as the Owner's agent where needed; the Owner's approval is needed to go beyond the terms of the lease. Utilities are as set in the lease (today the tenant pays We Energies and internet).$t$),
    jsonb_build_object('key', 's8', 'title', '8. Employees', 'body', $t$Any on-site manager, maintenance staff or other employee is Manager's employee for all purposes. Manager is responsible for injuries and damages caused by its employees' acts or omissions, except those caused by the Owner's negligence or intentional wrongdoing, and for Worker's Compensation coverage where required.$t$),
    jsonb_build_object('key', 's9', 'title', '9. Records and statements', 'body', $t$Manager keeps complete books and records of all income and expense for the Property. They belong to the Owner and are open to the Owner's inspection during business hours at 6626 N Bourbon St. Besides the statement for each payment, Manager mails the Owner a year-end statement of all income and expense within 45 days after the end of the year, and any tax form the law requires.$t$),
    jsonb_build_object('key', 's10', 'title', '10. Owner cooperation', 'body', $t$The Owner makes available to Manager the records and information needed to manage the Property, cooperates with Manager under this Agreement, and gives Manager the names of any prospective tenants right away.$t$),
    jsonb_build_object('key', 's11', 'title', '11. Insurance and indemnification', 'body', $t$The Owner carries insurance on the unit in the amount the Owner judges right for replacement, with at least $200,000 in liability coverage, naming Manager and its staff as additional insured on the liability coverage. The Owner indemnifies and holds Manager harmless for losses, damages, costs and expenses, including attorney's fees, arising out of this Agreement, unless caused by Manager's gross negligence or intentional wrongdoing.$t$),
    jsonb_build_object('key', 's12', 'title', '12. Term and default', 'body', $t$This Agreement starts when both parties have signed it and continues while the Property is leased, under the ROCA1 ByLaws. If either party materially defaults and does not cure the default within ten (10) days after written notice, the other party may end this Agreement. In any legal proceeding over a default, the prevailing party may recover its costs and reasonable attorney's fees.$t$),
    jsonb_build_object('key', 's13', 'title', '13. Notices and communication', 'body', $t$Documents and written notices under this Agreement are given by hand, by U.S. Mail to the Owner's mailing address on file, or through the owner portal at 2ndchinc.org. Manager may also call the Owner. The Owner may ask for a paper copy of anything at any time.$t$),
    jsonb_build_object('key', 's14', 'title', '14. General', 'body', $t$Wisconsin law governs this Agreement. It is the entire agreement of the parties; changes must be in writing and signed by both. A waiver of one breach is not a waiver of any other. If any part is unenforceable, the rest stays in effect. It may be signed in counterparts, which together are one agreement. It binds and benefits the parties and their personal representatives, successors and assigns.

Electronic signatures: the parties agree to sign this Agreement electronically. Each typed signature below, with its date, time and sign-in email, has the same effect as a handwritten signature.$t$)));
end $$;
