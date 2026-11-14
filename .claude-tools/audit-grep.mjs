// Prints, per audit file, how many times each topic word appears in its text (read-only; leads only, every fact is re-verified).
import fs from "node:fs";
const dir = "Issues and fixes/Databases_Final/";
const topics = { clothing: /cloth|closet|coat drive|apparel/gi, laundry: /laundr/gi, childcare: /child ?care|wisconsin shares|head start/gi, grief: /grief|bereave/gi,
  substance: /substance|aoda|addiction|recovery|detox|opioid/gi, expunge: /expung|pardon|record/gi, veteran: /veteran/gi, credit: /credit counsel|debt|financial coach/gi,
  furniture: /furniture|mattress|bed\b/gi, caregiver: /caregiver|respite/gi };
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".html"))) {
  const t = fs.readFileSync(dir + f, "utf8").replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, " ").replace(/<[^>]+>/g, " ");
  console.log(f.slice(10, 60), Object.entries(topics).map(([k, re]) => `${k}=${(t.match(re) || []).length}`).join(" "));
}
