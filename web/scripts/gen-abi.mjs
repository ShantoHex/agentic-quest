// Regenerate typed ABIs in src/lib/ from the Foundry ABI exports in ../abi/.
import { readFileSync, writeFileSync } from "node:fs";
const jobs = [
  ["ProofQuest.json", "proofQuestAbi.ts", "proofQuestAbi"],
  ["RewardDrop.json", "rewardDropAbi.ts", "rewardDropAbi"],
  ["QuestRewards.json", "questRewardsAbi.ts", "questRewardsAbi"],
];
for (const [src, out, name] of jobs) {
  const raw = JSON.parse(readFileSync(new URL(`../../abi/${src}`, import.meta.url)));
  const abi = Array.isArray(raw) ? raw : raw.abi;
  writeFileSync(
    new URL(`../src/lib/${out}`, import.meta.url),
    `// Generated from ../abi/${src} by scripts/gen-abi.mjs — do not edit by hand.\nexport const ${name} = ` +
      JSON.stringify(abi, null, 2) + " as const;\n",
  );
  console.log("wrote", out, abi.length, "entries");
}
