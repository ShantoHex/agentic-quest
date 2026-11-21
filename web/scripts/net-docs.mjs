// Rewrites the network-specific parts of public/agent.json and public/llms.txt from api/_networks.ts
// so the agent docs always match the NETWORK env var used for this build. Runs as `prebuild`.
import { readFileSync, writeFileSync } from "node:fs";
import { pickNetwork } from "../api/_networks.ts";

const n = pickNetwork(process.env.NETWORK);
const deployed = !!n.questRewards;
const main = n.key === "mainnet";

const aj = JSON.parse(readFileSync("public/agent.json", "utf8"));
aj.network = {
  chainId: n.chainId, name: n.name, rpc: n.rpc, explorer: n.explorer,
  agenticWalletCanSend: main,
  note: main
    ? (deployed ? "Live on BSC mainnet. Agentic Wallet (baw) sends with --binanceChainId 56." : "Mainnet contract not deployed yet; GET /api/campaigns returns deployed:false.")
    : "Testnet. Agentic Wallet (baw) sends on mainnet only (binanceChainId 56); on testnet send claim/settle with a testnet wallet.",
  live: "GET /api/campaigns returns network, chainId and contract for this deployment (authoritative).",
};
aj.contracts.QuestRewards = {
  address: n.questRewards || null,
  source: deployed ? `https://repo.sourcify.dev/${n.chainId}/${n.questRewards}` : null,
  abi: "https://agentic-quest.vercel.app/abi/QuestRewards.json",
};
aj.contracts.AgentIdRegistry = {
  address: n.agentIdRegistry,
  note: n.mockRegistry ? "testnet mock; mainnet registry 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F" : "SPACE ID Agent ID registry (official)",
};
writeFileSync("public/agent.json", JSON.stringify(aj, null, 2) + "\n");

let t = readFileSync("public/llms.txt", "utf8");
const netLine = main
  ? `Network of this deployment: BNB Smart Chain mainnet (chainId 56).${deployed ? "" : " Contract not deployed yet."}`
  : `Network of this deployment: BSC testnet (chainId 97). Mainnet (56) launch pending.`;
const cLine = deployed ? `Contract (QuestRewards, verified on Sourcify): ${n.questRewards}` : `Contract: not deployed yet (GET /api/campaigns -> deployed:false).`;
t = t.replace(/^Network of this deployment:.*$/m, netLine).replace(/^Contract(?: \(QuestRewards[^)]*\))?:.*$/m, cLine);
const testNote = "Testnet note: Agentic Wallet only sends transactions on mainnet. On this testnet deployment, sign-in works with an Agentic Wallet,\nbut claim/settle calldata must be sent from a testnet wallet the owner controls.";
const mainNote = "Mainnet: send claim/settle with `baw contract-call preview --binanceChainId 56 ...` then `execute` after owner confirmation.";
t = main ? t.replace(testNote, mainNote) : t.replace(mainNote, testNote);
writeFileSync("public/llms.txt", t);
console.log(`[net-docs] ${n.key} chainId=${n.chainId} questRewards=${n.questRewards || "(not deployed)"}`);
