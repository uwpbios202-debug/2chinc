select t.topic, (select count(*) from mirror.question_versions v where (coalesce(v.help,'') || ' ' || coalesce(v.options::text,'')) ~* t.pat) in_help_or_options
from (values ('childcare/parenting','child ?care|parent|kids|children|daycare'),('substance use','alcohol|drug|substance|sober|recovery|drinking'),
  ('criminal record','record|convict|expunge|probation|parole|incarcerat|jail|prison'),('debt/credit','debt|credit'),('caregiving','caregiv|care for'),
  ('disability','disab|wheelchair|accessib'),('grief/loss','grief|griev|loss'),('veteran','veteran|military'),('end of life','funeral|burial|advance directive')) t(topic, pat);
