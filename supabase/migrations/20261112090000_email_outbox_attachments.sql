-- Queued emails can carry attachments (Stephen, 10/12/2026: the Unit 4 basement warning goes out with its photo in the normal batch run,
-- and the whole email, photo included, stays saved on the outbox row). attachments = [{"filename": "...", "content": "<base64>"}].
alter table email_outbox add column if not exists attachments jsonb;
