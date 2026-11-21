// /api/publish — anyone (Agent ID holder by default) publishes their own quest.
// GET  → live creation rules + request format.
// POST {wallet, title, mode:"FCFS"|"RANDOM", rewardPerClaim? (FCFS), tiers? (RANDOM: [{amount, chancePct}]),
//       maxClaims, budget, postUrl? (optional, can be set later), endTime?|durationDays?}
//      → the exact unsigned transactions for the creator's own agent to preview and the creator to confirm:
//        1) approve EXACTLY `budget` of the reward token (never unlimited), 2) createQuest (creates + funds in one tx).
// The server never signs or sends anything for the creator.
import { encodeFunctionData, formatUnits, getAddress, isAddress, parseUnits, type Address } from "viem";
import { agentIdOf, body, CHAIN_ID, client, creationConfig, DEPLOYED, erc20Abi, NET, parsePostRef, qrAbi, QUEST_REWARDS, readSession, send, txFor } from "./_lib.js";

const MAX_CLAIMS = 1_000_000;
const MAX_TIERS = 5;
const DEFAULT_CHANCES = [30, 50, 20];

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export default async function handler(req: any, res: any) {
  if (req.method === "OPTIONS") return send(res, 204, {});
  if (!DEPLOYED) return send(res, 503, { ok: false, code: "NOT_DEPLOYED", error: "Quests are not live on this network yet." });
  let cfg;
  try { cfg = await creationConfig(); } catch { return send(res, 502, { ok: false, code: "UPSTREAM", error: "Chain read failed. Try again shortly." }); }
  const fmt = (v: bigint) => formatUnits(v, cfg.decimals);
  const rules = {
    network: NET.key, chainId: CHAIN_ID, contract: QUEST_REWARDS, token: cfg.token, tokenSymbol: cfg.symbol, decimals: cfg.decimals,
    creationOpen: cfg.open, creatorNeedsAgentId: cfg.needsAgentId, minBudget: fmt(cfg.minBudget), maxBudget: "none",
    minRewardPerClaim: fmt(cfg.minReward), maxRewardPerClaim: "none",
    randomTiers: `1-${MAX_TIERS} tiers set by the creator: each amount >= ${fmt(cfg.minReward)} (no max), whole-percent chances >= 1 that sum to 100 (default 3 tiers: ${DEFAULT_CHANCES.join("% / ")}%). The largest tier is reserved per pending claim, so the budget must cover it.`,
    budgetRule: "budget >= minBudget AND budget >= one claim (FCFS reward, or the largest RANDOM tier)",
    platformFee: "0",
    creatorCan: ["pause/resume own quest", "publish without an X post and set it later (before the first claim)", "withdraw own unreserved leftover after the end or while paused"],
    creatorCannot: ["touch other quests", "withdraw funds reserved for pending claims", "claim their own quest"],
  };
  if (req.method === "GET") {
    return send(res, 200, {
      ok: true, rules,
      request: { method: "POST", url: "/api/publish", body: { wallet: "0x…", title: "Quote our launch post", mode: "FCFS", rewardPerClaim: "0.10", maxClaims: 10, budget: "1", durationDays: 7 } },
      randomExample: { wallet: "0x…", title: "Lucky draw", mode: "RANDOM", tiers: [{ amount: "0.05", chancePct: 30 }, { amount: "0.10", chancePct: 50 }, { amount: "0.50", chancePct: 20 }], maxClaims: 10, budget: "2", durationDays: 7 },
      optional: { postUrl: "https://x.com/you/status/123 (or set later via POST /api/manage action=setPost)" },
    });
  }
  if (req.method !== "POST") return send(res, 405, { ok: false, error: "Use GET or POST." });

  const b = body(req);
  const bad = (code: string, error: string) => send(res, 400, { ok: false, code, error, rules });
  const w = String(b.wallet ?? "");
  if (!isAddress(w)) return bad("BAD_WALLET", "Pass your own wallet address.");
  const wallet = getAddress(w) as Address;
  const sess = readSession(req.headers?.authorization);
  if (sess && sess.w.toLowerCase() !== wallet.toLowerCase()) return send(res, 403, { ok: false, code: "WALLET_MISMATCH", error: "Signed-in wallet differs from the wallet in the request." });

  const title = String(b.title ?? "").trim();
  if (!title || Buffer.byteLength(title) > 120) return bad("BAD_TITLE", "Title is required, max 120 bytes.");
  if (/\b(binance|bnb)\b/i.test(title) && /\b(official|airdrop)\b/i.test(title)) return bad("BAD_TITLE", "Don't present a quest as an official Binance/BNB airdrop.");
  const mode = String(b.mode ?? "").toUpperCase();
  if (mode !== "FCFS" && mode !== "RANDOM") return bad("BAD_MODE", "mode must be FCFS or RANDOM.");
  const maxClaims = Number(b.maxClaims);
  if (!Number.isInteger(maxClaims) || maxClaims < 1 || maxClaims > MAX_CLAIMS) return bad("BAD_SLOTS", `maxClaims must be 1..${MAX_CLAIMS}.`);
  let budget: bigint, reward = 0n;
  const tierAmounts: bigint[] = [];
  const tierChances: number[] = [];
  const amt = (v: unknown) => { const t = String(v ?? "").trim(); if (!/^\d+(\.\d+)?$/.test(t)) throw new Error("nan"); return parseUnits(t, cfg.decimals); };
  try { budget = amt(b.budget); } catch { return bad("BAD_BUDGET", "budget must be a number of tokens, e.g. \"1\" (no maximum)."); }
  if (budget < cfg.minBudget) return bad("BUDGET_TOO_LOW", `Minimum budget is ${fmt(cfg.minBudget)} ${cfg.symbol}.`);
  if (mode === "FCFS") {
    try { reward = amt(b.rewardPerClaim); } catch { return bad("BAD_REWARD", "rewardPerClaim must be a number, e.g. \"0.10\"."); }
    if (reward < cfg.minReward) return bad("REWARD_TOO_LOW", `Reward per claim must be at least ${fmt(cfg.minReward)} ${cfg.symbol} (no maximum).`);
  } else {
    const raw = Array.isArray(b.tiers) ? b.tiers : null;
    if (!raw || raw.length < 1 || raw.length > MAX_TIERS) return bad("BAD_TIERS", `RANDOM needs tiers: 1-${MAX_TIERS} items like {"amount":"0.05","chancePct":30}; default chances ${DEFAULT_CHANCES.join("/")}.`);
    for (const [i, t] of raw.entries()) {
      let a: bigint;
      try { a = amt(t?.amount); } catch { return bad("BAD_TIERS", `Tier ${i + 1}: amount must be a number, e.g. "0.10".`); }
      if (a < cfg.minReward) return bad("REWARD_TOO_LOW", `Tier ${i + 1}: each reward must be at least ${fmt(cfg.minReward)} ${cfg.symbol} (no maximum).`);
      const ch = Number(t?.chancePct ?? (raw.length === DEFAULT_CHANCES.length ? DEFAULT_CHANCES[i] : NaN));
      if (!Number.isInteger(ch) || ch < 1 || ch > 100) return bad("BAD_TIERS", `Tier ${i + 1}: chancePct must be a whole number 1-100.`);
      tierAmounts.push(a); tierChances.push(ch);
    }
    const sum = tierChances.reduce((x, y) => x + y, 0);
    if (sum !== 100) return bad("BAD_TIERS", `Tier chances must add up to 100% (now ${sum}%).`);
  }
  const unit = mode === "FCFS" ? reward : tierAmounts.reduce((m, x) => (x > m ? x : m), 0n);
  if (budget < unit) return bad("BUDGET_TOO_LOW", `Budget must cover at least one claim (${fmt(unit)} ${cfg.symbol}${mode === "RANDOM" ? ", the largest tier" : ""}).`);
  let postId = "";
  if (b.postUrl !== undefined && b.postUrl !== null && b.postUrl !== "") {
    const p = parsePostRef(b.postUrl);
    if (!p) return bad("BAD_POST", "postUrl must be a link like https://x.com/you/status/123 (or leave it out and set it later, before the first claim).");
    postId = p;
  }
  const now = Math.floor(Date.now() / 1000);
  let endTime = 0;
  if (b.endTime !== undefined && b.endTime !== null && b.endTime !== "") {
    endTime = /^\d+$/.test(String(b.endTime)) ? Number(b.endTime) : Math.floor(Date.parse(String(b.endTime)) / 1000);
  } else if (b.durationDays !== undefined) {
    const d = Number(b.durationDays);
    if (!(d > 0 && d <= 365)) return bad("BAD_END", "durationDays must be 1..365.");
    endTime = now + Math.round(d * 86400);
  }
  if (endTime !== 0 && (!Number.isFinite(endTime) || endTime <= now + 60)) return bad("BAD_END", "endTime must be in the future (unix seconds or ISO date).");

  try {
    const isOwner = wallet.toLowerCase() === cfg.owner.toLowerCase();
    const handle = await agentIdOf(wallet);
    if (!isOwner && !cfg.open) return send(res, 403, { ok: false, code: "CREATION_CLOSED", error: "Quest creation is currently closed." });
    if (!isOwner && cfg.needsAgentId && !handle) return send(res, 403, { ok: false, code: "NO_AGENT_ID", error: "Only Agent ID holders can publish quests. Claim your Agent ID in the Binance App first." });
    const [bal, allowance] = await Promise.all([
      client.readContract({ address: cfg.token, abi: erc20Abi, functionName: "balanceOf", args: [wallet] }),
      client.readContract({ address: cfg.token, abi: erc20Abi, functionName: "allowance", args: [wallet, QUEST_REWARDS] }),
    ]);
    const slotsByBudget = budget / unit;
    const steps = [];
    if (allowance < budget) {
      steps.push({ step: steps.length + 1, ...txFor(wallet, encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [QUEST_REWARDS, budget] }), `Approve exactly ${fmt(budget)} ${cfg.symbol} for Agentic Quest (not unlimited)`, cfg.token) });
    }
    steps.push({ step: steps.length + 1, ...txFor(wallet, encodeFunctionData({ abi: qrAbi, functionName: "createQuest", args: [mode === "FCFS" ? 1 : 0, reward, tierAmounts, tierChances, maxClaims, BigInt(endTime), postId, title, budget] }), `Publish "${title}" and fund it with ${fmt(budget)} ${cfg.symbol}`) });
    const warnings: string[] = [];
    if (bal < budget) warnings.push(`Wallet holds ${fmt(bal)} ${cfg.symbol}; it needs ${fmt(budget)} ${cfg.symbol} before createQuest.`);
    if (slotsByBudget < BigInt(maxClaims)) warnings.push(`Budget covers ${slotsByBudget} of ${maxClaims} claims. Top up later with fundCampaign, or lower maxClaims.`);
    if (!postId) warnings.push("No X post set yet: claims stay closed until you set it (POST /api/manage action=setPost).");
    if (endTime === 0) warnings.push("No end time: to withdraw leftovers later you must pause the quest first.");
    return send(res, 200, {
      ok: true, wallet, creatorAgentId: handle ? `${handle}.ai` : null,
      quest: { title, mode, rewardPerClaim: mode === "FCFS" ? fmt(reward) : "random", tiers: mode === "RANDOM" ? tierAmounts.map((a, i) => ({ amount: fmt(a), chancePct: tierChances[i] })) : undefined, reservedPerClaim: fmt(unit), maxClaims, budget: fmt(budget), slotsCoveredByBudget: slotsByBudget.toString(), targetPostId: postId || null, endTime: endTime || null },
      steps, warnings, rules,
      rule: "Preview each step with your own Agentic Wallet, show the creator the parsed transaction, and execute only after explicit confirmation. Send the steps in order.",
      next: `After step ${steps.length} is mined: GET /api/campaigns?creator=${wallet}`,
    });
  } catch (e) {
    console.error("publish error:", e instanceof Error ? e.message : "unknown");
    return send(res, 502, { ok: false, code: "UPSTREAM", error: "Chain read failed. Try again shortly." });
  }
}
