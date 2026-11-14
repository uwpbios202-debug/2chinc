// Parking lot map and temporary stall switches (resident portal #parking, owner portal #parking, staff /parking/).
// 16 stalls numbered to match the units, plus guest and contractor stalls the office adds. Occupants can trade stalls
// with another unit for a while: one asks, the other accepts or declines, either can end it. Occupants see unit
// numbers and vehicle descriptions only. Database: supabase/migrations/20261106000000_parking_lot.sql.
import { client, esc, fmtDate, errorText } from "/assets/portal/portal.js";

export const LOT_CSS = `
.pl{display:grid;gap:14px}.pl-card{background:#fff;border:1px solid #d9dfd6;border-radius:12px;padding:14px 16px}
.pl h2{margin:0 0 6px;font-size:1.2rem}.pl-sub{color:#5b6573;font-size:.88rem;margin:0}
.pl-scroll{overflow-x:auto;margin-top:10px;padding-bottom:4px}
.pl-lot{display:grid;gap:8px;min-width:min-content;background:#4a4f55;border-radius:10px;padding:12px}
.pl-row{display:grid;gap:6px}.pl-rowlbl{color:#d6dbe0;font-size:.72rem;letter-spacing:.06em;text-transform:uppercase}
.pl-stall{min-width:56px;height:74px;border:2px dashed #f4f1e6;border-top:0;border-radius:0 0 6px 6px;background:#5c6168;color:#fff;cursor:pointer;
  display:flex;flex-direction:column;align-items:center;justify-content:center;font:inherit;padding:2px 4px;position:relative}
.pl-stall b{font-size:1.25rem;line-height:1}.pl-stall small{font-size:.66rem;opacity:.9;line-height:1.1;text-align:center}
.pl-stall.guest{background:#2f5d8a}.pl-stall.contractor{background:#8a5a1f}
.pl-stall.swapped{box-shadow:inset 0 0 0 3px #f2c94c}.pl-stall.held::after{content:"";position:absolute;inset:0;background:repeating-linear-gradient(45deg,transparent 0 6px,rgba(255,255,255,.14) 6px 12px)}
.pl-stall.owned{background:#2f6b4f;border-color:#bfe8cf}.pl-stall.mine{outline:3px solid #7ed957;outline-offset:2px}.pl-stall.sel{outline:3px solid #fff;outline-offset:2px}
.pl-stall.nopark{background:#b3261e;border-color:#ffd6d2;color:#fff}.pl-stall.nopark small{font-weight:700;opacity:1}
.pl-car{width:22px;height:12px;border-radius:4px;background:#e9e3d0;margin:4px 0 2px}
.pl-legend{display:flex;gap:12px;flex-wrap:wrap;font-size:.8rem;color:#5b6573;margin-top:8px}.pl-legend span{display:inline-flex;align-items:center;gap:5px}
.pl-sw{display:inline-block;width:14px;height:14px;border-radius:3px;background:#5c6168}
.pl-detail{margin-top:10px;border-top:1px solid #eef1ec;padding-top:10px;font-size:.95rem}
.pl-form{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px;margin-top:10px}
.pl-form label{display:grid;gap:3px;font-size:.85rem;color:#5b6573}.pl-form .wide{grid-column:1/-1}
.pl-form input,.pl-form select,.pl-form textarea{font:inherit;padding:8px 10px;border:1px solid #cfd6cc;border-radius:8px;color:#1b2430;background:#fff;width:100%;box-sizing:border-box}
.pl-btn{background:#2e7d1f;color:#fff;border:0;border-radius:999px;padding:9px 18px;font-weight:700;cursor:pointer}.pl-btn:disabled{opacity:.5}
.pl-btn.ghost{background:#fff;color:#2e7d1f;border:1px solid #2e7d1f}
.pl-pill{display:inline-block;font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;border-radius:20px;padding:.12rem .55rem;background:#e7f3e3;color:#2e7d1f}
.pl-pill.pending{background:#fff3cd;color:#7a5200}.pl-pill.declined,.pl-pill.cancelled,.pl-pill.ended{background:#eee;color:#555}
.pl-msg{min-height:1.2em;font-size:.9rem;margin-top:6px}.pl-msg.err{color:#b3261e}.pl-msg.ok{color:#2e7d1f}`;

