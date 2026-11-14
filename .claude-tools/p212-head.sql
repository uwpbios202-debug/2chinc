-- The Human Mirror Phase 9, handoff step 26: P2-12 an end date for sharing, with a reminder before it ends.
-- mirror.consents.expires_on existed and mirror.allowed already stops a share after it (since T2.2), but nobody could set it. Now:
--   * the person sets or clears an end date per organization and topic in Settings (mirror_my_consent_until);
--   * a coordinator records the end date a person without a sign-in gave them (mirror_consent_record_until), like the choice itself;
--   * changing how much is shared keeps the end date (mirror_my_consent_set and mirror_consent_record carry it over);
--   * Settings and the coordinator's "What they share" show the end date (mirror_my_settings, mirror_consents_recorded);
--   * 7 days before, the person gets "Sharing ending soon" (new email kind mirror_sharing, through mirror.email_queue, sent by the daily
--     mirror-reminders job). Like every kind it is OFF until Stephen turns it on (D-42). In safety mode it says only "2nd Chance Housing".
-- End dates: from tomorrow up to 5 years ahead. On the day after the end date the share simply stops (mirror.allowed, unchanged).
-- No new table. Functions below that already existed are copied from their live bodies; only the marked lines are new.

-- ---------------------------------------------------------------- the new email kind
alter table mirror.notifications drop constraint notifications_kind_check;
alter table mirror.notifications add constraint notifications_kind_check check (kind in ('mirror_invite', 'mirror_staff_invite', 'mirror_referral',
  'mirror_appointment', 'mirror_action', 'mirror_security', 'mirror_sharing'));

create or replace function mirror.email_kinds() returns jsonb language sql immutable as $$
  select '[{"kind":"mirror_invite","label":"Invitation to a person","choice":null},
           {"kind":"mirror_staff_invite","label":"Invitation to an organization member","choice":null},
           {"kind":"mirror_referral","label":"Updates on referrals","choice":"referral"},
           {"kind":"mirror_appointment","label":"Appointment reminders","choice":"appointment"},
           {"kind":"mirror_action","label":"Reminders about the plan","choice":"action"},
           {"kind":"mirror_sharing","label":"Sharing ending soon (sent to the person)","choice":null},
           {"kind":"mirror_security","label":"Security notices (always sent)","choice":null}]'::jsonb;
$$;

