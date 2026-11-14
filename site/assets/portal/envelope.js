// Print #10 envelopes (9.5 x 4.125 in) for notices. Stephen, 11/3/2026: the office printers take envelopes on the RIGHT side
// of the tray only. Default layout: a Letter page with the envelope against its right edge, fed short edge first, text turned
// 90 degrees. Choices (turn, nudge, or a true envelope-size page) are remembered in this browser.
// 11/12/2026: the office now prints on an HP Smart Tank 6000 (envelope in the middle of the tray), so that is the starting layout
// (new storage key, so this computer starts there; a computer with a right-side printer picks "right" once).
const KEY = "envelopePrint2";
const DEFAULTS = { mode: "center", turn: 90, dx: 0, dy: 0 };
const load = () => { try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(KEY) || "{}") }; } catch { return { ...DEFAULTS }; } };
const save = (o) => { try { localStorage.setItem(KEY, JSON.stringify(o)); } catch {} };
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

// 11/12/2026: the 2nd Chance logo sits beside the return address (absolute URL: the print window is about:blank).
const LOGO = location.origin + "/logo.png";
function envelopeHtml(from, e) {
  const names = (e.names || []).slice(0, 4).map(esc).join("<br>");
  return `<div class="env"><img class="logo" src="${LOGO}" alt=""><div class="from">${esc(from).replace(/\n/g, "<br>")}</div>
    <div class="cm">Certified Mail label</div><div class="stamp">Postage</div>
    <div class="to"${(e.names || []).length > 2 ? ' style="font-size:12pt"' : ""}>${names}<br>${esc(e.line1)}<br>${esc(e.line2)}</div></div>`;
}

function css(o) {
  const W = 9.5, H = 4.125, nudge = `translate(${Number(o.dx) || 0}in, ${Number(o.dy) || 0}in)`;
  const env = `.env { position: absolute; width: ${W}in; height: ${H}in; font-family: Arial, Helvetica, sans-serif; color: #000; }
    .logo { position: absolute; left: 0.25in; top: 0.25in; width: 0.65in; height: 0.65in; }
    .from { position: absolute; left: 1.0in; top: 0.27in; font-size: 11pt; line-height: 1.3; }
    /* Kept clear for the large Certified Mail sticker (top middle) and the postage (top right); dashed guides show on screen only. */
    .cm { position: absolute; left: 3.3in; top: 0.2in; width: 4.4in; height: 1.55in; }
    .stamp { position: absolute; left: 8.05in; top: 0.2in; width: 1.2in; height: 1.0in; }
    .cm, .stamp { display: none; }
    @media screen { .cm, .stamp { display: flex; align-items: center; justify-content: center; border: 1.5px dashed #9a9a9a; color: #8a8a8a; font-size: 10pt; box-sizing: border-box; } }
    /* Delivery address in the lower half, below the sticker, USPS style (capitals), clear of the bottom 5/8 in barcode strip. */
    .to { position: absolute; left: 3.5in; top: 2.15in; font-size: 14pt; line-height: 1.35; text-transform: uppercase; }`;
  // "center": an envelope-size page; trays that centre the envelope between the guides (HP Smart Tank 6000) place it themselves.
  if (o.mode === "envelope" || o.mode === "center") {
    return `@page { size: ${W}in ${H}in; margin: 0; } .page { position: relative; width: ${W}in; height: ${H}in; overflow: hidden; page-break-after: always; }
      .env { left: 0; top: 0; transform: ${nudge}; } ${env}`;
  }
  // Letter page; the envelope sits against the right edge (4.125 in wide strip, 9.5 in tall), short edge fed first.
  const rot = Number(o.turn) === 270 ? `translate(0, ${W}in) rotate(-90deg)` : `translate(${H}in, 0) rotate(90deg)`;
  return `@page { size: 8.5in 11in; margin: 0; } .page { position: relative; width: 8.5in; height: 11in; overflow: hidden; page-break-after: always; }
    .strip { position: absolute; left: ${8.5 - H}in; top: 0; width: ${H}in; height: ${W}in; transform: ${nudge}; }
    .strip .env { left: 0; top: 0; transform-origin: 0 0; transform: ${rot}; }
    @media screen { .strip { outline: 1px dashed #999; } } ${env}`;
}

