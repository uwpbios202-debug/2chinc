-- The "Bank deposits: N need a look" email went out on every bank sync (the daily job plus every Plaid webhook, which can
-- arrive several at once), repeating the same waiting deposits. From now on each deposit that needs a look is emailed once:
-- bank-feed claims it by setting review_notified_at (an atomic update, so parallel syncs cannot both email it).
alter table public.bank_receipts add column if not exists review_notified_at timestamptz;

-- Deposits already waiting were emailed (several times) on 11/8; mark them so they are not emailed again.
update public.bank_receipts set review_notified_at = now() where status = 'needs_review' and review_notified_at is null;