export function ensureLotCss() {
  if (document.getElementById("pl-css")) return;
  const s = document.createElement("style"); s.id = "pl-css"; s.textContent = LOT_CSS; document.head.appendChild(s);
}

const KIND = { unit: "Unit stall", guest: "Guest stall", contractor: "Contractor stall" };
const today = () => new Date().toLocaleDateString("en-CA");
const carText = (v) => v.summary || [v.color, v.year, v.make, v.model].filter(Boolean).join(" ") + (v.kind === "loaner" ? " (loaner)" : v.kind === "visitor" ? " (regular visitor)" : "");

// The map. `mine` = unit numbers to outline; `sel` = selected stall id.
export function lotHtml(D, { mine = [], owned = [], sel = null } = {}) {
  const stalls = D.stalls || [];
  if (!stalls.length) return `<p class="pl-sub">No stalls on the map yet.</p>`;
  const rows = [...new Set(stalls.map((s) => s.row))].sort((a, b) => a - b);
  const maxPos = Math.max(...stalls.map((s) => s.pos));
  return `<div class="pl-scroll"><div class="pl-lot">${rows.map((r) => {
    const rs = stalls.filter((s) => s.row === r);
    const kinds = [...new Set(rs.map((s) => s.kind))];
    const lbl = kinds.length === 1 && kinds[0] !== "unit" ? (kinds[0] === "guest" ? "Guest" : "Contractor") : rs.every((s) => s.kind === "unit") ? "Units " + rs[0].label + "–" + rs[rs.length - 1].label : "Row " + r;
    return `<div class="pl-rowlbl">${esc(lbl)}</div><div class="pl-row" style="grid-template-columns:repeat(${maxPos},minmax(56px,1fr))">${rs.map((s) => {
      const swapped = s.kind === "unit" && s.used_by && s.used_by !== s.home_unit;
      const blocked = s.kind === "unit" && (D.blocked || []).includes(s.home_unit);
      const cls = ["pl-stall", s.kind, blocked ? "nopark" : "", swapped ? "swapped" : "", s.hold ? "held" : "", s.kind === "unit" && mine.includes(s.used_by) ? "mine" : "", s.kind === "unit" && owned.includes(s.home_unit) ? "owned" : "", sel === s.id ? "sel" : ""].join(" ");
      const own = s.kind === "unit" && owned.includes(s.home_unit) && !mine.includes(s.home_unit);
      const sub = blocked ? "NO PARKING · dues" : s.kind === "unit" ? (swapped ? "Unit " + s.used_by + " today" : (s.vehicles || []).length ? (own ? "tenant" : "") : s.occupancy === "vacant" ? (own ? "yours · vacant" : "vacant") : own ? "tenant" : "")
        : s.hold ? (s.hold.holder_kind === "guest" ? "guest" + (s.hold.for_unit ? " of " + s.hold.for_unit : "") : s.hold.holder_kind) : "open";
      return `<button type="button" class="${cls}" style="grid-column:${s.pos}" data-stall="${esc(s.id)}" title="${esc(KIND[s.kind] + " " + s.label)}">
        <b>${esc(s.label)}</b>${(!blocked && s.kind === "unit" && (s.vehicles || []).length) || s.hold ? `<span class="pl-car"></span>` : ""}<small>${esc(sub)}</small></button>`;
    }).join("")}</div>`;
  }).join("")}</div></div>
  <div class="pl-legend"><span><i class="pl-sw"></i>Unit stall</span><span><i class="pl-sw" style="background:#2f5d8a"></i>Guest</span><span><i class="pl-sw" style="background:#8a5a1f"></i>Contractor</span>
    <span><i class="pl-sw" style="box-shadow:inset 0 0 0 3px #f2c94c"></i>Switched</span><span><i class="pl-sw" style="background:repeating-linear-gradient(45deg,#5c6168 0 3px,#8a8f96 3px 6px)"></i>Held</span>
    ${(D.blocked || []).length ? `<span><i class="pl-sw" style="background:#b3261e"></i>No parking (dues)</span>` : ""}    ${mine.length ? `<span><i class="pl-sw" style="outline:3px solid #7ed957"></i>Yours</span>` : ""}${owned.length ? `<span><i class="pl-sw" style="background:#2f6b4f"></i>You own</span>` : ""}</div>`;
}

