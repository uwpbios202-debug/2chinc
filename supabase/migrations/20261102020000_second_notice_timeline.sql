-- "Second Notice" (sent the day after the pay-or-vacate notice is mailed) is the projected
-- sequence of events if rent stays unpaid: notice ends -> case filed -> court date ->
-- writ decision -> sheriff. It replaces the earlier "Past Due Rent - Second Notice"
-- wording (letter_templates.legacy_id = '101'); the rent-cycle function fills the dates
-- for each tenant. Edit the wording on the Letters page; the [[Fields]] are filled per tenant.

insert into portal_settings (key, value) values
  ('writ_days_after_court', '0'),        -- days from the court date to the writ decision (0 = decided at the hearing)
  ('sheriff_days_after_writ', '10')      -- the sheriff typically arrives about this many days after the writ is filed
on conflict (key) do nothing;

update letter_templates set
  name = 'Past Due Rent - Second Notice (what happens next)',
  subject = 'What happens next if rent stays unpaid',
  description = 'Emailed the day after the pay-or-vacate notice: the projected dates from the notice ending to a court date, a writ decision and the sheriff.',
  html = '<p>[[Current_Date]]</p>
<p>Dear [[Tenant_Greeting]],</p>
<p>Rent of <b>[[Rent_Balance]]</b> for [[Unit_Address_Line_1]], Unit [[Unit_Number]], is still unpaid. A [[Notice_Days]]-day notice to pay rent or vacate was mailed to you on [[Notice_Served]]. If the rent stays unpaid, this is the sequence of events, with the dates we expect:</p>
<ol>
<li><b>The notice ends:</b> [[Notice_End]].</li>
<li><b>Eviction case filed in court:</b> [[Filing_Date]].</li>
<li><b>Expected court date:</b> [[Court_Date]]. The court sets the actual date; it is usually about two weeks after filing.</li>
<li><b>Writ decision:</b> [[Writ_Date]]. If the court rules for the landlord, a writ of restitution is requested.</li>
<li><b>Sheriff:</b> about [[Sheriff_Date]], typically 10 days after the writ is filed. [[Writ_Text]]</li>
</ol>
<p><b>You can stop this by paying the full unpaid rent before the notice ends.</b> Pay in your resident portal ([[Portal_URL]]) and tap "I''ve paid", or call [[Org_Phone]] to talk about it.</p>
<p>Sincerely,</p><p>[[Sender_Signature]]</p>',
  fields = array['Current_Date', 'Tenant_Greeting', 'Rent_Balance', 'Unit_Address_Line_1', 'Unit_Number', 'Notice_Days', 'Notice_Served', 'Notice_End',
                 'Filing_Date', 'Court_Date', 'Writ_Date', 'Sheriff_Date', 'Writ_Text', 'Portal_URL', 'Org_Phone']
where legacy_id = '101';
