// Read-only sanity check against the configured RPC. Sends no transactions.
import { createPublicClient, http, getAddress } from "viem";
import { readFileSync } from "node:fs";

const env = Object.fromEntries(
  readFileSync(new URL("../.env.example", import.meta.url), "utf8")
    .split("\n").filter((l) => /^VITE_\w+=/.test(l)).map((l) => l.split(/=(.*)/s).slice(0, 2)),
);
const rpc = process.env.VITE_RPC_URL || env.VITE_RPC_URL;
const PQ = getAddress(process.env.VITE_PROOFQUEST_ADDRESS || env.VITE_PROOFQUEST_ADDRESS);
const REG = getAddress(process.env.VITE_AGENT_ID_REGISTRY || env.VITE_AGENT_ID_REGISTRY);
const raw = JSON.parse(readFileSync(new URL("../../abi/ProofQuest.json", import.meta.url)));
const abi = Array.isArray(raw) ? raw : raw.abi;
const reg = [
  { type: "function", name: "handleOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "string" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
];
const c = createPublicClient({ transport: http(rpc) });
const r = (functionName, args = []) => c.readContract({ address: PQ, abi, functionName, args });

console.log("chainId", await c.getChainId(), "block", await c.getBlockNumber());
console.log("bytecode present", ((await c.getCode({ address: PQ })) ?? "0x").length > 2);
const owner = await r("owner");
console.log("owner", owner, "pendingOwner", await r("pendingOwner"));
console.log("agentId()", await r("agentId"), "matches config:", (await r("agentId")).toLowerCase() === REG.toLowerCase());
const n = await r("questCount");
console.log("questCount", n, "MAX_WINNERS_CAP", await r("MAX_WINNERS_CAP"));
console.log("isPrizeToken(0x0)", await r("isPrizeToken", ["0x0000000000000000000000000000000000000000"]));
console.log("hasAgentId(owner)", await r("hasAgentId", [owner]));
console.log("registry handleOf(owner)", JSON.stringify(await c.readContract({ address: REG, abi: reg, functionName: "handleOf", args: [owner] })),
  "balanceOf", await c.readContract({ address: REG, abi: reg, functionName: "balanceOf", args: [owner] }));
for (let i = 1n; i <= n && i <= 5n; i++) console.log("quest", i, await r("getQuest", [i]), await r("questWinners", [i]));

// RewardDrop (optional)
const RD = process.env.VITE_REWARD_DROP_ADDRESS || env.VITE_REWARD_DROP_ADDRESS;
if (RD) {
  const rraw = JSON.parse(readFileSync(new URL("../../abi/RewardDrop.json", import.meta.url)));
  const rabi = Array.isArray(rraw) ? rraw : rraw.abi;
  const rr = (functionName, args = []) => c.readContract({ address: getAddress(RD), abi: rabi, functionName, args });
  console.log("RewardDrop", RD, "token", await rr("token"), "decimals", await rr("tokenDecimals"), "paused", await rr("paused"));
  console.log("tiers", await rr("tiers"));
  console.log("availablePool", await rr("availablePool"), "totalPaid", await rr("totalPaid"), "claimCount", await rr("claimCount"), "totalReserved", await rr("totalReserved"));
  console.log("canClaim(owner)", await rr("canClaim", [owner]), "pendingClaim(owner)", await rr("pendingClaim", [owner]));
}
