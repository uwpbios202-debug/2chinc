-- Pay-or-vacate tenant email: no Zelle in emails; steer to paying from the bank in the resident portal (Stripe). CLAUDE.md, Stephen 10/17/2026.
do $$
declare n int;
begin
  update letter_templates set email_html = replace(email_html,
      'You can pay by Zelle to [[Zelle_Name]] or in your <a href="[[Portal_URL]]">resident portal</a>, then tap "I''ve paid".',
      'Pay from your bank in your <a href="[[Portal_URL]]">resident portal</a> (Payments, Pay now).')
  where template_key = '2c-pay-or-vacate';
  select count(*) into n from letter_templates where template_key = '2c-pay-or-vacate' and email_html not ilike '%zelle%';
  if n <> 1 then raise exception 'pay-or-vacate email still mentions Zelle'; end if;
end;
$$;
