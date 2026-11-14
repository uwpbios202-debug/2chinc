-- One Plaid login can hold both the tenant account and the owner account: key by (item, account), not by item alone.
alter table bank_accounts drop constraint if exists bank_accounts_plaid_item_id_key;
create unique index if not exists bank_accounts_item_account_idx on bank_accounts (plaid_item_id, plaid_account_id);
