-- Mirror T8.7 check: inventory of donated goods (D-38). The organization's own stock (coordinators and admins, not volunteers, not
-- other organizations); giving lowers the count and never below 0; giving to a Mirror person needs their everyday "see and change" and
-- shows on their Mirror; giving outside the Mirror keeps no name; a mistake is marked returned. Fictional people; always rolled back.
-- Run: sh ./.claude-tools/mirror-rollback-check.sh <migration or /dev/null> tools/mirror-checks/t87-inventory-check.sql
do $chk$
declare
  r text[] := '{}'; x uuid; y uuid; a uuid; j jsonb; ok boolean; coat uuid; shirt uuid; gift uuid; xname text;
  ua uuid := gen_random_uuid(); uc uuid := gen_random_uuid(); uv uuid := gen_random_uuid(); uy uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sc uuid := gen_random_uuid(); sv uuid := gen_random_uuid(); sy uuid := gen_random_uuid();
  pa text; cx text; vx text; cy text;
begin
  insert into auth.users (id, email) values (ua, 'check.ia@example.invalid'), (uc, 'check.icx@example.invalid'),
    (uv, 'check.ivx@example.invalid'), (uy, 'check.icy@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at)
  values (sa, ua, now(), now(), now()), (sc, uc, now(), now(), now()), (sv, uv, now(), now(), now()), (sy, uy, now(), now(), now());
  pa := json_build_object('sub', ua, 'email', 'check.ia@example.invalid', 'aal', 'aal1', 'role', 'authenticated', 'session_id', sa)::text;
  cx := json_build_object('sub', uc, 'email', 'check.icx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sc)::text;
  vx := json_build_object('sub', uv, 'email', 'check.ivx@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sv)::text;
  cy := json_build_object('sub', uy, 'email', 'check.icy@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sy)::text;
  select id, name into x, xname from mirror.organizations where is_platform_owner;
  insert into mirror.organizations (name, kind) values ('CHECK IY', 'nonprofit') returning id into y;
  insert into mirror.individuals (auth_email, preferred_name, created_by_org) values ('check.ia@example.invalid', 'CHECK IA', x) returning id into a;
  insert into mirror.organization_members (organization_id, auth_email, name, role) values
    (x, 'check.icx@example.invalid', 'CHECK ICX', 'coordinator'), (x, 'check.ivx@example.invalid', 'CHECK IVX', 'volunteer'),
    (y, 'check.icy@example.invalid', 'CHECK ICY', 'coordinator');
  insert into mirror.organization_individuals (organization_id, individual_id, status) values (x, a, 'active');
  perform set_config('role', 'authenticated', true);

  -- 1. the coordinator adds 3 winter coats and 1 shirt; a volunteer and another organization cannot add or see; 0 below is refused
  perform set_config('request.jwt.claims', cx, true);
  coat := (public.mirror_inventory_save(jsonb_build_object('organization_id', x, 'category', 'coats', 'item', 'CHECK Winter coat', 'size', 'L',
            'fits', 'women', 'condition', 'like_new', 'season', 'winter', 'quantity', 3)) ->> 'id')::uuid;
  shirt := (public.mirror_inventory_save(jsonb_build_object('organization_id', x, 'category', 'clothing', 'item', 'CHECK Shirt', 'quantity', 1)) ->> 'id')::uuid;
  ok := coat is not null and shirt is not null;
  begin perform public.mirror_inventory_save(jsonb_build_object('id', coat, 'item', 'CHECK Winter coat', 'quantity', -1)); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', vx, true);
  begin perform public.mirror_inventory(x); ok := false; exception when others then null; end;
  begin perform public.mirror_inventory_save(jsonb_build_object('organization_id', x, 'item', 'CHECK v')); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', cy, true);
  begin perform public.mirror_inventory(x); ok := false; exception when others then null; end;
  begin perform public.mirror_inventory_give(jsonb_build_object('item_id', coat, 'quantity', 1)); ok := false; exception when others then null; end;
  r := r || format('1 coordinator adds; below 0 refused; volunteer and another organization refused: %s', ok);

  -- 2. giving to the person: refused while they share everyday only "see"; with "see and change" 2 coats go (1 left); 5 is refused
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'view');
  perform set_config('request.jwt.claims', cx, true);
  ok := true;
  begin perform public.mirror_inventory_give(jsonb_build_object('item_id', coat, 'quantity', 2, 'individual_id', a)); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', pa, true);
  perform public.mirror_my_consent_set(x, 'general', 'edit');
  perform set_config('request.jwt.claims', cx, true);
  j := public.mirror_inventory_give(jsonb_build_object('item_id', coat, 'quantity', 2, 'individual_id', a, 'note', 'CHECK for the cold'));
  gift := (j ->> 'id')::uuid;
  ok := ok and (j ->> 'left')::int = 1;
  begin perform public.mirror_inventory_give(jsonb_build_object('item_id', coat, 'quantity', 5, 'individual_id', a)); ok := false; exception when others then null; end;
  r := r || format('2 giving needs everyday "see and change"; 2 given leaves 1; more than on hand refused: %s', ok);

  -- 3. a shirt to someone not in the Mirror: counted, no name
  perform public.mirror_inventory_give(jsonb_build_object('item_id', shirt, 'quantity', 1));
  j := public.mirror_inventory(x);
  ok := (j ->> 'given_30')::int = 3 and (j ->> 'given_30_outside')::int = 1
    and (select (v ->> 'quantity')::int from jsonb_array_elements(j -> 'items') v where v ->> 'id' = shirt::text) = 0;
  r := r || format('3 a gift outside the Mirror is only counted (3 given in 30 days, 1 outside, shirts 0): %s', ok);

  -- 4. the person sees what they received and from whom; another organization cannot look
  perform set_config('request.jwt.claims', pa, true);
  j := public.mirror_received() -> 'received';
  ok := jsonb_array_length(j) = 1 and j -> 0 ->> 'organization' = xname and (j -> 0 ->> 'quantity')::int = 2;
  perform set_config('request.jwt.claims', cy, true);
  begin perform public.mirror_received(a, y); ok := false; exception when others then null; end;
  r := r || format('4 the person sees 2 coats from the organization; another organization refused: %s', ok);

  -- 5. a mistake: marked returned, the 2 coats go back (3 on hand), the person sees it was returned; twice is refused
  perform set_config('request.jwt.claims', cx, true);
  perform public.mirror_inventory_return(gift, 'CHECK wrong person');
  ok := (select (v ->> 'quantity')::int from jsonb_array_elements(public.mirror_inventory(x) -> 'items') v where v ->> 'id' = coat::text) = 3;
  begin perform public.mirror_inventory_return(gift, null); ok := false; exception when others then null; end;
  perform set_config('request.jwt.claims', pa, true);
  ok := ok and (public.mirror_received() -> 'received' -> 0 ->> 'returned')::boolean and jsonb_array_length(public.mirror_my_export_received()) = 1;
  r := r || format('5 marked returned: back on the shelf, the person sees it, not twice; in their download: %s', ok);

  raise exception 'MIRROR CHECK RESULTS (all rolled back): % ', array_to_string(r, ' | ');
end $chk$;
