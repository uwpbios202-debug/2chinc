select t.topic, (select count(*) from mirror.reflection_questions q where q.prompt ~* t.pat) questions,
       (select count(*) from mirror.question_versions v where v.prompt ~* t.pat) versions
from (values ('laundry','laundr'),('clothing','cloth|coat|shoe|wardrobe'),('childcare/parenting','child ?care|parent|kids|children|daycare'),
  ('substance use','alcohol|drug|substance|sober|recovery|drinking'),('pets','\mpets?\M|animal|dog|cat\M'),('furniture','furniture|furnish|bed\M|mattress'),
  ('faith/spiritual','faith|spiritual|religio|church|pray'),('criminal record','record|convict|expunge|probation|parole|incarcerat'),
  ('health insurance','insurance|medicaid|badgercare|medicare'),('debt/credit','debt|credit'),('caregiving','caregiv|take care of someone|care for'),
  ('voting/civic','vote|voting|civic'),('hygiene','hygiene|shower|toiletr|bath'),('disability','disab|wheelchair|accessib'),('end of life/planning','will\M|funeral|burial|advance directive'),
  ('grief/loss','grief|griev|loss of|passed away'),('veteran','veteran|military')) t(topic, pat);
