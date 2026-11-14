// Proof of mailing: pick a photo or PDF of the green certified-mail receipt, turn it upright, save it as a JPEG in notices/proof/<id>.jpg.
// Shared by /documents/notices/ and /staff/efile/ (Process screen). New file: browsers cache portal.js for hours.
const PDFJS = "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js";
async function loadPdfJs() {
  if (!window.pdfjsLib) await new Promise((ok, bad) => { const s = document.createElement("script"); s.src = PDFJS; s.onload = ok; s.onerror = () => bad(new Error("Couldn't load the PDF reader.")); document.head.appendChild(s); });
  window.pdfjsLib.GlobalWorkerOptions.workerSrc = PDFJS.replace("pdf.min.js", "pdf.worker.min.js");
  return window.pdfjsLib;
}
async function fileToCanvas(file) {
  const c = document.createElement("canvas");
  if (file.type === "application/pdf" || /\.pdf$/i.test(file.name)) {
    const lib = await loadPdfJs();
    const pdf = await lib.getDocument({ data: await file.arrayBuffer() }).promise, page = await pdf.getPage(1);
    const v1 = page.getViewport({ scale: 1 }), vp = page.getViewport({ scale: Math.min(3, 2000 / Math.max(v1.width, v1.height)) });
    c.width = vp.width; c.height = vp.height;
    await page.render({ canvasContext: c.getContext("2d"), viewport: vp }).promise;
    return c;
  }
  const bmp = await createImageBitmap(file, { imageOrientation: "from-image" });
  const k = Math.min(1, 2000 / Math.max(bmp.width, bmp.height));
  c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
  c.getContext("2d").drawImage(bmp, 0, 0, c.width, c.height);
  return c;
}
function rotated(src) {
  const c = document.createElement("canvas"); c.width = src.height; c.height = src.width;
  const g = c.getContext("2d"); g.translate(c.width, 0); g.rotate(Math.PI / 2); g.drawImage(src, 0, 0);
  return c;
}
// inp: the <input type=file>; msg: an element for short messages; onDone: called after the receipt is saved.
export async function pickProof(client, id, msg, inp, errorText, onDone) {
  const f = inp.files && inp.files[0]; inp.value = ""; if (!f) return;
  msg.className = "msg"; msg.textContent = "Reading…";
  let cv;
  try { cv = await fileToCanvas(f); } catch (e) { msg.className = "msg err"; msg.textContent = e.message || "Couldn't read that file."; return; }
  msg.textContent = "";
  const o = document.createElement("div");
  o.style.cssText = "position:fixed;inset:0;background:rgba(0,0,0,.8);z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;padding:16px";
  o.innerHTML = `<div style="color:#fff;font-weight:700">Turn it so the writing reads normally, then Save.</div>
    <img style="max-width:90vw;max-height:70vh;background:#fff;border-radius:6px">
    <div style="display:flex;gap:8px"><button class="btn" type="button" data-rot>↻ Rotate</button><button class="btn" type="button" data-save>Save receipt</button><button class="btn" type="button" data-cancel>Cancel</button></div>
    <div class="msg" style="color:#fff" data-om></div>`;
  const img = o.querySelector("img"), show = () => { img.src = cv.toDataURL("image/jpeg", 0.8); };
  show(); document.body.appendChild(o);
  o.querySelector("[data-rot]").onclick = () => { cv = rotated(cv); show(); };
  o.querySelector("[data-cancel]").onclick = () => o.remove();
  o.querySelector("[data-save]").onclick = async (ev) => {
    ev.target.disabled = true; const om = o.querySelector("[data-om]"); om.textContent = "Saving…";
    try {
      const blob = await new Promise((ok) => cv.toBlob(ok, "image/jpeg", 0.85));
      const path = `proof/${id}.jpg`;
      const { error: ue } = await client.storage.from("notices").upload(path, blob, { contentType: "image/jpeg", upsert: true });
      if (ue) throw new Error(ue.message);
      const { error: re } = await client.rpc("notice_attach_proof", { p_id: id, p_path: path });
      if (re) throw new Error(errorText ? await errorText(re) : re.message);
      o.remove(); if (onDone) await onDone();
    } catch (e) { om.textContent = e.message || "Couldn't save."; ev.target.disabled = false; }
  };
}
