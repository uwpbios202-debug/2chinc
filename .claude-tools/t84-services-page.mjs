import fs from "node:fs";
const f = "site/mirror/workspace/services/index.html";
let s = fs.readFileSync(f, "utf8");
const rep = (a, b) => { if (!s.includes(a)) { console.error("MISSING: " + a); process.exit(1); } s = s.replace(a, b); };
rep('import { voiceAll } from "/mirror/assets/mirror-voice.js?v=20261113c";',
    'import { voiceAll } from "/mirror/assets/mirror-voice.js?v=20261113c";\nimport { DIMENSIONS } from "/mirror/assets/dimensions.js?v=20261113a";\n\n// the private parts of life (mirror.dimension_category)\nconst PRIVATE = ["physical_health", "mental_health", "identity_legal", "finances", "safety"];\nconst dims = DIMENSIONS.map((d) => ({ key: d.key, title: d.title, private: PRIVATE.includes(d.key) }));');
rep('let dims = [];\n', '');
rep('  try {\n    S = await rpc("mirror_services", { p_org: org });\n    if (S.can_manage && !dims.length) dims = await rpc("mirror_dimensions");\n  } catch', '  try { S = await rpc("mirror_services", { p_org: org }); } catch');
rep('<label class="mm-check"><input type="checkbox" id="eActive"', '<label class="mm-choice"><input type="checkbox" id="eActive"');
fs.writeFileSync(f, s);
console.log("ok");
