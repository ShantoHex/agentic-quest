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
};

export const NETWORKS: Record<"testnet" | "mainnet", Net> = {
  testnet: {
    key: "testnet",
    chainId: 97,
    name: "BSC Testnet",
    rpc: "https://bsc-testnet-dataseed.bnbchain.org",
    explorer: "https://testnet.bscscan.com",
    questRewards: "0x0c14AA36e477A885881c2084769CaF6E1AB40E9a",
    agentIdRegistry: "0xD126FBafc7e7a609056e421187A0286FFC27e5c5", // MockAgentID
    usdt: "0x6898e0e131FDB06b9Ae8d4C3f4475438F04c3398", // test USDT
    mockRegistry: true,
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
  },
};

export function pickNetwork(v: string | undefined): Net {
  return (v || "").toLowerCase() === "mainnet" ? NETWORKS.mainnet : NETWORKS.testnet;
}
