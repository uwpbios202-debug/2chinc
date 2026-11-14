-- Unit 6 parking-and-keys access: when the owner clicks "Give access", the system emails the tenant the sign-in steps (no copy and paste
-- for the owner), and "Send the steps again" resends them (Stephen, 11/4/2026). Email only, from the office address, naming the owner.

drop function if exists owner_occupant_add(text, text, text);

create or replace function occupant_invite_email(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare o unit_occupants; v_owner text;
begin
  select * into o from unit_occupants where id = p_id and active;
  if o.id is null then raise exception 'Not found.'; end if;
  select split_part(trim(co.name), ' ', 1) into v_owner from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current
    join condo_owners co on co.id = s.owner_id where cu.unit_number = o.unit_number limit 1;
  insert into email_outbox (to_email, subject, html, kind) values (lower(o.email),
    'Your parking and keys login for Unit ' || o.unit_number,
    '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>Hi ' || repair_esc(split_part(coalesce(o.name, ''), ' ', 1)) || ',</p>'
    || '<p>' || repair_esc(coalesce(nullif(v_owner, ''), 'The owner of your unit')) || ', the owner of Unit ' || repair_esc(o.unit_number)
    || ', gave you access to <b>parking and keys</b> on the 2nd Chance Housing website.</p>'
    || '<ol><li>Go to <a href="https://2ndchinc.org/unit-access/">https://2ndchinc.org/unit-access/</a></li>'
    || '<li>Sign in with this email address: <b>' || repair_esc(lower(o.email)) || '</b></li>'
    || '<li>We email you a 6-digit code. Type it in. There is no password.</li></ol>'
    || '<p>You will see the <b>parking lot</b> (if someone parks in your stall, tap it to alert everyone, and request a tow if it is not moved) and your '
    || '<b>door codes</b> (the glass entry door and the basement front door).</p>'
    || '<p>On your phone you can also turn on free parking alerts on the Parking page.</p>'
    || '<p>Questions? Call or text (262) 236-5443.</p><p style="color:#5b6573;font-size:13px">2nd Chance Housing</p></div>', 'occupant_invite');
end;
$$;
revoke all on function occupant_invite_email(uuid) from public, anon, authenticated;

create or replace function owner_occupant_add(p_unit text, p_name text, p_email text, p_send boolean default true)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); v_email text := lower(trim(coalesce(p_email, ''))); v_id uuid;
begin
  if v_owner is null or not condo_session_ok() then raise exception 'Owner sign-in required' using errcode = '42501'; end if;
  if not (p_unit = any (owner_direct_unit_list()) and exists (select 1 from condo_ownerships s join condo_units cu on cu.id = s.unit_id
            where s.is_current and s.owner_id = v_owner and cu.unit_number = p_unit)) then
    raise exception 'You can add a person only for your own owner-managed unit.' using errcode = '42501';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'Enter the person''s name.'; end if;
  if (select count(*) from unit_occupants where active and unit_number = p_unit) >= 4 then raise exception 'Up to 4 people per unit.'; end if;
  if exists (select 1 from unit_occupants where active and lower(email) = v_email) then raise exception 'That email already has parking and keys access.'; end if;
  insert into unit_occupants (unit_number, name, email, added_by) values (p_unit, trim(p_name), v_email, lower(auth.email())) returning id into v_id;
  if coalesce(p_send, true) then perform occupant_invite_email(v_id); end if;
end;
$$;
revoke all on function owner_occupant_add(text, text, text, boolean) from public, anon;
grant execute on function owner_occupant_add(text, text, text, boolean) to authenticated;

create or replace function owner_occupant_resend(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if v_owner is null or not condo_session_ok() then raise exception 'Owner sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from unit_occupants o where o.id = p_id and o.active and o.unit_number in
                   (select cu.unit_number from condo_ownerships s join condo_units cu on cu.id = s.unit_id where s.is_current and s.owner_id = v_owner)) then
    raise exception 'Not found.';
  end if;
  if (select count(*) from email_outbox e join unit_occupants o on lower(o.email) = e.to_email
       where o.id = p_id and e.kind = 'occupant_invite' and e.created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Sent 3 times in the last hour. Please wait a bit, and ask them to check their spam folder.';
  end if;
  perform occupant_invite_email(p_id);
end;
$$;
revoke all on function owner_occupant_resend(uuid) from public, anon;
grant execute on function owner_occupant_resend(uuid) to authenticated;
