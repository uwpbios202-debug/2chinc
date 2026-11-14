-- Housing Navigators sign in with the emailed sign-in button or 6-digit code only, no authenticator app (Stephen, 11/11/2026).
update portal_settings
   set value = array_to_string(array_remove(string_to_array(replace(value, ' ', ''), ','), 'navigator'), ',')
 where key = 'mfa_required_roles';

create or replace function nav_staff_invite(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n navigators;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into n from navigators where id = p_id;
  if not found then raise exception 'Navigator not found.'; end if;
  if n.status not in ('preview', 'pilot', 'active') then raise exception 'Set the Navigator to Preview, Pilot or Active first.'; end if;
  perform nav_email(n.email, 'Your Housing Navigator sign-in at 2nd Chance Housing',
    '<p>Hello ' || repair_esc(split_part(n.name, ' ', 1)) || ',</p>'
    || '<p>Welcome to the 2nd Chance Housing Community Housing Partnership. Your Navigator portal is ready.</p>'
    || '<ol><li>Open <a href="https://2ndchinc.org/navigator/">https://2ndchinc.org/navigator/</a> on your phone or computer.</li>'
    || '<li>Type this email address (' || repair_esc(n.email) || ') and tap <b>Email me a code</b>.</li>'
    || '<li>Open the email from 2nd Chance Housing and tap <b>Click here to sign in</b>, or type the 6-digit code it shows. No password to remember.</li></ol>'
    || case when n.status = 'preview'
         then '<p>For now your portal is a <b>preview</b>: look around and see how it works. Adding people, landlords and units opens once the partner and confidentiality agreements are signed.</p>'
         else '<p>In the portal you add the people you are helping (with their signed consent), the landlords and units you work with, record move-ins and check-ins, and see your pay.</p>' end
    || '<p>Questions: reply to this email or write to info@2ndchinc.org.</p><p>2nd Chance Housing Inc</p>', 'nav_invite');
  update navigators set invited_at = now() where id = p_id;
  perform nav_log('navigator_invited', n.email, null, p_id);
end;
$$;
