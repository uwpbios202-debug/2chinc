-- Pay-or-vacate notice (Stephen, 11/2/2026): "How the amount was calculated" becomes a table whose total row is bold and one size larger
-- (judges in Milwaukee like the amount due to stand out), and the mailing date in "Served by ... on ..." is left blank for the agent to write in.
update letter_templates set html =
  replace(
    regexp_replace(html, '<ul><li>Rent unpaid for[\s\S]*?</ul>',
      '<table><tr><td>Rent unpaid for [[Rent_Month]]</td><td>[[Current_Unpaid]]</td></tr>' || chr(10)
      || '<tr><td>Unpaid rent from earlier months</td><td>[[Prior_Unpaid]]</td></tr>' || chr(10)
      || '<tr class="big"><td><b>Total unpaid rent required</b></td><td><b>[[Amount_Required]]</b></td></tr></table>'),
    'Served by [[Service_Method]] on [[Mail_Date]].', 'Served by [[Service_Method]] on ______________________.')
where template_key = '2c-pay-or-vacate';
