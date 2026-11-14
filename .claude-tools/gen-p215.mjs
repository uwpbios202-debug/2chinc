// P2-15: build migration 20261119597000 from the LIVE bodies in the scratchpad (p215/*.sql), adding only the rate checks.
// Every replacement must match exactly once, or the script stops. (one-off; not committed)
import fs from "node:fs";
const dir = process.argv[2];
const out = "supabase/migrations/20261119597000_mirror_rate_limits.sql";
const body = (name, pairs) => {
  let s = fs.readFileSync(`${dir}/${name}.sql`, "utf8").trim();
  for (const [a, b] of pairs) {
    const n = s.split(a).length - 1;
    if (n < 1 || (n > 1 && !a.startsWith("\nbegin\n"))) { console.error(`${name}: expected 1 match, found ${n}: ${a.slice(0, 80)}`); process.exit(1); }
    s = s.replace(a, b);   // first occurrence only
  }
  return s + ";\n";
};
const header = `-- The Human Mirror P2-15 (Phase 10 step 30; Stephen 11/13/2026 "go"): rate limits.
-- Before: nothing limited how often a signed-in user could call the Mirror. A stolen session or a runaway script could read every
-- record an organization may see, or flood the database and the office's email, as fast as the network allows.
-- Now (D-42), per sign-in, counted per minute in mirror.rate_counts:
--   * every change through the gate (mirror.allowed, action edit): 600 per 10 minutes (about one a second; hands-free answering stays
--     far below it);
--   * every look at a person's record by an organization member (mirror.allowed, action view, not a quiet probe): 3,000 per hour;
--   * adding people (mirror_person_add): 100 per hour; sending referrals (mirror_referral_send, which emails the office): 30 per hour;
--   * organization reports (mirror_org_report): 60 per hour; platform pages (mirror_platform_overview / _audit): 300 per hour.
-- Over a limit: "Too many in a short time. Please wait a few minutes and try again." (errcode 54000), and for a member's look or change
-- one refusal per 10 minutes is written to the audit log (reason rate_limit). The person's own reads are not limited.
-- The limits are in one function, mirror.rate_limit(bucket). The sign-in code itself is limited by Supabase Auth and Turnstile.
-- The function bodies below are the live ones (11/13/2026) with only the rate checks added. New table: service_role only, row security on.

create table mirror.rate_counts (
  actor_email text not null,
  bucket text not null,
  minute timestamptz not null,
  n int not null default 1,
  primary key (actor_email, bucket, minute)
);
alter table mirror.rate_counts enable row level security;
revoke all on mirror.rate_counts from public, anon, authenticated, service_role;
grant select, insert, update, delete on mirror.rate_counts to service_role;

-- the limits, in one place: how many per how many minutes
create or replace function mirror.rate_limit(p_bucket text, out max_n int, out minutes int)
language sql immutable as $$
  select case p_bucket when 'edit' then 600 when 'look' then 3000 when 'person_add' then 100 when 'referral_send' then 30
                       when 'report' then 60 when 'platform' then 300 else 600 end,
         case p_bucket when 'edit' then 10 else 60 end;
$$;

-- count this call; true while within the limit (no sign-in: true, the gate refuses it anyway)
create or replace function mirror.rate_ok(p_bucket text) returns boolean
language plpgsql security definer set search_path = mirror, public as $$
declare v_email text := lower(auth.email()); l record; v_n bigint;
begin
  if v_email is null then return true; end if;
  l := mirror.rate_limit(p_bucket);
  insert into mirror.rate_counts (actor_email, bucket, minute) values (v_email, p_bucket, date_trunc('minute', now()))
  on conflict (actor_email, bucket, minute) do update set n = mirror.rate_counts.n + 1;
  select coalesce(sum(c.n), 0) into v_n from mirror.rate_counts c
   where c.actor_email = v_email and c.bucket = p_bucket and c.minute > now() - make_interval(mins => l.minutes);
  if random() < 0.01 then delete from mirror.rate_counts where minute < now() - interval '2 days'; end if;
  return v_n <= l.max_n;
end $$;

create or replace function mirror.rate_message() returns text language sql immutable as $$
  select 'Too many in a short time. Please wait a few minutes and try again.'::text;
$$;

create or replace function mirror.rate_require(p_bucket text) returns void
language plpgsql security definer set search_path = mirror, public as $$
begin
  if not mirror.rate_ok(p_bucket) then raise exception '%', mirror.rate_message() using errcode = '54000'; end if;
end $$;

-- a member's refusal for the limit goes to the audit log at most once per 10 minutes per sign-in
create or replace function mirror.rate_refused(p_individual uuid, p_org uuid, p_role text, p_category text, p_table text, p_row text) returns void
language plpgsql security definer set search_path = mirror, public as $$
begin
  if not exists (select 1 from mirror.audit_logs a where a.actor_email = lower(auth.email()) and a.reason = 'rate_limit'
                 and a.at > now() - interval '10 minutes') then
    perform mirror.audit_refused(p_individual, p_org, p_role, p_category, p_table, p_row, 'rate_limit');
  end if;
end $$;

revoke all on function mirror.rate_limit(text), mirror.rate_ok(text), mirror.rate_message(), mirror.rate_require(text),
  mirror.rate_refused(uuid, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function mirror.rate_limit(text), mirror.rate_ok(text), mirror.rate_message(), mirror.rate_require(text),
  mirror.rate_refused(uuid, uuid, text, text, text, text) to service_role;

`;
const parts = [
  body("mirror.allowed", [
    ["    if found then return jsonb_build_object('ok', true, 'role', 'self'); end if;",
     "    if found then\n      if not v_probe and p_action = 'edit' and not mirror.rate_ok('edit') then\n        return jsonb_build_object('ok', false, 'role', 'self', 'reason', mirror.rate_message());\n      end if;\n      return jsonb_build_object('ok', true, 'role', 'self');\n    end if;"],
    ["    if v_sensitive or p_action = 'edit' then\n      if not v_probe then perform mirror.audit(",
     "    if not v_probe and not mirror.rate_ok(case when p_action = 'edit' then 'edit' else 'look' end) then\n      perform mirror.rate_refused(p_individual, m.organization_id, m.role, p_category, p_table, p_row);\n      return jsonb_build_object('ok', false, 'role', m.role, 'reason', mirror.rate_message());\n    end if;\n    if v_sensitive or p_action = 'edit' then\n      if not v_probe then perform mirror.audit("],
  ]),
  body("public.mirror_person_add", [["\nbegin\n", "\nbegin\n  perform mirror.rate_require('person_add');\n"]]),
  body("public.mirror_referral_send", [["\nbegin\n", "\nbegin\n  perform mirror.rate_require('referral_send');\n"]]),
  body("public.mirror_org_report", [["\nbegin\n", "\nbegin\n  perform mirror.rate_require('report');\n"]]),
  body("public.mirror_platform_overview", [["\nbegin\n", "\nbegin\n  perform mirror.rate_require('platform');\n"]]),
  body("public.mirror_platform_audit", [["\nbegin\n", "\nbegin\n  perform mirror.rate_require('platform');\n"]]),
];
fs.writeFileSync(out, header + parts.join("\n"));
console.log("wrote " + out + " (" + parts.length + " functions)");
