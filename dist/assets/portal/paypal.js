// PayPal / Venmo hosted button, shared by the owner page and the resident page.
// A page puts <div id="pp-..." data-pp></div> where the button goes and calls
// renderPayPalButtons(clientId, hostedButtonId). The client id and button id
// are public; PayPal handles the payment. It doesn't post to our ledger on its
// own: the payer still taps "I've paid" and the office or bank match posts it.
let loading;
function load(clientId) {
  if (window.paypal && window.paypal.HostedButtons) return Promise.resolve();
  if (!loading) loading = new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = `https://www.paypal.com/sdk/js?client-id=${encodeURIComponent(clientId)}&components=hosted-buttons&enable-funding=venmo&disable-funding=card,credit,paylater&currency=USD`;
    s.onload = resolve; s.onerror = () => reject(new Error("PayPal didn't load"));
    document.head.appendChild(s);
  });
  return loading;
}

export async function renderPayPalButtons(clientId, hostedId, root = document) {
  const els = Array.from(root.querySelectorAll("[data-pp]:not([data-done])"));
  if (!els.length || !clientId || !hostedId) return;
  els.forEach((el) => { el.dataset.done = "1"; });   // claim now so a second call can't draw them again
  try {
    await load(clientId);
    for (const el of els) {
      el.innerHTML = "";
      await window.paypal.HostedButtons({ hostedButtonId: hostedId }).render("#" + el.id);
    }
  } catch (e) {
    els.forEach((el) => { el.textContent = "PayPal isn't available right now. Use another way to pay."; });
  }
}
