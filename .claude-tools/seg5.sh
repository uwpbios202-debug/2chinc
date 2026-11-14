#!/bin/sh
# Bug-check segment 5: money engine (read-only)
Q=./.claude-tools/supa-query.sh
$Q "select count(*) accounts, count(*) filter (where condo_account_balance(a.id) <> coalesce((select sum(amount) from condo_ledger_entries e where e.account_id=a.id),0)) mismatches, (select count(*) from condo_ledger_entries) entries, (select count(*) from condo_ledger_entries where account_id is null) no_account from condo_ledger_accounts a"
$Q "select count(*) lease_payments_since_1010_no_source from lease_ledger_entries where kind ilike '%payment%' and entry_date >= '2026-10-10' and source is null and payment_report_id is null"
$Q "select count(*) positive_payment_lines_since_1010 from lease_ledger_entries where kind ilike '%payment%' and entry_date >= '2026-10-10' and amount > 0"
$Q "select count(*) dup_late_fee_months from (select lease_id, date_trunc('month', entry_date) m from lease_ledger_entries where entry_date >= '2026-10-10' and (kind ilike '%late%' or gl_account ilike '%late%') and amount > 0 group by 1,2 having count(*) > 1) x"
$Q "select count(*) dup_condo_late_fee_months from (select account_id, date_trunc('month', entry_date) m from condo_ledger_entries where entry_date >= '2026-10-10' and kind ilike '%late%' and amount > 0 and reverses_entry_id is null group by 1,2 having count(*) > 1) x"
$Q "select position('late' in lower(prosrc)) > 0 mentions_late from pg_proc where proname='lease_rent_due'"
$Q "select kind, count(*) from lease_ledger_entries where entry_date >= '2026-10-10' group by 1 order by 2 desc"
