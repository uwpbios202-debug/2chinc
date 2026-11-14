// @ts-check
// The Human Mirror T3.4: one reflection page. Each /mirror/my-mirror/<page>/ is a few lines of HTML with
// <body data-area="my" data-reflection="identity"> and loads this file.

import { requireArea, rpc } from "/mirror/assets/mirror-client.js?v=20261113p";
import { esc, notice } from "/mirror/assets/mirror-ui.js?v=20261113h";
import { runSet } from "/mirror/assets/assessment-engine.js?v=20261113p";

/** Page address of each reflection (the prompt's route names) and the order we SUGGEST (never forced: Mirror 2). */
export const PAGES = { identity: "today", history: "history", vision: "vision", assets: "strengths", needs: "needs",
  function: "abilities", preferences: "preferences", contribution: "contribution" };
export const SUGGESTED_ORDER = ["identity", "assets", "vision", "history", "needs", "preferences", "function", "contribution"];

/** The reflection to suggest next: one already started first, then the first untouched one in the suggested order. @param {any[]} sets */
export function suggestNext(sets, except = "") {
  const by = Object.fromEntries(sets.map((s) => [s.reflection, s]));
  const order = SUGGESTED_ORDER.filter((k) => k !== except && by[k] && by[k].questions > 0);
  return order.find((k) => by[k].answered > 0 && by[k].answered < by[k].questions)
    || order.find((k) => by[k].answered === 0) || null;
}

export async function reflectionPage() {
  const key = document.body.dataset.reflection || "";
  await requireArea("my");
  const head = /** @type {HTMLElement} */ (document.getElementById("mmHead"));
  const box = /** @type {HTMLElement} */ (document.getElementById("mmSet"));
  let sets;
  try { sets = await rpc("mirror_sets", { p_kind: "reflection" }); }
  catch (e) { box.innerHTML = notice("urgent", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); return; }
  const s = sets.find((/** @type {any} */ x) => x.reflection === key);
  if (!s) { box.innerHTML = notice("info", "<p>This reflection isn't available.</p>"); return; }

  head.innerHTML = `<p class="mm-eyebrow">Reflection ${["identity", "history", "vision", "assets", "needs", "function", "preferences", "contribution"].indexOf(key) + 1} of 8</p>
    <h1>${esc(s.title)}</h1><p class="mm-lead">${esc(s.intro || "")}</p>`;
  document.title = s.title + " | The Human Mirror";
  const nxt = suggestNext(sets, key);
  const nextSet = nxt ? sets.find((/** @type {any} */ x) => x.reflection === nxt) : null;
  runSet(box, s.key, { nextLink: nextSet ? { href: `/mirror/my-mirror/${PAGES[nxt]}/`, label: `Next: ${nextSet.title}` } : null });

}

// ---------------------------------------------------------------- T3.5: the 15 life areas (/mirror/my-mirror/life/<area>/)
/** Address of a life area page: the dimension key with dashes. @param {string} key */
export const lifeHref = (key) => `/mirror/my-mirror/life/${key.replace(/_/g, "-")}/`;

/** One life-area page: <body data-area="my" data-dimension="housing">. */
export async function lifeAreaPage() {
  const key = document.body.dataset.dimension || "";
  await requireArea("my");
  const head = /** @type {HTMLElement} */ (document.getElementById("mmHead"));
  const box = /** @type {HTMLElement} */ (document.getElementById("mmSet"));
  let sets;
  try { sets = await rpc("mirror_sets", { p_kind: "dimension" }); }
  catch (e) { box.innerHTML = notice("urgent", `<p>${esc(e instanceof Error ? e.message : String(e))}</p>`); return; }
  const s = sets.find((/** @type {any} */ x) => x.dimension === key);
  if (!s) { box.innerHTML = notice("info", "<p>This part of life isn't available.</p>"); return; }
  head.innerHTML = `<p class="mm-eyebrow"><a href="/mirror/my-mirror/life/">Areas of life</a></p>
    <h1>${esc(s.title)}</h1><p class="mm-lead">${esc(s.intro || "")}</p>`;
  document.title = s.title + " | The Human Mirror";
  // Next: the next area not yet started, in the usual order of the 15.
  const nxt = sets.find((/** @type {any} */ x) => x.dimension !== key && x.answered === 0);
  runSet(box, s.key, { nextLink: nxt ? { href: lifeHref(nxt.dimension), label: `Next: ${nxt.title}` } : { href: "/mirror/my-mirror/life/", label: "All areas of life" } });
}
