import { useQuery } from "@tanstack/react-query";
import { useReadContracts } from "wagmi";
import type { Address, Hex } from "viem";
import { agentIdAbi, erc20Abi } from "./abis";
import { hiddenCampaignIdsFor } from "../../api/_networks";
import { AGENT_ID_REGISTRY, NET, QUEST_REWARDS } from "../config";
import { useAccount, useSession } from "./session";

export function useMyAgentId() {
  const { address } = useAccount();
  const r = useReadContracts({
    contracts: [
      { address: AGENT_ID_REGISTRY, abi: agentIdAbi, functionName: "balanceOf", args: [address as Address] },
      { address: AGENT_ID_REGISTRY, abi: agentIdAbi, functionName: "handleOf", args: [address as Address] },
    ],
    query: { enabled: !!address },
  });
  const bal = r.data?.[0]?.result as bigint | undefined;
  const handle = ((r.data?.[1]?.result as string | undefined) ?? "").toLowerCase();
  return { address, ok: !!bal && bal > 0n && !!handle, handle, isLoading: r.isLoading, refetch: r.refetch };
}

export function useTokenInfo(token?: Address) {
  const r = useReadContracts({
    contracts: [
      { address: token, abi: erc20Abi, functionName: "symbol" },
      { address: token, abi: erc20Abi, functionName: "decimals" },
    ],
    query: { enabled: !!token, staleTime: Infinity },
  });
  const decimals = r.data?.[1]?.result as number | undefined;
  if (decimals === undefined) return undefined;
  return { symbol: (r.data?.[0]?.result as string) ?? "USDT", decimals: Number(decimals) };
}

export type Tx = { label: string; from: Address; to: Address; data: Hex; value: string };
export type You = { canClaim: boolean; reason: string | null; claimed: boolean; reward: string | null; pending?: { targetBlock: string; ready: boolean; expired: boolean; blocksLeft: number }; nextTx?: Tx };
export type Camp = {
  id: string; title: string; mode: "RANDOM" | "FCFS"; creator: Address; blocked: boolean;
  reward: { type: "fixed"; amount: string } | { type: "random"; tiers: { amount: string; oddsPct: number }[]; reservedPerClaim?: string };
  maxClaims: number; slotsUsed: number; settled: number; remainingSlots: string; endTime: number | null; paused: boolean;
  budget: { balance: string; reserved: string; totalPaid: string }; targetPostId: string | null; targetPostUrl: string | null; you?: You;
};
export type CampResp = { ok: boolean; deployed?: boolean; token?: Address; campaigns: Camp[]; error?: string };

/** Quests + (when signed in) your status, from the API. */
export function useCampaigns() {
  const { session } = useSession();
  return useQuery({
    queryKey: ["campaigns", session?.wallet ?? ""],
    queryFn: async (): Promise<CampResp> => {
      const data: CampResp = await (await fetch(`/api/campaigns${session ? `?wallet=${session.wallet}` : ""}`)).json();
      const hidden = new Set(hiddenCampaignIdsFor(NET, QUEST_REWARDS ?? ""));
      if (data?.campaigns?.length && hidden.size) data.campaigns = data.campaigns.filter((c) => !hidden.has(c.id));
      return data;
    },
    refetchInterval: 6000,
  });
}