// What one stall holds that day. Staff rows carry names, emails and plates; occupant rows don't.
export function stallDetailHtml(s, D, owned = []) {
  if (!s) return "";
  const out = [`<b>${esc(KIND[s.kind])} ${esc(s.label)}</b> · ${fmtDate(D.date)}`];
  if (s.kind === "unit" && (D.blocked || []).includes(s.home_unit)) return `<div class="pl-detail" style="color:#b3261e"><b>${out[0].replace(/<[^>]+>/g, "")}</b><br><b>NO PARKING: Unit ${esc(s.home_unit)} has an association dues violation and is not allowed to park.</b></div>`;
  if (s.kind === "unit") {
    out.push(s.used_by !== s.home_unit ? `Used by <b>Unit ${esc(s.used_by)}</b> (switched with Unit ${esc(s.home_unit)} ${fmtDate(s.swap.start_date)} to ${fmtDate(s.swap.end_date)})` : `Belongs to <b>Unit ${esc(s.home_unit)}</b>${s.occupancy === "vacant" ? " (vacant)" : ""}`);
    if (owned.includes(s.home_unit)) out.push(s.occupancy === "vacant" ? `<b>You own Unit ${esc(s.home_unit)}.</b> It is vacant, so this stall is yours to use whenever you like.` : s.occupancy === "tenant" ? `<b>You own Unit ${esc(s.home_unit)}.</b> A tenant lives there and uses this stall.` : `<b>You own Unit ${esc(s.home_unit)}.</b>`);
    if (s.people && s.people.length) out.push("Who: " + s.people.map((p) => esc(p.name || "") + (p.email ? ` &lt;${esc(p.email)}&gt;` : "") + ` (${esc(p.kind)})`).join(", "));
    out.push((s.vehicles || []).length ? s.vehicles.map((v) => "🚗 " + esc(carText(v)) + (v.tenant ? " · " + esc(v.tenant) : "")).join("<br>") : `<span class="pl-sub">No vehicle registered.</span>`);
  } else if (s.hold) {
    const h = s.hold;
    out.push(`Held for a <b>${esc(h.holder_kind)}</b>${h.for_unit ? " (Unit " + esc(h.for_unit) + ")" : ""}, ${fmtDate(h.start_date)} to ${fmtDate(h.end_date)}`);
    if (h.holder_name || h.company) out.push(esc([h.holder_name, h.company].filter(Boolean).join(", ")));
    if (h.vehicle || h.plate) out.push("🚗 " + esc([h.vehicle, h.plate ? "plate " + h.plate + (h.plate_state ? " " + h.plate_state : "") : ""].filter(Boolean).join(", ")));
    if (h.guest && h.guest.decal_number) out.push("Decal " + esc(h.guest.decal_number));
    if (h.note) out.push(esc(h.note));
  } else out.push(`<span class="pl-sub">Open${s.kind === "guest" ? ": guests park here only with an approved request and the office's decal" : ": for contractors the office has scheduled"}.</span>`);
  if (s.note) out.push(`<span class="pl-sub">${esc(s.note)}</span>`);
  return `<div class="pl-detail">${out.join("<br>")}</div>`;
}

const STATUS = (w) => w.status === "accepted" && w.start_date > today() ? "accepted · starts " + fmtDate(w.start_date) : w.status === "accepted" ? "switched now" : w.status;

