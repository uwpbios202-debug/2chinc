-- Parking decal pick-up (Stephen, 11/11/2026).
-- When someone registers a vehicle, the unit's people (parking_unit_people: tenants on the active lease, the owner of an owner-occupied unit,
-- Unit 6's parking-and-keys occupant) are emailed WHERE to pick up the unit's rear-view mirror parking decal, with a photo of the spot.
--   * One pick-up spot per unit: parking_decal_pickups (where_text + a marked-up photo kept as base64 JPEG, sent as an attachment and
--     shown in the email body through content_id). The spots and photos are entered by local-only data migrations, never committed.
--   * Each person gets the email once per unit (parking_decal_pickup_sends). A unit whose red tags were already received gets nothing.
--   * The trigger never blocks a registration: any problem is swallowed and the office still gets its usual "New vehicle registered" email.
--   * Website roles have no access to the tables (functions only).

create table if not exists parking_decal_pickups (
  unit_number text primary key,
  where_text text not null,
  photo_b64 text,
  photo_name text not null default 'decal-pickup.jpg',
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table parking_decal_pickups enable row level security;
revoke all on table parking_decal_pickups from anon, authenticated;
grant all on table parking_decal_pickups to service_role;

create table if not exists parking_decal_pickup_sends (
  id bigserial primary key,
  unit_number text not null,
  to_email text not null,
  vehicle_id uuid,
  outbox_id bigint,
  created_at timestamptz not null default now(),
  unique (unit_number, to_email)
);
alter table parking_decal_pickup_sends enable row level security;
revoke all on table parking_decal_pickup_sends from anon, authenticated;
grant all on table parking_decal_pickup_sends to service_role;
grant usage, select on sequence parking_decal_pickup_sends_id_seq to service_role;

-- Queue the pick-up email for everyone on the unit who has not had it yet. Returns how many were queued.
create or replace function parking_decal_pickup_notify(p_unit text, p_vehicle uuid default null)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare pk parking_decal_pickups; v vehicles; p record; n int := 0; v_out bigint; v_link text; v_html text;
begin
  select * into pk from parking_decal_pickups where unit_number = p_unit and active;
  if pk.unit_number is null then return 0; end if;
  -- Already have the decal: the unit confirmed its red tags.
  if exists (select 1 from parking_tags t where t.home_unit = p_unit and t.kind = 'resident' and t.received_at is not null) then return 0; end if;
  if p_vehicle is not null then select * into v from vehicles where id = p_vehicle; end if;

  for p in select distinct on (lower(u.email)) u.name, lower(u.email) email, u.kind from parking_unit_people(p_unit) u
            where coalesce(u.email, '') like '%@%'
              and not exists (select 1 from parking_decal_pickup_sends s where s.unit_number = p_unit and s.to_email = lower(u.email))
  loop
    v_link := case p.kind when 'tenant' then 'https://2ndchinc.org/resident/#parking'
                          when 'occupant' then 'https://2ndchinc.org/unit-access/#parking'
                          else 'https://2ndchinc.org/association-owners/roca1/#parking' end;
    v_html := '<p>Hello ' || repair_esc(coalesce(nullif(split_part(trim(coalesce(p.name, '')), ' ', 1), ''), 'there')) || ',</p>'
      || '<p>Thank you for registering your vehicle' || case when v.id is not null and v.kind <> 'visitor' then ' (' || repair_esc(trim(concat_ws(' ', v.color, v.make, v.model))) || coalesce(', plate ' || repair_esc(v.plate), '') || ')' else '' end
      || ' for the Unit ' || repair_esc(p_unit) || ' parking stall. Your parking decal (the tag that hangs on your rear-view mirror) is ready for you to pick up.</p>'
      || '<p><b>Where to pick it up:</b><br>' || replace(repair_esc(pk.where_text), E'\n', '<br>') || '</p>'
      || case when pk.photo_b64 is not null then '<p>The photo shows the spot (red box). It is also attached to this email.</p>'
           || '<p><img src="cid:decal-photo" alt="Where your parking decal is" style="max-width:100%;height:auto;border:1px solid #ccc"></p>' else '' end
      || '<p>Hang it from your rear-view mirror so it can be seen through the windshield. Always Towing checks for it on patrol.</p>'
      || '<p>Your stall and the parking rules: <a href="' || v_link || '">' || v_link || '</a></p>'
      || '<p>Questions? Reply to this email.</p><p>2nd Chance Housing</p>';
    insert into email_outbox (to_email, subject, html, kind, attachments)
    values (p.email, 'Unit ' || p_unit || ': where to pick up your parking decal', v_html, 'parking_decal_pickup',
            case when pk.photo_b64 is not null then jsonb_build_array(jsonb_build_object('filename', pk.photo_name, 'content', pk.photo_b64, 'content_id', 'decal-photo')) end)
    returning id into v_out;
    insert into parking_decal_pickup_sends (unit_number, to_email, vehicle_id, outbox_id) values (p_unit, p.email, p_vehicle, v_out);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function parking_decal_pickup_notify(text, uuid) from public, anon, authenticated;

create or replace function vehicles_decal_pickup()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform parking_decal_pickup_notify(new.unit_number, new.id);
  exception when others then
    raise warning 'parking decal pick-up email for unit % not queued: %', new.unit_number, sqlerrm;
  end;
  return new;
end;
$$;
revoke all on function vehicles_decal_pickup() from public, anon, authenticated;

drop trigger if exists vehicles_decal_pickup on vehicles;
create trigger vehicles_decal_pickup after insert on vehicles
  for each row when (new.status = 'active') execute function vehicles_decal_pickup();
