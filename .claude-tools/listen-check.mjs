// Runs the Mirror phrase matcher on sample text (local check only).
import { analyse, urgentIn } from "../site/mirror/assets/mirror-listen.js";
const ex = {
  home: "Right now me and my two kids are staying at my sister's place on the north side. She's been good to us but she said we got to be out by the end of the month because her landlord is complaining.",
  hardest: "Honestly I don't know where to start. My hours got cut at the warehouse in September and I fell behind on rent at my old place, so I got a 5 day notice and we left before it went to court.",
  money: "I work part time, about 25 hours, so maybe $1,300 a month. I get food share for the kids. I still owe WE Energies about $600 and they sent a disconnection notice to my old address.",
  people: "My son is 7 and my daughter is 3. My sister helps when she can. My mom passed last year.",
  day: "I'm tired all the time and stressed. My daughter has asthma and I need to keep up with her medication. My car broke down so I take the bus to work.",
  past: "The eviction filing might show up even though we left. My credit is bad from the utility bills. I lost my wallet so I don't have a state ID right now.",
  future: "A place of our own, even a small two bedroom, where the kids can stay at the same school. And I want to get back to full time.",
};
for (const f of analyse(ex)) console.log(f.kind.padEnd(6), f.private ? "PRIV" : "    ", f.label, "|", f.quotes[0].words.slice(0, 70));
console.log("--neg:", analyse({ home: "I'm not behind on rent and I have never been evicted." }).map((f) => f.key));
console.log("--urgent:", urgentIn("I have nowhere to sleep tonight"), urgentIn("he hit me last week"), urgentIn("sometimes I don't want to be here anymore"));
