import { getAddress, isAddress, type Address, type Chain } from "viem";
import { bsc, bscTestnet } from "viem/chains";
import { pickNetwork } from "../api/_networks";

declare const __NETWORK__: string;
/** Network is chosen by ONE env var at build time: NETWORK=mainnet|testnet (shared with the API). */
export const NET = pickNetwork(typeof __NETWORK__ === "string" ? __NETWORK__ : "testnet");
export const CHAIN_ID = NET.chainId;
export const IS_TESTNET = CHAIN_ID !== 56;
export const RPC_URL = NET.rpc;
export const EXPLORER_URL = NET.explorer;
export const chain: Chain = {
  ...(IS_TESTNET ? bscTestnet : bsc),
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: "BscScan", url: EXPLORER_URL } },
};
const opt = (v: string): Address | null => (v && isAddress(v) ? getAddress(v) : null);
export const QUEST_REWARDS = opt(NET.questRewards);
export const AGENT_ID_REGISTRY = getAddress(NET.agentIdRegistry);
export const USDT = getAddress(NET.usdt);
export const MOCK_REGISTRY = NET.mockRegistry;
export const SOURCE_URL = QUEST_REWARDS ? `https://repo.sourcify.dev/${CHAIN_ID}/${QUEST_REWARDS}` : "";
export const VERIFY_API = "/api/verify-quote";
export const NATIVE_SYMBOL = chain.nativeCurrency.symbol;
export const explorerAddress = (a: string) => `${EXPLORER_URL}/address/${a}`;
export const explorerTx = (h: string) => `${EXPLORER_URL}/tx/${h}`;
