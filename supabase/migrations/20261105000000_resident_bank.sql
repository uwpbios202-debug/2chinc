-- A resident saves the bank they use for Zelle once, so the Pay page can send them there next time.
-- Only a bank name and its https website are stored. No account numbers.
alter table tenants add column if not exists zelle_bank_name text;
alter table tenants add column if not exists zelle_bank_url text;

create or replace function resident_bank_get()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t tenants;
begin
  select * into t from tenants where id in (select resident_me()) order by created_at limit 1;
  if t.id is null then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('name', t.zelle_bank_name, 'url', t.zelle_bank_url);
end;
$$;
revoke all on function resident_bank_get() from public, anon;
grant execute on function resident_bank_get() to authenticated;

create or replace function resident_bank_save(p_name text, p_url text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(trim(p_url), '') = '' then
    update tenants set zelle_bank_name = null, zelle_bank_url = null where id in (select resident_me());
    return jsonb_build_object('ok', true);
  end if;
  if p_url !~* '^https://[^[:space:]]+\.[^[:space:]]+$' or length(p_url) > 300 then raise exception 'Enter your bank''s website, like https://www.mybank.com'; end if;
  update tenants set zelle_bank_name = left(nullif(trim(p_name), ''), 60), zelle_bank_url = trim(p_url) where id in (select resident_me());
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function resident_bank_save(text, text) from public, anon;
grant execute on function resident_bank_save(text, text) to authenticated;
