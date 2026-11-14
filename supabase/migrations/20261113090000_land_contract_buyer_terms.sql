-- Land contract buyer portal (Stephen, 10/13/2026): the buyer sees how late payments are handled, in plain words.
-- Only the two numbers the default notice already uses are returned (days before a notice, days to cure); nothing else from lc_* settings.
create or replace function resident_land_contract_terms()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from land_contracts c join land_contract_buyers b on b.contract_id = c.id
                 where c.status = 'active' and b.tenant_id in (select resident_me())) then
    raise exception 'Resident sign-in required' using errcode = '42501';
  end if;
  return jsonb_build_object('default_days', coalesce(nullif(condo_setting('lc_default_days', '10'), '')::int, 10),
                            'cure_days', coalesce(nullif(condo_setting('lc_cure_days', '30'), '')::int, 30));
end;
$$;
revoke all on function resident_land_contract_terms() from public, anon;
grant execute on function resident_land_contract_terms() to authenticated;
