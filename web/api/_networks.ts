// Single source of network config for the site AND the API.
// Switch networks with ONE env var on Vercel: NETWORK=mainnet (default: testnet).
// After the mainnet deploy, put the QuestRewards address below (scripts/launch-mainnet.sh does it).
export type Net = {
  key: "testnet" | "mainnet";
  chainId: number;
  name: string;
  rpc: string;
  explorer: string;
  questRewards: string; // "" = not deployed yet
  agentIdRegistry: string;
  usdt: string;
  mockRegistry: boolean;
  /** Quest IDs hidden from public listings, only for this exact QuestRewards address. Future IDs are not hidden. */
  hiddenCampaignIds: readonly string[];
};

export const NETWORKS: Record<"testnet" | "mainnet", Net> = {
  testnet: {
    key: "testnet",
    chainId: 97,
    name: "BSC Testnet",
    rpc: "https://bsc-testnet-dataseed.bnbchain.org",
    explorer: "https://testnet.bscscan.com",
    questRewards: "0x0D812bad0A7804a24CeB5bEccf84E2f6916c866D",
    agentIdRegistry: "0xD126FBafc7e7a609056e421187A0286FFC27e5c5", // MockAgentID
    usdt: "0x6898e0e131FDB06b9Ae8d4C3f4475438F04c3398", // test USDT
    mockRegistry: true,
    // v5 e2e proof quests (#1 FCFS, #2 RANDOM). Do not add future IDs here.
    hiddenCampaignIds: ["1", "2"],
  },
  mainnet: {
    key: "mainnet",
    chainId: 56,
    name: "BSC",
    rpc: "https://bsc-dataseed.bnbchain.org",
    explorer: "https://bscscan.com",
    questRewards: "",
    agentIdRegistry: "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F", // SPACE ID Agent ID (official)
    usdt: "0x55d398326f99059fF775485246999027B3197955", // BSC-USD
    mockRegistry: false,
    hiddenCampaignIds: [],
  },
};

export function pickNetwork(v: string | undefined): Net {
  return (v || "").toLowerCase() === "mainnet" ? NETWORKS.mainnet : NETWORKS.testnet;
}

/** Hidden listing IDs for `contract`, only when it is this network's configured QuestRewards. */
export function hiddenCampaignIdsFor(net: Net, contract: string): readonly string[] {
  if (!contract || !net.questRewards) return [];
  if (contract.toLowerCase() !== net.questRewards.toLowerCase()) return [];
  return net.hiddenCampaignIds;
}
