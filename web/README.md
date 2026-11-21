# Agentic Quest — web frontend

React + Vite + TypeScript + wagmi v2 + viem, with Vercel Functions in `api/`. The live product uses agent-driven sign-in (see [`/llms.txt`](https://agentic-quest.vercel.app/llms.txt)). No QR or pairing-code login, and no key collection. Token approvals are exact-amount only, never unlimited.

## Run locally

```bash
cd web
npm install
cp .env.example .env.local   # optional; defaults target BSC testnet (chain 97)
npm run dev                  # http://localhost:5173
npm run build                # type-check + production build into dist/
npm run check:reads          # read-only RPC sanity check (no transactions)
node scripts/gen-abi.mjs     # regenerate src/lib/proofQuestAbi.ts after ABI changes
```

## Config (all public, via `VITE_*` env)

| Var | Testnet default | Mainnet |
| --- | --- | --- |
| `VITE_CHAIN_ID` | `97` | `56` |
| `VITE_RPC_URL` | `https://bsc-testnet-rpc.publicnode.com` | e.g. `https://bsc-rpc.publicnode.com` |
| `VITE_PROOFQUEST_ADDRESS` | `0xCE3277D3Cbf7e0785627A63dA7Bb595669322d19` | mainnet deploy |
| `VITE_AGENT_ID_REGISTRY` | `0xD126FBafc7e7a609056e421187A0286FFC27e5c5` (MockAgentID) | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| `VITE_MOCK_REGISTRY` | `true` (shows "mint test handle" helper) | `false` |
| `VITE_USDT_ADDRESS` | empty | `0x55d398326f99059fF77548524633006e1a0d54EE` |
| `VITE_EXPLORER_URL` | `https://testnet.bscscan.com` | `https://bscscan.com` |
| `VITE_SOURCE_REPO_URL` | empty | public GitHub repo |

`.env.production` holds the testnet values used for Vercel builds; change it (or set Vercel env vars) for mainnet.

## Pages

- `/` — Agent ID status (handle or "no Agent ID"; testnet mock-mint helper), quest list with open/ended filters.
- `/quest/:id` — details, winners, commit → reveal (random 32-byte salt from `crypto.getRandomValues`, saved in localStorage keyed by chain+contract+quest+wallet before the wallet prompt, downloadable/importable JSON backup, reveal disabled until ≥1 block after the on-chain commit), verifier `attempt`, post-deadline `refund`.
- `/create` — hash / verifier / combined quests, native or allowlisted ERC-20 prize, exact-amount `approve` (never unlimited), risk notice.
- `/leaderboard` — handles from `questWinners`, ranked by `winsOf`, earnings by `earningsOf`.
- `/about` — Agent ID usage, live owner/pendingOwner/registry reads, owner powers from `ProofQuest.sol`, BscScan source link, non-affiliation notice.
