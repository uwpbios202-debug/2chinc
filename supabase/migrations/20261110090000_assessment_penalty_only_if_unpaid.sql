-- A special-assessment late penalty is charged only when THAT assessment installment is still unpaid (payments applied oldest charge first),
-- not whenever the unit owes anything. Before, a unit that had paid the assessment but still owed older dues was penalized 12% on it.

CREATE OR REPLACE FUNCTION public.roca_auto_assessments(p_today date, p_live boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; v_id bigint; n int := 0; n_pen int := 0; v_due jsonb := '[]'::jsonb;
  v_pen boolean := coalesce((select value from portal_settings where key = 'roca_assessment_penalty'), 'off') = 'on';
  v_pct numeric := coalesce((select value from portal_settings where key = 'roca_assessment_penalty_pct'), '12')::numeric;
  v_days int := coalesce((select value from portal_settings where key = 'roca_assessment_penalty_days'), '15')::int;
begin
  for c in select ch.*, a.title, a.status a_status, r.number from roca_assessment_charges ch join roca_assessments a on a.id = ch.assessment_id
           join roca_resolutions r on r.id = a.resolution_id
           where ch.ledger_entry_id is null and ch.due_date <= p_today and a.status = 'scheduled' order by ch.due_date, ch.unit_number loop
    v_due := v_due || jsonb_build_array(jsonb_build_object('unit', c.unit_number, 'amount', c.amount, 'due', c.due_date));
    if p_live then
      v_id := roca_post_charge(c.unit_number, 'Special Assessment', c.due_date, c.amount, 'Special assessment',
        'Special assessment ' || coalesce(c.number, '') || ': ' || c.title || case when (select installments from roca_assessments where id = c.assessment_id) > 1 then ' (installment ' || c.installment || ')' else '' end,
        'billing', 'automation', 'Resolution ' || coalesce(c.number, ''));
      update roca_assessment_charges set ledger_entry_id = v_id, posted_at = now() where id = c.id;
      n := n + 1;
    end if;
  end loop;
  if p_live then
    update roca_assessments a set status = 'complete' where status = 'scheduled'
      and not exists (select 1 from roca_assessment_charges ch where ch.assessment_id = a.id and ch.ledger_entry_id is null);
  end if;
  if v_pen then
    for c in select ch.*, r.number from roca_assessment_charges ch join roca_assessments a on a.id = ch.assessment_id join roca_resolutions r on r.id = a.resolution_id
             where ch.ledger_entry_id is not null and ch.penalty_entry_id is null and ch.due_date + v_days < p_today
               and exists (select 1 from roca_unit_unpaid_charges(ch.unit_number, p_today) up where up.entry_id = ch.ledger_entry_id) loop
      if p_live then
        v_id := roca_post_charge(c.unit_number, 'Late Fee Income', p_today, round(c.amount * v_pct / 100, 2), 'Late penalty',
          'Late penalty ' || v_pct || '% on special assessment ' || coalesce(c.number, ''), 'billing', 'automation', 'By-Laws §1500(6)');
        update roca_assessment_charges set penalty_entry_id = v_id where id = c.id;
      end if;
      n_pen := n_pen + 1;
    end loop;
  end if;
  return jsonb_build_object('installments_due', jsonb_array_length(v_due), 'posted', n, 'penalties', n_pen, 'penalty_setting', case when v_pen then 'on' else 'off' end, 'due', v_due);
end;
$function$;
