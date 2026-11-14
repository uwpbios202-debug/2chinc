-- Autopay: "view as" is detected on the server, not only after the browser's bind step (Stephen, 10/14/2026).
-- A view-as session used to count as view-as only once the view-as page called "bind" (within 2 minutes). If that step was skipped
-- or failed (18 of the first 51 view-as openings were never bound), the admin's session looked exactly like the tenant's own.
-- Now a session also counts as view-as when it was created during an admin's view-as request for that person (from 1 minute before
-- to 10 minutes after it), bound or not. A token with no session id is treated as view-as (refused): never guess in the tenant's favor.
-- Only autopay uses this; a real tenant is blocked only if they happen to sign in during an unbound view-as of themselves (try again later).
create or replace function autopay_view_as_session()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(auth.jwt() ->> 'session_id', '') = ''
      or exists (select 1 from view_as_grants g
                  where g.target_user_id = auth.uid()
                    and (g.session_id::text = (auth.jwt() ->> 'session_id')
                         or (g.session_id is null and exists (select 1 from auth.sessions s
                                                              where s.id::text = (auth.jwt() ->> 'session_id') and s.user_id = auth.uid()
                                                                and s.created_at between g.created_at - interval '1 minute' and g.created_at + interval '10 minutes'))));
$$;
revoke all on function autopay_view_as_session() from public, anon, authenticated;
