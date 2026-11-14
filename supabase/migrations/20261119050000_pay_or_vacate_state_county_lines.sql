-- The notice PDF draws every table as a boxed amount row, so the State/County and To: block is plain lines, not a table.
do $$
declare n int;
begin
  update letter_templates set html = replace(html,
      '<table><tr><td>State of Wisconsin }<br>Milwaukee County }</td><td>To: [[Lease_All_Tenants]]<br>[[Unit_Address]]</td></tr></table>',
      '<p>State of Wisconsin }<br>Milwaukee County }</p>' || chr(10) || '<p>To: [[Lease_All_Tenants]]<br>[[Unit_Address]]</p>')
  where template_key = '2c-pay-or-vacate' and html like '%<table><tr><td>State of Wisconsin }%';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'State/County block not found'; end if;
end;
$$;