export async function mountStalls(el) {
  ensureLotCss();
  let date = today(), sel = null;
  async function draw(msg) {
    el.innerHTML = `<p class="pl-sub">Loading the parking lot…</p>`;
    const { data: D, error } = await client.rpc("parking_lot_mine", { p_date: date });
    if (!error) D.blocked = (await client.rpc("parking_blocked_units")).data || [];
    if (error) { el.innerHTML = `<p class="pl-msg err">${esc(await errorText(error))}</p>`; return; }
    const mine = (D.my_units || []).map((u) => u.unit), owned = (D.owned || []).map((u) => u.unit), t = today();
    const { data: T } = date === t ? { data: D } : await client.rpc("parking_lot_mine", { p_date: t });
    const yours = mine.map((u) => {
      const s = (T.stalls || []).find((x) => x.kind === "unit" && x.used_by === u);
      return s && s.home_unit !== u ? `Today Unit ${esc(u)} parks in <b>stall ${esc(s.label)}</b> (switched with Unit ${esc(s.home_unit)} until ${fmtDate(s.swap.end_date)}).` : `Unit ${esc(u)} parks in <b>stall ${esc(u)}</b>.`;
    });
    const ownedOnly = (D.owned || []).filter((o) => !mine.includes(o.unit)).map((o) => o.occupancy === "vacant" ? `You own Unit ${esc(o.unit)}: it is vacant, so <b>stall ${esc(o.unit)}</b> is yours to use whenever you like.` : `You own Unit ${esc(o.unit)}: a tenant lives there and uses <b>stall ${esc(o.unit)}</b>.`);
    const others = (D.unit_stalls || []).filter((u) => !mine.includes(u));
    const swaps = D.swaps || [];
    el.innerHTML = `<div class="pl">
      ${mine.length || ownedOnly.length ? `<div class="pl-card"><h2>Your stall${mine.length + ownedOnly.length > 1 ? "s" : ""}</h2><p>${yours.concat(ownedOnly).join("<br>")}</p></div>` : ""}
      <div class="pl-card"><h2>Parking lot</h2><p class="pl-sub">Every unit has the stall with its own number. Tap a stall to see whose it is.</p>
        <div class="pl-form" style="max-width:240px"><label>Show the lot on<input type="date" id="plDate" value="${esc(date)}"></label></div>
        ${lotHtml(D, { mine, owned, sel })}<div id="plDetail">${stallDetailHtml((D.stalls || []).find((s) => s.id === sel), D, owned)}</div></div>
      ${mine.length ? `<div class="pl-card"><h2>Switch stalls for a while</h2>
        <p class="pl-sub">Ask another unit to trade stalls for some days. Nothing changes unless they accept; the office is told either way. Each of you can end it early.${D.office_phone ? " Questions: " + esc(D.office_phone) + "." : ""}</p>
        <form class="pl-form" id="plForm" novalidate>
          ${mine.length > 1 ? `<label>My unit<select id="plMine">${mine.map((u) => `<option>${esc(u)}</option>`).join("")}</select></label>` : ""}
          <label>Switch with unit<select id="plOther"><option value="">Choose…</option>${others.map((u) => `<option>${esc(u)}</option>`).join("")}</select></label>
          <label>First day<input type="date" id="plStart" min="${t}"></label><label>Last day<input type="date" id="plEnd" min="${t}"></label>
          <label class="wide">Why? (optional; the other unit sees it)<textarea id="plNote" rows="2" maxlength="500"></textarea></label>
          <div class="wide"><button class="pl-btn" type="submit" id="plSend">Ask</button><div class="pl-msg" id="plMsg" role="status"></div></div>
        </form></div>
      <div class="pl-card"><h2>Your switches</h2>${swaps.length ? swaps.map((w) => {
        const asked = mine.includes(w.unit_a), other = asked ? w.unit_b : w.unit_a, me = asked ? w.unit_a : w.unit_b, live = w.end_date >= t;
        return `<div style="border-top:1px solid #eef1ec;padding:10px 0"><div style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap">
          <b>Unit ${esc(me)} ⇄ Unit ${esc(other)}</b><span class="pl-pill ${esc(w.status)}">${esc(STATUS(w))}</span></div>
          <div class="pl-sub">${fmtDate(w.start_date)} to ${fmtDate(w.end_date)} · ${asked ? "you asked" : "Unit " + esc(other) + " asked"}${w.note ? " · “" + esc(w.note) + "”" : ""}${w.decision_note ? " · reply: “" + esc(w.decision_note) + "”" : ""}</div>
          ${w.status === "pending" && !asked && live ? `<div style="display:flex;gap:8px;margin-top:6px"><button class="pl-btn" type="button" data-plok="${esc(w.id)}">Accept</button><button class="pl-btn ghost" type="button" data-plno="${esc(w.id)}">Decline</button></div>` : ""}
          ${w.status === "pending" && asked ? `<button class="pl-btn ghost" type="button" data-plend="${esc(w.id)}" style="margin-top:6px">Cancel request</button>` : ""}
          ${w.status === "accepted" && live ? `<button class="pl-btn ghost" type="button" data-plend="${esc(w.id)}" style="margin-top:6px">${w.start_date > t ? "Cancel switch" : "End switch today"}</button>` : ""}
        </div>`;
      }).join("") : `<p class="pl-sub">No switches.</p>`}</div>` : ""}
    </div>`;
    const $ = (id) => el.querySelector("#" + id), v = (id) => ($(id) ? $(id).value.trim() : "");
    if (msg) { $("plMsg").className = "pl-msg ok"; $("plMsg").textContent = msg; }
    $("plDate").onchange = () => { date = v("plDate") || t; draw(); };
    el.querySelectorAll("[data-stall]").forEach((b) => b.onclick = () => {
      sel = b.dataset.stall; el.querySelectorAll(".pl-stall.sel").forEach((x) => x.classList.remove("sel")); b.classList.add("sel");
      $("plDetail").innerHTML = stallDetailHtml((D.stalls || []).find((s) => s.id === sel), D, owned);
    });
    const flush = () => client.functions.invoke("outbox-flush", { body: {} }).catch(() => {});
    if ($("plForm")) {
      $("plStart").onchange = () => { $("plEnd").min = v("plStart") || t; if (!v("plEnd") || v("plEnd") < v("plStart")) $("plEnd").value = v("plStart"); };
      $("plForm").onsubmit = async (e) => {
        e.preventDefault();
        const say = (x, bad) => { $("plMsg").className = "pl-msg " + (bad ? "err" : "ok"); $("plMsg").textContent = x; };
        if (!v("plOther")) return say("Choose the unit to switch with.", true);
        $("plSend").disabled = true; say("Sending…");
        const { error: err } = await client.rpc("parking_swap_request", { p_my_unit: mine.length > 1 ? v("plMine") : mine[0], p_other_unit: v("plOther"),
          p_start: v("plStart") || null, p_end: v("plEnd") || null, p_note: v("plNote") });
        if (err) { $("plSend").disabled = false; return say(await errorText(err), true); }
        flush(); draw("Sent. We'll email you when Unit " + v("plOther") + " answers.");
      };
    }
    el.querySelectorAll("[data-plok],[data-plno]").forEach((b) => b.onclick = async () => {
      const ok = !!b.dataset.plok, note = prompt(ok ? "Accept. Add a note for them? (optional)" : "Decline. Add a note for them? (optional)", "");
      if (note === null) return;
      const { error: err } = await client.rpc("parking_swap_respond", { p_id: b.dataset.plok || b.dataset.plno, p_accept: ok, p_note: note });
      if (err) return alert(await errorText(err));
      flush(); draw();
    });
    el.querySelectorAll("[data-plend]").forEach((b) => b.onclick = async () => {
      if (!confirm("End this switch? Both units and the office are emailed.")) return;
      const { error: err } = await client.rpc("parking_swap_end", { p_id: b.dataset.plend, p_note: null });
      if (err) return alert(await errorText(err));
      flush(); draw();
    });
  }
  await draw();
}
