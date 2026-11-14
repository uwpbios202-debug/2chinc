-- Applications: staff can save the audio and video answers to their own secure drive and then
-- delete them from the site, the same way as the ID images (apply-staff "recordings_offline").
-- Written answers stay; they are text on the application, not files.
alter table rental_applications add column if not exists recordings_offline_at timestamptz;
alter table rental_applications add column if not exists recordings_offline_by text;
