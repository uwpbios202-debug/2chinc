-- One office number everywhere: (262) 236-5443 (Stephen, 10/11/2026).
update portal_settings set value = '(262) 236-5443' where key in ('office_phone', 'emergency_phone', 'org_phone');

-- The Online Payments letter, rewritten to match how payments work now: pay from the bank in the portal, autopay, Zelle matched from the bank
-- (no "I've paid" button, nothing to report), check or money order. No cards (tenant_cards is off).
update letter_templates set html = $html$<p>Dear [[Tenant_First_Name]],</p>
<p>Your rent of <b>[[Tenant_Rent_Portion]]</b> is due on the 1st of each month. The easiest way to pay on time is in your resident portal at <a href="[[Portal_URL]]">[[Portal_URL]]</a>, on the Payments page:</p>
<ul>
<li><b>Pay now from your bank account.</b> It is free to you, and it is added to your account the moment you pay.</li>
<li><b>Turn on autopay</b> and your rent is paid from your bank account automatically on the 1st. Never forget rent again.</li>
<li><b>Zelle:</b> the Payments page shows exactly where to send it. Put your account number in the memo and your payment is matched to your account automatically, usually within 1 to 2 business days. You do not need to tell us you paid.</li>
<li><b>Check or money order:</b> the Payments page shows where to mail it. Write your account number on it.</li>
</ul>
<p>Your account number, your balance and every payment are always shown in the portal.</p>
<p>[[Late_Fee_Policy]]</p>
<p>If you have any questions, or would like help, call or text us at [[Org_Phone]].</p>
<p>Sincerely,</p><p>[[Sender_Signature]]</p>$html$
 where template_key = '2c-online-payments';
