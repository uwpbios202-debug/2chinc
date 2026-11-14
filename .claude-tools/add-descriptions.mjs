import fs from "node:fs";
const base = "C:/Users/mkepr/Documents/lease/site/mirror/";
const D = {
  "how-it-works": "How the Human Mirror works: eight ways of looking at your life, fifteen areas, your Daily Number and a plan you choose, at your own pace.",
  "life-dimensions": "The fifteen areas of life the Human Mirror looks at, from housing and health to work, relationships, purpose and giving back.",
  "daily-number": "Work out your Daily Number: what one day of your life costs, what comes in, and the gap. Free, and nothing you type is saved or sent.",
  "about": "Why 2nd Chance Housing built the Human Mirror: start with the whole person, their strengths and their goals, before any program or paperwork.",
  "privacy": "How the Human Mirror protects your information: what is kept, who can see it, private topics, safety mode, and how to download or delete it.",
  "accessibility": "The Human Mirror works on any phone or computer: speak instead of type, read aloud, larger text, and keyboard and screen reader support.",
  "living-options": "Ways to live and the help that can come with them, from your own place to supportive housing. Information only; you choose.",
  "sign-in": "Sign in to the Human Mirror with a 6-digit code sent to your email. By invitation through a coordinator or Housing Navigator.",
  "forgot-password": "Can't sign in to the Human Mirror? What to do if your code doesn't arrive, you can't get into your email, or someone else is using your account.",
};
for (const [dir, text] of Object.entries(D)) {
  const f = base + dir + "/index.html";
  let s = fs.readFileSync(f, "utf8");
  if (s.includes('name="description"')) { console.log(dir, "already has one"); continue; }
  const eol = s.includes("\r\n") ? "\r\n" : "\n";
  const m = s.match(/<title>[^<]*<\/title>\r?\n/);
  if (!m) { console.log(dir, "NO TITLE"); continue; }
  s = s.replace(m[0], m[0] + `<meta name="description" content="${text}">` + eol);
  fs.writeFileSync(f, s);
  console.log(dir, "ok", text.length);
}
