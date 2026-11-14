-- Landlord Recruitment Database check, part 1 (see lrd-landlord-db-check.sql). Fictional people; rolled back by part 2.
create temp table lrd_chk (n int, line text) on commit drop;
grant all on lrd_chk to authenticated, anon;
do $chk$
declare
  j jsonb; k jsonb; ok boolean; e text; v uuid; nid text;
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid(); up uuid := gen_random_uuid(); us uuid := gen_random_uuid();
  sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sp uuid := gen_random_uuid(); ss uuid := gen_random_uuid();
  na uuid; nb uuid; pa text; pb text; pp text; ps text;
begin
  insert into auth.users (id, email) values (ua, 'check.lla@example.invalid'), (ub, 'check.llb@example.invalid'),
    (up, 'check.llp@example.invalid'), (us, 'check.lls@example.invalid');
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at) values
    (sa, ua, now(), now(), now()), (sb, ub, now(), now(), now()), (sp, up, now(), now(), now()), (ss, us, now(), now(), now());
  insert into navigators (name, email, status) values ('CHECK NAV A', 'check.lla@example.invalid', 'pilot') returning id into na;
  insert into navigators (name, email, status) values ('CHECK NAV B', 'check.llb@example.invalid', 'pilot') returning id into nb;
  insert into navigators (name, email, status) values ('CHECK NAV P', 'check.llp@example.invalid', 'preview');
  insert into condo_staff (email, name) values ('check.lls@example.invalid', 'CHECK STAFF');
  pa := json_build_object('sub', ua, 'email', 'check.lla@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sa)::text;
  pb := json_build_object('sub', ub, 'email', 'check.llb@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sb)::text;
  pp := json_build_object('sub', up, 'email', 'check.llp@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', sp)::text;
  ps := json_build_object('sub', us, 'email', 'check.lls@example.invalid', 'aal', 'aal2', 'role', 'authenticated', 'session_id', ss)::text;

  -- 1 seed counts match the workbook; tables closed to the website roles
  ok := (select count(*) = 41 from lrd_landlords) and (select count(*) = 17 from lrd_channels) and (select count(*) = 10 from lrd_business_networks)
    and (select count(*) = 24 from lrd_property_managers where landlord_id is not null) and (select count(*) = 16 from lrd_large_networks where landlord_id is not null)
    and (select count(*) = 11 from lrd_market_profile) and (select value = 19000 from lrd_market_profile where is_derived)
    and (select count(*) = 16 from lrd_data_sources) and (select count(*) = 3 from lrd_data_sources where not adopted)
    and (select count(*) = 22 from lrd_gap_analysis) and (select count(*) = 7 from lrd_build_steps) and (select count(*) = 47 from lrd_sources)
    and (select count(*) = 0 from lrd_outreach) and (select count(*) = 1 from lrd_landlords where do_not_partner)
    and not has_table_privilege('authenticated', 'lrd_landlords', 'select') and not has_table_privilege('anon', 'lrd_outreach', 'select')
    and not has_function_privilege('anon', 'lrd_leads(jsonb)', 'execute') and not has_function_privilege('authenticated', 'lrd_require(boolean)', 'execute');
  insert into lrd_chk values (1, format('1 seed counts (41/17/10/24/16/11, estimate 19000, 3 not adopted, 22/7/47) and closed tables: %s', ok));

  perform set_config('role', 'authenticated', true);
  -- 2 nobody signed in is refused; a Navigator sees 24 leads (large networks hidden) and all 41 with include_large
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  begin perform lrd_leads('{}'); ok := false; exception when insufficient_privilege then ok := true; end;
  perform set_config('request.jwt.claims', pa, true);
  ok := ok and jsonb_array_length(lrd_leads('{}')) = 24 and jsonb_array_length(lrd_leads('{"include_large":true}')) = 41
    and (lrd_directory()->>'role') = 'navigator' and lrd_directory()->'gap_analysis' = 'null'::jsonb;
  insert into lrd_chk values (2, format('2 signed-out refused; Navigator sees 24 leads, 41 with large networks, no office sheets: %s', ok));

  -- 3 A claims PM02; B cannot, and sees only "another Navigator"
  j := lrd_claim('LLS-PM02', true);
  ok := j->>'claim' = 'you';
  perform set_config('request.jwt.claims', pb, true);
  begin perform lrd_claim('LLS-PM02', true); ok := false; exception when raise_exception then null; end;
  ok := ok and (lrd_lead('LLS-PM02')->>'claim') = 'another Navigator';
  insert into lrd_chk values (3, format('3 one Navigator at a time; the other sees "another Navigator": %s', ok));

  -- 4 A logs a contact with an opt-in phone; B sees none of it; staff see it with A's name
  perform set_config('request.jwt.claims', pa, true);
  perform lrd_log('{"landlord_id":"LLS-PM02","channel_id":"CH09","contact_method":"Phone (business line)","outcome":"Interested - send LIFT packet","units_offered":"3","accepts_vouchers":"Yes","lift_interest":"Yes","opt_in_phone":"(414) 555-0100","notes":"CHECK"}');
  j := lrd_lead('LLS-PM02');
  ok := j->>'contact_status' = 'Interested' and j->>'phone_opt_in' = '(414) 555-0100' and jsonb_array_length(j->'outreach') = 1 and j->'outreach'->0->>'by' = 'You';
  perform set_config('request.jwt.claims', pb, true);
  ok := ok and jsonb_array_length(lrd_lead('LLS-PM02')->'outreach') = 0 and (lrd_lead('LLS-PM02')->>'outreach_count')::int = 0;
  begin perform lrd_log('{"landlord_id":"LLS-PM02","contact_method":"Postal mail","outcome":"Left information"}'); ok := false; exception when raise_exception then null; end;
  perform set_config('request.jwt.claims', ps, true);
  j := lrd_lead('LLS-PM02');
  ok := ok and jsonb_array_length(j->'outreach') = 1 and j->'outreach'->0->>'by' = 'CHECK NAV A' and j->>'claim' = 'CHECK NAV A' and lrd_directory()->>'role' = 'staff'
    and jsonb_array_length(lrd_directory()->'gap_analysis') = 22;
  insert into lrd_chk values (4, format('4 own outreach only for Navigators, staff see who: %s', ok));

  -- 5 not-to-recruit and screen-first are blocked; sign-up makes a PRIVATE nav_landlords row for A
  perform set_config('request.jwt.claims', pa, true);
  begin perform lrd_claim('LLS-X02', true); ok := false; exception when raise_exception then ok := true; end;
  begin perform lrd_claim('LLS-NET01', true); ok := false; exception when raise_exception then null; end;
  begin perform lrd_sign_up('LLS-PM19'); ok := false; exception when raise_exception then null; end;
  v := lrd_sign_up('LLS-PM02', '{"contact_name":"CHECK CONTACT"}');
  perform set_config('role', 'postgres', true);
  ok := ok and exists (select 1 from nav_landlords l where l.id = v and l.added_by_navigator = na and not l.shared and l.phone = '(414) 555-0100'
           and l.business_name = 'Residential Renters' and l.accepts_vouchers);
  perform set_config('role', 'authenticated', true);
  ok := ok and (lrd_lead('LLS-PM02')->>'contact_status') = 'Signed up' and (lrd_lead('LLS-PM02')->>'can_sign_up')::boolean = false;
  begin perform lrd_sign_up('LLS-PM02'); ok := false; exception when raise_exception then null; end;
  perform set_config('request.jwt.claims', pb, true);
  ok := ok and lrd_lead('LLS-PM02')->>'nav_landlord_id' is null;
  insert into lrd_chk values (5, format('5 large network, Highgrove and screen-first blocked; sign-up private to A; B never sees the link: %s', ok));

  -- 6 do-not-contact stops everyone
  perform set_config('request.jwt.claims', pa, true);
  perform lrd_log('{"landlord_id":"LLS-PM03","contact_method":"Postal mail","outcome":"Do not contact","opt_in_email":"x@example.invalid"}');
  perform set_config('role', 'postgres', true);
  ok := (select do_not_contact and claimed_by_navigator is null and email_opt_in is null from lrd_landlords where landlord_id = 'LLS-PM03');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', pb, true);
  begin perform lrd_claim('LLS-PM03', true); ok := false; exception when raise_exception then null; end;
  perform set_config('request.jwt.claims', ps, true);
  begin perform lrd_log('{"landlord_id":"LLS-PM03","contact_method":"Postal mail","outcome":"Left information"}'); ok := false; exception when raise_exception then null; end;
  insert into lrd_chk values (6, format('6 do-not-contact: no opt-in kept, claim cleared, nobody can claim or log: %s', ok));

  -- 7 Preview is read only; only staff edit; staff add an office lead
  perform set_config('request.jwt.claims', pp, true);
  ok := jsonb_array_length(lrd_leads('{}')) = 24;
  begin perform lrd_claim('LLS-PM05', true); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', pa, true);
  begin perform lrd_save('{"landlord_id":"LLS-PM05","our_note":"x"}'); ok := false; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', ps, true);
  nid := lrd_save('{"owner_or_company_name":"CHECK OFFICE LEAD","segment":"micro (1-4 units)","independent_flag":"Yes"}');
  ok := ok and nid like 'LLS-L%' and (lrd_lead(nid)->>'is_local')::boolean;
  perform lrd_channel_save('{"kind":"channel","id":"CH01","our_status":"reached_out","our_note":"CHECK"}');
  perform set_config('request.jwt.claims', pa, true);
  ok := ok and (select c->>'our_note' from jsonb_array_elements(lrd_directory()->'channels') c where c->>'channel_id' = 'CH01') is null;
  insert into lrd_chk values (7, format('7 Preview read only; Navigators cannot edit; office adds a lead; office notes hidden from Navigators: %s', ok));

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $chk$;
reset role;
