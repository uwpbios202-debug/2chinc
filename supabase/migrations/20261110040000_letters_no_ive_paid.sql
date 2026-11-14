-- The portal has no "I've paid" button (payments are matched from the bank), so the Online Payments letter must not tell tenants to tap one.
update letter_templates
   set html = regexp_replace(html, '\s*Then tap\s*"?(&quot;)?I''ve paid(&quot;)?"?\s*in the portal so we can match your payment\.', '', 'g')
 where html ilike '%ve paid%';
