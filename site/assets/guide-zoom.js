// Click a picture in a help guide to see it large; click anywhere or press Esc to close.
(function () {
  var css = document.createElement("style");
  css.textContent = ".guide figure img{cursor:zoom-in}" +
    ".zoomov{position:fixed;inset:0;z-index:10000;background:rgba(0,0,0,.85);display:flex;align-items:center;justify-content:center;padding:12px;cursor:zoom-out}" +
    ".zoomov img{max-width:100%;max-height:100%;border-radius:8px;background:#fff}" +
    ".zoomov span{position:absolute;top:10px;right:16px;color:#fff;font:700 30px/1 Arial,sans-serif}";
  document.head.appendChild(css);
  function close() { var o = document.querySelector(".zoomov"); if (o) o.remove(); }
  document.addEventListener("click", function (e) {
    var img = e.target.closest && e.target.closest(".guide figure img");
    if (!img) { if (e.target.closest && e.target.closest(".zoomov")) close(); return; }
    var o = document.createElement("div");
    o.className = "zoomov";
    o.setAttribute("role", "dialog");
    o.setAttribute("aria-label", "Enlarged picture. Click to close.");
    o.innerHTML = '<span aria-hidden="true">&times;</span>';
    var big = document.createElement("img");
    big.src = img.src; big.alt = img.alt;
    o.appendChild(big);
    document.body.appendChild(o);
  });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") close(); });
})();
