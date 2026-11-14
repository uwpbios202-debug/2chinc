-- The Human Mirror T6.1 follow-up (Stephen 11/13/2026, T6.1 report finding 2: "should people be able to remove their own needs - yes").
-- A person may remove one of their own needs for good: the need, its history (need_events) and its steps (action_items, which cascade)
-- go with it. Only the person, never a coordinator (a coordinator can still mark a need "no longer needed").
-- Every other single delete of a need stays blocked: mirror.needs_no_delete() lets a delete through only when mirror_need_delete has
-- set a transaction-local flag naming that very need, or when the whole Mirror is being deleted (as before).
-- No table is created, so no new grants are needed (CLAUDE.md, 10/30/2026 rule).

create or replace function mirror.needs_no_delete() returns trigger language plpgsql set search_path = mirror as $$
begin
  if not exists (select 1 from mirror.individuals i where i.id = old.individual_id) then return old; end if;   -- whole Mirror deleted
  if coalesce(current_setting('mirror.need_remove', true), '') = old.id::text then return old; end if;      -- the person's own removal
  raise exception 'Needs are removed only by the person, from their own page; or mark it "no longer needed".' using errcode = '42501';
end $$;

create or replace function public.mirror_need_delete(p_id uuid) returns boolean
language plpgsql security definer set search_path = mirror, public as $$
declare n mirror.needs; g jsonb;
begin
  select * into n from mirror.needs where id = p_id;
  if not found then raise exception 'That need is not available.' using errcode = 'P0002'; end if;
  g := mirror.require(n.individual_id, n.category, 'edit', null, 'needs', n.id::text);
  if (g ->> 'role') <> 'self' then
    raise exception 'Only the person removes a need. You can mark it "no longer needed".' using errcode = '42501';
  end if;
  perform set_config('mirror.need_remove', n.id::text, true);
  delete from mirror.needs where id = n.id;
  perform set_config('mirror.need_remove', '', true);
  return true;
end $$;

revoke all on function public.mirror_need_delete(uuid) from public, anon;
grant execute on function public.mirror_need_delete(uuid) to authenticated, service_role;