function pages(o, data) {
  return data.list.map((e) => o.mode === "envelope" || o.mode === "center"
    ? `<div class="page">${envelopeHtml(data.from, e)}</div>`
    : `<div class="page"><div class="strip">${envelopeHtml(data.from, e)}</div></div>`).join("");
}

// Opens the print window at once (before any await, so it is not blocked), then fills it.
export async function printEnvelopes(client, ids) {
  const w = window.open("", "_blank");
  if (!w) { alert("Allow pop-ups for 2ndchinc.org to print envelopes."); return; }
  w.document.write("<p style='font-family:Arial'>Preparing envelopes…</p>");
  const { data, error } = await client.rpc("notice_envelopes", { p_ids: ids });
  if (error || !data || !data.list.length) { w.document.body.innerHTML = `<p style='font-family:Arial'>${esc(error ? error.message : "No envelopes to print.")}</p>`; return; }
  const o = load();
  const d = w.document;
  d.open();
  d.write(`<!DOCTYPE html><html><head><meta charset="utf-8"><title>Envelopes (${data.list.length})</title><style id="pcss"></style>
    <style>@media print { .bar { display: none !important; } body { margin: 0; } } @media screen { body { background: #ddd; margin: 0; } .page { background: #fff; margin: 12px auto; box-shadow: 0 1px 4px rgba(0,0,0,.3); } }
      .bar { font-family: Arial, sans-serif; font-size: 14px; background: #fff; padding: 10px 14px; border-bottom: 1px solid #bbb; position: sticky; top: 0; z-index: 2; display: flex; gap: 14px; flex-wrap: wrap; align-items: center; }
      .bar label { display: flex; gap: 6px; align-items: center; } .bar input { width: 60px; } .bar button { font-size: 15px; padding: 6px 16px; font-weight: 700; }
      .bar .tip { flex-basis: 100%; color: #555; font-size: 12.5px; }</style></head><body>
    <div class="bar"><button type="button" id="go">Print ${data.list.length} envelope${data.list.length > 1 ? "s" : ""}</button>
      <label>Layout <select id="mode"><option value="right">Envelope at the right side of the tray (Letter page)</option><option value="center">Envelope in the MIDDLE of the tray (HP Smart Tank)</option><option value="envelope">Envelope-size page (printer places it)</option></select></label>
      <label id="turnL">Text turned <select id="turn"><option value="90">clockwise</option><option value="270">counter-clockwise</option></select></label>
      <label>Move right (in) <input id="dx" type="number" step="0.05"></label><label>Move down (in) <input id="dy" type="number" step="0.05"></label>
      <div class="tip"><b>Middle of the tray (HP Smart Tank):</b> slide the paper guides in against the envelope so it sits in the middle; in the print dialog choose paper size <b>Envelope #10</b>, Margins: None, Scale: Default, Headers and footers off.
        <b>Right side of the tray:</b> load #10 envelopes against the RIGHT guide, short edge first; paper size Letter, Margins: None, Scale 100% (Actual size), Headers and footers off; if the address prints upside down, switch "Text turned".
        If it lands off-centre, move it a little. These choices are remembered on this computer.</div></div>
    <div id="pages"></div></body></html>`);
  d.close();
  const draw = () => { d.getElementById("pcss").textContent = css(o); d.getElementById("pages").innerHTML = pages(o, data); d.getElementById("turnL").style.display = o.mode === "right" ? "" : "none"; };
  for (const k of ["mode", "turn", "dx", "dy"]) {
    const el = d.getElementById(k); el.value = String(o[k]);
    el.addEventListener("input", () => { o[k] = k === "mode" ? el.value : Number(el.value) || 0; save(o); draw(); });
  }
  // Wait for the logo to load so it is on the printed envelope.
  d.getElementById("go").onclick = async () => {
    await Promise.all([...d.images].map((im) => im.complete ? 0 : new Promise((ok) => { im.onload = im.onerror = ok; })));
    w.print();
  };
  draw();
}
