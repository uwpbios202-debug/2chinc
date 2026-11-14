import fs from "node:fs";
const cut = (src, from, to) => { const a = src.indexOf(from), b = src.indexOf(to, a); if (a < 0 || b < 0) throw new Error("cut " + from); return src.slice(a, b); };
const t91 = fs.readFileSync("supabase/migrations/20261119660000_mirror_email_templates.sql", "utf8");
const t92 = fs.readFileSync("supabase/migrations/20261119680000_mirror_reminders.sql", "utf8");
let html = cut(t91, "-- The words. data:", "-- The one way a Mirror email is queued.");
const caseAt = "    else raise exception 'Unknown Mirror email kind: %', p_kind using errcode = '22023';";
if (html.split(caseAt).length !== 2) throw new Error("case anchor");
html = html.split(caseAt).join(
`    when 'mirror_sharing' then                                                   -- NEW (P2-12)
      if v_safe then
        v_subject := '2nd Chance Housing: a choice you made ends soon';
        v_body := '<p>A choice you made in your 2nd Chance Housing account ends' || coalesce(' on ' || v_when, ' soon') || '. Sign in to see it or change it.</p>' || v_btn;
      else
        v_subject := 'What you share with ' || v_org || ' ends' || coalesce(' on ' || v_when, ' soon');
        v_body := '<p>As you chose, ' || v_org || ' will stop seeing some of what you share in your Human Mirror' || coalesce(' after ' || v_when, ' soon')
          || '. To keep sharing, sign in and change the end date in your Settings. To let it end, do nothing.</p>' || v_btn;
      end if;
` + caseAt);
html = "-- mirror.email_html: live body (20261119660000); NEW: the mirror_sharing words.\n" + html;
let rem = cut(t92, "create or replace function mirror.send_reminders()", "revoke all on function mirror.send_reminders()");
const retAt = "  return jsonb_build_object('held', v_held, 'queued', v_queued, 'skipped', v_skipped);";
if (rem.split(retAt).length !== 2) throw new Error("return anchor");
rem = rem.split(retAt).join(
`  -- NEW (P2-12): 7 days before a share ends, one email per person and organization.
  for x in
    select c.individual_id as ind, c.organization_id as org, c.expires_on, i.auth_email, i.preferred_name, o.name as org_name
      from mirror.consents c join mirror.individuals i on i.id = c.individual_id join mirror.organizations o on o.id = c.organization_id
     where c.revoked_at is null and c.expires_on = current_date + 7 and i.auth_email is not null
     group by c.individual_id, c.organization_id, c.expires_on, i.auth_email, i.preferred_name, o.name
  loop
    s := mirror.email_queue(x.auth_email, 'mirror_sharing',
      jsonb_build_object('first_name', x.preferred_name, 'organization', x.org_name, 'when', trim(to_char(x.expires_on, 'FMDay, FMMonth FMDD')),
                         'ref', 'share:' || x.ind || ':' || x.org || ':' || x.expires_on), x.ind);
    v_held := v_held + (s = 'held')::int; v_queued := v_queued + (s = 'queued')::int; v_skipped := v_skipped + (s = 'skipped')::int;
  end loop;
` + retAt);
rem = "-- mirror.send_reminders: live body (20261119680000); NEW: the sharing-ends-soon loop. The mirror-reminders job is unchanged.\n" + rem;
const out = fs.readFileSync(".claude-tools/p212-head.sql", "utf8") + html + rem + fs.readFileSync(".claude-tools/p212-tail.sql", "utf8");
fs.writeFileSync("supabase/migrations/20261119690000_mirror_consent_end_dates.sql", out);
console.log("ok", out.split("\n").length, "lines");
