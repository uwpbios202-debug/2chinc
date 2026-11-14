import { scenes } from "./scenes.js?v=3";
import { people } from "./people.js?v=3";

export function mountMirror(root, demo = false) {
  const asset = new URL(".", import.meta.url);
  const find = (selector) => root.querySelector(selector);
  const photo = find("#ip-photo");
  const picker = find("#ip-file");
  const remove = find("#ip-remove");
  const position = find("#ip-position");
  const zoom = find("#ip-zoom");
  const placeholder = find("#ip-placeholder");
  const status = find("#ip-status");
  let activeURL = "";
  let pendingURL = "";
  let selection = 0;
  const personPicker = find("#ip-person");
  const scenePhoto = find("#ip-scene-photo");
  for (const [key, name, age, role] of people) personPicker.add(new Option(name + ", " + age + " — " + role, key));

  function currentScene() {
    return scenes.find((scene) => scene.key === find("[name=ip-scene]:checked").value);
  }

  function selectScene(scene) {
    const art = find("#ip-art");
    const person = activeURL ? null : people.find(([key]) => key === personPicker.value);
    const name = person?.[1];
    const file = person ? "people/" + person[0] + "-" + scene.key + ".webp" : scene.key + ".webp";
    art.src = new URL(file, asset);
    art.alt = name ? (scene.key === "trade" ? name + " at work as a " + person[3].toLowerCase() + "." : name + " in the “" + scene.title + "” scene.") : scene.setting;
    art.classList.toggle("ip-art-person", Boolean(person));
    find("#ip-image-description").textContent = activeURL ? "Your photo in this possibility collage. Remove it to choose a sample person." : name ? "Fictional example featuring " + name + (scene.key === "trade" ? " — " + person[3] : "") : "";
    find("#ip-title").textContent = scene.title;
    find("#ip-step").textContent = scene.step;
    find("#ip-goal").href = "/mirror/my-mirror/plan/?possibility=" + scene.key + "#gt-new";
    if (demo) {
      find("#ip-goal").href = "#ip-demo-note";
      find("#ip-demo-note").textContent = "In My Mirror, this opens the existing My Plan form with “" + scene.title + "” filled in for you to edit and save.";
    }
  }
  for (const field of root.querySelectorAll("[name=ip-scene]")) {
    field.addEventListener("change", () => selectScene(scenes.find((scene) => scene.key === field.value)));
  }
  personPicker.value = "maya";
  personPicker.addEventListener("change", () => selectScene(currentScene()));
  selectScene(currentScene());

  function resetCrop() {
    position.value = "42";
    zoom.value = "100";
    updateCrop();
  }
  function updateCrop() {
    for (const image of [photo, scenePhoto]) {
      image.style.objectPosition = "50% " + position.value + "%";
      image.style.transformOrigin = "50% " + position.value + "%";
      image.style.transform = "scale(" + Number(zoom.value) / 100 + ")";
    }
  }
  position.addEventListener("input", updateCrop);
  zoom.addEventListener("input", updateCrop);

  function cancelPending() {
    selection++;
    if (pendingURL) URL.revokeObjectURL(pendingURL);
    pendingURL = "";
  }
  function clearPhoto() {
    cancelPending();
    if (activeURL) URL.revokeObjectURL(activeURL);
    activeURL = "";
    picker.value = "";
    photo.removeAttribute("src");
    scenePhoto.removeAttribute("src");
    find("#ip-inset").hidden = true;
    personPicker.disabled = false;
    photo.hidden = true;
    placeholder.hidden = false;
    remove.hidden = true;
    find("#ip-crop").hidden = true;
    resetCrop();
  }

  picker.addEventListener("change", async () => {
    const file = picker.files[0];
    picker.value = "";
    if (!file) return;
    cancelPending();
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 20 * 1024 * 1024) {
      status.textContent = "Choose a JPG, PNG, or WebP photo up to 20 MB.";
      return;
    }
    const current = selection;
    const url = URL.createObjectURL(file);
    pendingURL = url;
    const candidate = new Image();
    candidate.src = url;
    status.textContent = "Opening your photo…";
    try {
      await candidate.decode();
      if (current !== selection) return;
      if (activeURL) URL.revokeObjectURL(activeURL);
      activeURL = url;
      pendingURL = "";
      resetCrop();
      photo.src = url;
      scenePhoto.src = url;
      find("#ip-inset").hidden = false;
      personPicker.disabled = true;
      selectScene(currentScene());
      photo.hidden = false;
      placeholder.hidden = true;
      remove.hidden = false;
      find("#ip-crop").hidden = false;
      status.textContent = "Your photo is in the mirror. Use the position and zoom controls to adjust it.";
    } catch {
      if (current !== selection) return;
      cancelPending();
      status.textContent = "This photo couldn’t be opened. Try a different JPG, PNG, or WebP.";
    }
  });
  remove.addEventListener("click", () => {
    clearPhoto();
    selectScene(currentScene());
    status.textContent = "Photo removed.";
    picker.focus();
  });
  window.addEventListener("pageshow", (event) => {
    if (event.persisted) selectScene(currentScene());
  });
  window.addEventListener("pagehide", () => {
    clearPhoto();
    status.textContent = "";
  });
}
