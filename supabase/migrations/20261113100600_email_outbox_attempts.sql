-- Email queue: count the tries (Stephen, 10/14/2026). An email that keeps failing is retried after newer ones and gives up after
-- 5 tries, so it can never block the queue (an autopay reminder stuck behind it would hold that month's withdrawal).
alter table email_outbox add column if not exists attempts int not null default 0;
create index if not exists email_outbox_unsent_idx on email_outbox (attempts, id) where sent_at is null;
