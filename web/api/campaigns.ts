// GET /api/campaigns[?wallet=0x…][&id=N]  → reward campaigns (RANDOM / FCFS) and, for a wallet, its status
// plus the next unsigned transaction (e.g. settle) for the wallet owner's agent to preview and confirm.
import { getAddress, isAddress, keccak256, toBytes, type Address } from "viem";
import { agentIdOf, CHAIN_ID, DEPLOYED, HIDDEN, NET, client, encodeSettle, qrAbi, QUEST_REWARDS, readSession, send, txFor } from "./_lib.js";

const MODES = ["RANDOM", "FCFS"] as const;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export default async function handler(req: any, res: any) {
  if (req.method === "OPTIONS") return send(res, 204, {});
  const sess = readSession(req.headers?.authorization);
  const w = String(req.query?.wallet ?? sess?.w ?? "");
  const wallet = isAddress(w) ? (getAddress(w) as Address) : null;
  const only = req.query?.id ? BigInt(String(req.query.id)) : null;
  const cq = String(req.query?.creator ?? "");
  const creatorFilter = isAddress(cq) ? cq.toLowerCase() : null;
  const showHidden = req.query?.all === "1" || !!only;
  if (!DEPLOYED) return send(res, 200, { ok: true, deployed: false, network: NET.key, chainId: CHAIN_ID, contract: null, campaigns: [] });
  try {
    const c = { address: QUEST_REWARDS, abi: qrAbi } as const;
    const [count, signer, paused, token, tiers, block] = await Promise.all([
      client.readContract({ ...c, functionName: "campaignCount" }),
      client.readContract({ ...c, functionName: "signer" }),
      client.readContract({ ...c, functionName: "paused" }),
      client.readContract({ ...c, functionName: "token" }),
      client.readContract({ ...c, functionName: "tiers" }),
      client.getBlockNumber(),
    ]);
    const handle = wallet ? await agentIdOf(wallet) : "";
    const ids: bigint[] = [];
    for (let i = count; i >= 1n; i--) if ((!only || only === i) && (showHidden || !HIDDEN.has(i.toString()))) ids.push(i);
    const all = await Promise.all(ids.map(async (id) => {
      const [k, remaining, creator, blocked] = await Promise.all([
        client.readContract({ ...c, functionName: "getCampaign", args: [id] }),
        client.readContract({ ...c, functionName: "remainingSlots", args: [id] }),
        client.readContract({ ...c, functionName: "creatorOf", args: [id] }),
        client.readContract({ ...c, functionName: "questBlocked", args: [id] }),
      ]);
      if (creatorFilter && creator.toLowerCase() !== creatorFilter) return null;
      const out: Record<string, unknown> = {
        id: id.toString(),
        title: k.title,
        creator,
        blocked,
        hidden: HIDDEN.has(id.toString()) || undefined,
        mode: MODES[k.mode],
        reward: k.mode === 1
          ? { type: "fixed", amount: k.fcfsAmount.toString() }
          : { type: "random", tiers: tiers[0].map((a, i) => ({ amount: a.toString(), oddsPct: tiers[1][i] })) },
        maxClaims: k.maxClaims, slotsUsed: k.slotsUsed, settled: k.settled,
        remainingSlots: remaining.toString(),
        endTime: Number(k.endTime) || null,
        paused: k.paused || paused || blocked,
        budget: { balance: k.balance.toString(), reserved: k.reserved.toString(), totalPaid: k.totalPaid.toString() },
        targetPostId: k.targetPostId || null,
        targetPostUrl: k.targetPostId ? `https://x.com/i/status/${k.targetPostId}` : null,
      };
      if (wallet) {
        const [can, pend, claimed] = await Promise.all([
          client.readContract({ ...c, functionName: "canClaim", args: [id, wallet] }),
          client.readContract({ ...c, functionName: "pendingClaim", args: [id, wallet] }),
          client.readContract({ ...c, functionName: "addressClaimed", args: [id, wallet] }),
        ]);
        let reward: string | null = null;
        if (claimed && handle) reward = (await client.readContract({ ...c, functionName: "rewardOfHandle", args: [id, keccak256(toBytes(handle))] })).toString();
        const st: Record<string, unknown> = { canClaim: can[0], reason: can[1] || null, claimed, reward };
        if (pend[0]) {
          st.pending = { targetBlock: pend[1].toString(), ready: pend[4], expired: pend[5], blocksLeft: pend[4] ? 0 : Number(pend[1] - block + 1n) };
          if (pend[4]) st.nextTx = txFor(wallet, encodeSettle(id), `Settle RANDOM claim in campaign ${id}`);
        }
        out.you = st;
      }
      return out;
    }));
    const campaigns = all.filter(Boolean);
    return send(res, 200, {
      ok: true, deployed: true, network: NET.key, chainId: CHAIN_ID, contract: QUEST_REWARDS, token, signer, block: block.toString(),
      wallet, agentId: handle ? `${handle}.ai` : wallet ? null : undefined, campaigns,
    });
  } catch (e) {
    console.error("campaigns error:", e instanceof Error ? e.message : "unknown");
    return send(res, 502, { ok: false, code: "UPSTREAM", error: "Chain read failed. Try again shortly." });
  }
}
