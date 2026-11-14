select t.topic, count(distinct p.program_id) programs, string_agg(distinct left(o.legal_name, 40), ' / ') orgs
from (values ('substance use','substance|aoda|addiction|recovery|sober|detox|opioid|alcohol'),('grief','grief|bereave|hospice'),
  ('expungement','expung|pardon|record clear|reentry|re-entry'),('veterans','veteran|\mva\M|hud-vash|ssvf'),('credit/debt','credit counsel|debt|financial counsel|credit repair'),
  ('childcare','child ?care|wisconsin shares|daycare|head start'),('caregiver','caregiver|respite|aging and disability'),('furniture','furniture|bed\M|mattress|household goods'),
  ('clothing','cloth|coat|closet|apparel|shoe'),('laundry','laundr')) t(topic, pat)
left join chpms_programs p on (p.program_name || ' ' || coalesce(p.assistance_form,'') || ' ' || coalesce(p.eligibility_summary,'') || ' ' || coalesce(p.notes,'')) ~* t.pat
left join chpms_orgs o on o.org_id = p.org_id
group by t.topic order by t.topic
