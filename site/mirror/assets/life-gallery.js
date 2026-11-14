import { DIMENSIONS } from "/mirror/assets/dimensions.js?v=20261113a";

const catalogURL = new URL("/mirror/assets/scenes/manifest.json", location.origin);
const grid = document.querySelector("#life-grid");
const picker = document.querySelector("#life-person");
const status = document.querySelector("#life-status");
const dialog = document.querySelector("#life-dialog");
const previous = dialog.querySelector("[data-previous]");
const next = dialog.querySelector("[data-next]");
let people = [];
let active = 0;
let opener;

function photo(container, person, dimension, eager = false) {
  container.replaceChildren();
  if (!person) return;
  const scene = person.scenes?.[dimension.key];
  const expectedPath = `images/${person.id}/${dimension.key}.webp`;
  const unavailable = () => {
    const message = document.createElement("span");
    message.textContent = "Scene unavailable";
    container.replaceChildren(message);
  };
  if (scene?.src !== expectedPath) {
    unavailable();
    return;
  }
  const image = document.createElement("img");
  image.alt = scene.alt || `${person.name} · ${dimension.title}`;
  image.loading = eager ? "eager" : "lazy";
  image.decoding = "async";
  image.addEventListener("error", () => {
    if (container.contains(image)) unavailable();
  }, { once: true });
  image.src = new URL(expectedPath, catalogURL).href;
  container.append(image);
}

const selected = () => people.find(person => person.id === picker.value);
const cards = DIMENSIONS.map((dimension, index) => {
  const card = document.createElement("li");
  card.className = "life-card";
  const art = document.createElement("div");
  art.className = "life-art";
  const copy = document.createElement("div");
  copy.className = "life-copy";
  const number = document.createElement("span");
  number.className = "life-number";
  number.textContent = String(dimension.n).padStart(2, "0");
  const heading = document.createElement("h3");
  heading.textContent = dimension.title;
  const description = document.createElement("p");
  description.textContent = dimension.intro;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "mm-btn mm-btn-secondary";
  button.textContent = "Explore";
  button.setAttribute("aria-label", `Explore ${dimension.title}`);
  button.addEventListener("click", () => {
    active = index;
    opener = button;
    showDetail();
    dialog.showModal();
  });
  copy.append(number, heading, description, button);
  card.append(art, copy);
  return { card, art };
});
grid.replaceChildren(...cards.map(({ card }) => card));
document.querySelector("#life-original").hidden = true;
document.querySelector("#life-gallery").hidden = false;

function showDetail() {
  const dimension = DIMENSIONS[active];
  const person = selected();
  dialog.querySelector("#life-detail-title").textContent = dimension.title;
  dialog.querySelector("#life-detail-copy").textContent = dimension.intro;
  dialog.querySelector("#life-detail-person").textContent = person
    ? `${person.name} · Age ${person.age}${dimension.key === "work" ? ` · ${person.role}` : ""}`
    : "";
  dialog.querySelector("#life-detail-position").textContent = `${active + 1} of ${DIMENSIONS.length}`;
  photo(dialog.querySelector(".life-art"), person, dimension, true);
  previous.disabled = active === 0;
  next.disabled = active === DIMENSIONS.length - 1;
}
previous.addEventListener("click", () => { if (active > 0) { active--; showDetail(); if (previous.disabled) next.focus(); } });
next.addEventListener("click", () => { if (active < DIMENSIONS.length - 1) { active++; showDetail(); if (next.disabled) previous.focus(); } });
dialog.addEventListener("close", () => opener?.focus());

function showPerson() {
  const person = selected();
  cards.forEach(({ art }, index) => photo(art, person, DIMENSIONS[index], index < 3));
  status.textContent = `${person.name} · Age ${person.age} · ${person.role} · ${DIMENSIONS.length} life dimensions`;
}
picker.addEventListener("change", showPerson);

try {
  const response = await fetch(catalogURL);
  if (!response.ok) throw new Error("Catalog unavailable");
  const catalog = await response.json();
  if (!Array.isArray(catalog.people)) throw new Error("Invalid catalog");
  people = catalog.people.filter(person => typeof person?.id === "string" && /^[a-z0-9-]+$/.test(person.id) &&
    typeof person.name === "string" && Number.isFinite(person.age) && typeof person.role === "string");
  if (!people.length) throw new Error("Empty catalog");
  picker.replaceChildren(...people.map(person => new Option(`${person.name} · ${person.age} · ${person.role}`, person.id)));
  if (people.some(person => person.id === "maya")) picker.value = "maya";
  picker.disabled = false;
  showPerson();
} catch {
  status.textContent = "The scene gallery is unavailable right now. You can still explore all fifteen areas.";
}
