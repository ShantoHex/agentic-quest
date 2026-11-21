import { createConfig, http } from "wagmi";
import { chain, RPC_URL } from "./config";

// Read-only chain access. There is NO browser-wallet connector: users sign in and transact through
// their own agent's Agentic Wallet (see components/SignIn.tsx and components/AgentTx.tsx).
export const wagmiConfig = createConfig({
  chains: [chain],
  connectors: [],
  transports: { [chain.id]: http(RPC_URL) },
  multiInjectedProviderDiscovery: false,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
