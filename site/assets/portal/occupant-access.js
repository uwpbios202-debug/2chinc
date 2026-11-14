// Owner portal, Tenant tab: the owner of an owner-managed unit (Unit 6) gives their tenant a login that opens ONLY Parking and Keys
// (https://2ndchinc.org/unit-access/). "Give access" also emails the tenant the sign-in steps, so the owner has nothing to copy or send
// (Stephen, 11/4/2026); "Send the steps again" resends them.
// Database: supabase/migrations/20261118180000_unit_occupant_parking_keys.sql.
import { client, esc, fmtDate, errorText } from "/assets/portal/portal.js";

export async function mountOccupantAccess(el) {
  if (!el) return;
  const { data, error } = await client.rpc("owner_occupants_mine");
  if (error || !data || !(data.units || []).length) { el.innerHTML = ""; return; }
  const units = data.units, people = data.people || [];
  el.innerHTML = `<section class="panel"><div><h2>Parking and keys login for your tenant</h2>
    <p class="sub">Your tenant can have a login that opens <b>only</b> Parking and Keys (no rent, payments or anything else). Type their name and email and click <b>Give access</b>: we email them the sign-in steps right away.</p></div>
    ${people.length ? `<table style="width:100%;border-collapse:collapse;margin:8px 0">${people.map((p) => `<tr style="border-bottom:1px solid var(--line)">
      <td style="padding:6px 4px"><b>${esc(p.name || "")}</b><br><span class="sub">${esc(p.email)} · Unit ${esc(p.unit)} · since ${fmtDate(String(p.since).slice(0, 10))} · ${p.signed_in ? "has signed in" : "not signed in yet"}</span></td>
      <td style="text-align:right;white-space:nowrap"><button class="linkbtn" type="button" data-oc-resend="${esc(p.id)}">Send the steps again</button> <button class="linkbtn" type="button" data-oc-rm="${esc(p.id)}">Remove</button></td></tr>`).join("")}</table>` : `<p class="sub">No one has parking and keys access yet.</p>`}
    <div class="row" style="gap:8px;flex-wrap:wrap;align-items:flex-end">
      ${units.length > 1 ? `<label>Unit<select id="ocUnit">${units.map((u) => `<option>${esc(u)}</option>`).join("")}</select></label>` : ""}
      <label>Tenant's name<input id="ocName" maxlength="80"></label><label>Tenant's email<input id="ocEmail" type="email" maxlength="120"></label>
      <button class="btn" type="button" id="ocAdd">Give access and email them</button></div>
    <div id="ocMsg" class="msg" role="status"></div></section>`;
  const flush = () => client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
  const $ = (id) => el.querySelector("#" + id), say = (t, ok) => { $("ocMsg").className = "msg " + (ok ? "ok" : "err"); $("ocMsg").textContent = t; };
  $("ocAdd").onclick = async () => {
    const email = $("ocEmail").value.trim();
    $("ocAdd").disabled = true;
    const { error: err } = await client.rpc("owner_occupant_add", { p_unit: $("ocUnit") ? $("ocUnit").value : units[0], p_name: $("ocName").value, p_email: email, p_send: true });
    if (err) { $("ocAdd").disabled = false; return say(await errorText(err)); }
    await flush();
    await mountOccupantAccess(el); el.querySelector("#ocMsg").className = "msg ok"; el.querySelector("#ocMsg").textContent = "Done. We emailed " + email.toLowerCase() + " the sign-in steps. Ask them to check their spam folder if it doesn't arrive.";
  };
  el.querySelectorAll("[data-oc-resend]").forEach((b) => b.onclick = async () => {
    b.disabled = true;
    const { error: err } = await client.rpc("owner_occupant_resend", { p_id: b.dataset.ocResend });
    if (err) { b.disabled = false; return say(await errorText(err)); }
    await flush(); say("Sent again.", true);
  });
  el.querySelectorAll("[data-oc-rm]").forEach((b) => b.onclick = async () => {
    if (!confirm("Remove this person's parking and keys access? They will no longer be able to sign in.")) return;
    const { error: err } = await client.rpc("owner_occupant_remove", { p_id: b.dataset.ocRm });
    if (err) return say(await errorText(err));
    mountOccupantAccess(el);
  });
}
