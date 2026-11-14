-- Security hardening (Stephen, 11/5/2026: "the best and most safe and secure uninterruptible system"), from the Supabase
-- security advisor:
--  1. Every function in public without a fixed search_path gets the one it already uses in practice (the database default
--     "$user", public, extensions), written onto the function, so a caller can never make it resolve names somewhere else.
--     Behaviour does not change. (57 functions on 11/5/2026; functions that belong to an extension are left alone.)
--  2. Trigger functions are not callable through the API by anyone: a trigger fires on its table whatever EXECUTE says.

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as fn
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c where c like 'search_path=%')
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter function %s set search_path = public, extensions, pg_temp', r.fn);
  end loop;

  for r in
    select p.oid::regprocedure as fn
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prorettype = 'trigger'::regtype
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.fn);
  end loop;
end;
$$;
