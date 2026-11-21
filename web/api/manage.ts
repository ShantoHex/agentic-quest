// POST /api/manage {wallet, id, action, postUrl?, amount?} → unsigned tx for a quest CREATOR's own agent.
// actions: pause | resume | setPost (before first claim) | withdraw (unreserved leftover; after end or while paused) | fund (anyone; exact approve + fund)
import { encodeFunctionData, formatUnits, getAddress, isAddress, parseUnits, type Address } from "viem";
import { body, client, creationConfig, DEPLOYED, erc20Abi, parsePostRef, qrAbi, QUEST_REWARDS, readSession, send, txFor } from "./_lib.js";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export default async function handler(req: any, res: any) {
  if (req.method === "OPTIONS") return send(res, 204, {});
  if (req.method !== "POST") return send(res, 200, { ok: true, usage: "POST {wallet, id, action: pause|resume|setPost|withdraw|fund, postUrl?, amount?}. Returns unsigned tx(s) for the creator's own wallet to preview and confirm." });
  if (!DEPLOYED) return send(res, 503, { ok: false, code: "NOT_DEPLOYED", error: "Quests are not live on this network yet." });
  const b = body(req);
  const w = String(b.wallet ?? "");
  if (!isAddress(w)) return send(res, 400, { ok: false, code: "BAD_WALLET", error: "Invalid wallet." });
  const wallet = getAddress(w) as Address;
  const sess = readSession(req.headers?.authorization);
  if (sess && sess.w.toLowerCase() !== wallet.toLowerCase()) return send(res, 403, { ok: false, code: "WALLET_MISMATCH", error: "Signed-in wallet differs from the wallet in the request." });
  let id: bigint;
  try { id = BigInt(String(b.id)); } catch { return send(res, 400, { ok: false, code: "BAD_ID", error: "id must be a quest number." }); }
  const action = String(b.action ?? "");
  try {
    const c = { address: QUEST_REWARDS, abi: qrAbi } as const;
    const count = await client.readContract({ ...c, functionName: "campaignCount" });
    if (id < 1n || id > count) return send(res, 404, { ok: false, code: "UNKNOWN_CAMPAIGN", error: "No such quest." });
    const [k, creator, blocked, paused, cfg] = await Promise.all([
      client.readContract({ ...c, functionName: "getCampaign", args: [id] }),
      client.readContract({ ...c, functionName: "creatorOf", args: [id] }),
      client.readContract({ ...c, functionName: "questBlocked", args: [id] }),
      client.readContract({ ...c, functionName: "paused" }),
      creationConfig(),
    ]);
    const fmt = (v: bigint) => formatUnits(v, cfg.decimals);
    const isCreator = creator.toLowerCase() === wallet.toLowerCase();
    if (action !== "fund" && !isCreator) return send(res, 403, { ok: false, code: "NOT_CREATOR", error: `Only the quest creator (${creator}) can do this.` });
    const tx = (data: `0x${string}`, label: string) => [{ step: 1, ...txFor(wallet, data, label) }];
    if (action === "pause" || action === "resume") {
      return send(res, 200, { ok: true, steps: tx(encodeFunctionData({ abi: qrAbi, functionName: "setCampaignPaused", args: [id, action === "pause"] }), `${action === "pause" ? "Pause" : "Resume"} quest ${id}`) });
    }
    if (action === "setPost") {
      if (k.slotsUsed !== 0) return send(res, 409, { ok: false, code: "ALREADY_STARTED", error: "The X post can only be set before the first claim." });
      const p = parsePostRef(b.postUrl);
      if (!p) return send(res, 400, { ok: false, code: "BAD_POST", error: "postUrl must be a link like https://x.com/you/status/123." });
      return send(res, 200, { ok: true, steps: tx(encodeFunctionData({ abi: qrAbi, functionName: "setTargetPost", args: [id, p] }), `Set quest ${id} X post to ${p}`) });
    }
    if (action === "withdraw") {
      const free = k.balance - k.reserved;
      const ended = k.endTime !== 0n && BigInt(Math.floor(Date.now() / 1000)) > k.endTime;
      if (!(ended || k.paused || blocked || paused)) return send(res, 409, { ok: false, code: "STILL_ACTIVE", error: "Withdraw is allowed after the end time or while the quest is paused. Pause it first (action=pause)." });
      let amt = free;
      if (b.amount !== undefined && b.amount !== "") { try { amt = parseUnits(String(b.amount), cfg.decimals); } catch { return send(res, 400, { ok: false, code: "BAD_AMOUNT", error: "amount must be a number." }); } }
      if (amt <= 0n || amt > free) return send(res, 409, { ok: false, code: "AMOUNT_TOO_HIGH", error: `Withdrawable now: ${fmt(free)} ${cfg.symbol} (reserved for pending claims: ${fmt(k.reserved)}).` });
      return send(res, 200, { ok: true, steps: tx(encodeFunctionData({ abi: qrAbi, functionName: "withdrawCampaignLeftover", args: [id, amt, wallet] }), `Withdraw ${fmt(amt)} ${cfg.symbol} from quest ${id} to your wallet`) });
    }
    if (action === "fund") {
      let amt: bigint;
      try { amt = parseUnits(String(b.amount ?? ""), cfg.decimals); } catch { return send(res, 400, { ok: false, code: "BAD_AMOUNT", error: "amount must be a number." }); }
      if (amt <= 0n) return send(res, 400, { ok: false, code: "BAD_AMOUNT", error: "amount must be > 0." });
      const allowance = await client.readContract({ address: cfg.token, abi: erc20Abi, functionName: "allowance", args: [wallet, QUEST_REWARDS] });
      const steps = [];
      if (allowance < amt) steps.push({ step: 1, ...txFor(wallet, encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [QUEST_REWARDS, amt] }), `Approve exactly ${fmt(amt)} ${cfg.symbol} (not unlimited)`, cfg.token) });
      steps.push({ step: steps.length + 1, ...txFor(wallet, encodeFunctionData({ abi: qrAbi, functionName: "fundCampaign", args: [id, amt] }), `Add ${fmt(amt)} ${cfg.symbol} to quest ${id}${isCreator ? "" : " (funds then belong to the quest; only its creator can withdraw leftovers)"}`) });
      return send(res, 200, { ok: true, steps });
    }
    return send(res, 400, { ok: false, code: "BAD_ACTION", error: "action must be pause, resume, setPost, withdraw or fund." });
  } catch (e) {
    console.error("manage error:", e instanceof Error ? e.message : "unknown");
    return send(res, 502, { ok: false, code: "UPSTREAM", error: "Chain read failed. Try again shortly." });
  }
}
