-- Pay-or-vacate notice follows the Unit 2 notice of 12/12/2025 section by section (Stephen, 11/11/2026: "too much information;
-- follow the Desiree notice, it is what the courts recognize"). Same order and wording: title, statute, landlord, State/County and To:,
-- the "terminates your tenancy ... within N days from service hereof unless you pay the total unpaid rent of $X" sentence, description
-- of premises, how the amount was calculated, dated, landlord/agent signature, non-waiver, credit reporting, double rent, absconding
-- (943.215), arrangement through the tenant portal, sincerely. Dropped: "your rent is past due", "how to pay" (Zelle, mailing a check),
-- "managing agent", the repeated premises line. Kept from our rules: the exact statute for the lease (not the old shotgun cite), rent only
-- (no late-fee lines or "zero balance" note), no fixed pay-by date, the federal 30-day paragraph only when the tenancy is covered.
do $$
declare n int;
begin
  update letter_templates set html = $tpl$<p style="text-align: center"><strong>[[Notice_Title]]</strong></p>
<p style="text-align: center">[[Notice_Statute]]</p>
<p>[[Landlord_Line]]<br>[[Landlord_Address]]</p>
<table><tr><td>State of Wisconsin }<br>Milwaukee County }</td><td>To: [[Lease_All_Tenants]]<br>[[Unit_Address]]</td></tr></table>
<p>This notice terminates your tenancy pursuant to [[Notice_Statute]], and requires you to vacate the premises described in this notice within [[Notice_Days]] days from service hereof unless you pay the total unpaid rent of <b>[[Amount_Required]]</b>.</p>
[[Federal_Paragraph]]
<p>Description of premises: [[Unit_Address]].</p>
<p>The amount was calculated as follows:</p>
<table><tr><td>[[Rent_Month]] unpaid rent</td><td>[[Current_Unpaid]]</td></tr>
<tr><td>Unpaid rent prior to [[Rent_Month]]</td><td>[[Prior_Unpaid]]</td></tr>
<tr class="big"><td><b>Total unpaid rent</b></td><td><b>[[Amount_Required]]</b></td></tr></table>
<p>Dated at Milwaukee, Wisconsin, [[Notice_Date]].</p>
<p>Landlord / Landlord's Agent:</p>
<p>[[Sender_Signature]]</p>
<p>[[Agent_Name]], [[Agent_Title]]<br>[[Landlord_Signoff]]</p>
<p><b>Non Waiver:</b> If you make a payment of less than the [[Amount_Required]] required by this notice, you will still be in default and SUBJECT TO EVICTION unless the Owner agrees in writing to cancel this notice.</p>
<p><b>Credit reporting:</b> We may report delinquent accounts to credit bureaus. This may affect your ability to obtain credit or your ability to rent in the future.</p>
<p><b>Double Rent:</b> Wisconsin law § 704.27 provides that an owner can recover a minimum of twice the daily rent amount for the time the tenant remains in possession of the unit after expiration of this notice.</p>
<p><b>Skipping out is against the law in Wisconsin.</b> Statute 943.215: "Absconding without paying rent. (1) Whoever having obtained the tenancy, as defined in s. 704.01 (4) of residential property he or she is entitled to occupy, intentionally absconds without paying all current and past due rent is guilty of a Class A misdemeanor."</p>
<p>Arrangement for payment can be made through your Tenant Portal.</p>
<p>Sincerely,<br>Property Management<br>[[Org_Phone]]</p>$tpl$
  where template_key = '2c-pay-or-vacate';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'pay-or-vacate template not found'; end if;
end;
$$;
