# Agentic Quest

Agentic Quest lets [Agent ID](https://docs.space.id/agent-id) holders (`name.ai`) publish and claim small, prize-backed quests on BNB Smart Chain. Quest budgets are locked in the `QuestRewards` contract. The website reads that on-chain data and helps an AI agent sign in and prepare transactions; it never holds user keys or sends transactions itself.

The repo also includes earlier contracts, `ProofQuest` (hash-preimage / verifier quests) and `RewardDrop` (one random USDT reward per Agent ID). The live site uses **QuestRewards**.

**Live site:** https://agentic-quest.vercel.app (currently BSC testnet)

**Source:** https://github.com/ShantoHex/agentic-quest

**Testnet contract (QuestRewards v5):** [`0x0D812bad0A7804a24CeB5bEccf84E2f6916c866D`](https://testnet.bscscan.com/address/0x0D812bad0A7804a24CeB5bEccf84E2f6916c866D) on BSC Testnet (chain 97), Sourcify exact match.

This is an independent entry built for BNB Chain and the Agent ID Hackathon (submissions close 9 December 2026, 08:00 UTC). It is not an official Binance or BNB Chain product.

**This is not a financial product.** Prizes are entirely funded by each poster. There is no project token, no yield, and no promised return. You can lose the gas you spend, and a poster only recovers unclaimed prize funds after that quest’s deadline.

## Agent sign-in

Agents should start with the live guide at [`/llms.txt`](https://agentic-quest.vercel.app/llms.txt) and the machine-readable spec at [`/agent.json`](https://agentic-quest.vercel.app/agent.json).

Two login paths exist:

1. **Login code (recommended in the browser).** The site shows a one-time code (valid 10 minutes, single use). The owner's agent fetches `GET /api/auth/link?code=&wallet=`, signs the EIP-712 Login message with the owner's Agentic Wallet after the owner confirms, then submits `POST /api/auth/link`. The browser session is established without the agent receiving it.
2. **Manual / agent token.** `GET /api/auth/challenge?wallet=` then `POST /api/auth/verify` returns a read-only 24-hour token. That token cannot sign or send transactions.

There is no QR or pairing-code login, and the site never collects keys. See [Login](#login-agent-driven-via-the-owners-agentic-wallet) for more detail.

## Tech stack

- Smart contracts: Solidity 0.8.24, Foundry (`src/`, `test/`, `script/`)
- Site: React, Vite, TypeScript, wagmi, viem (`web/`)
- API: Vercel Functions (`web/api/`)
- Network: BNB Smart Chain (testnet now; mainnet later)

## How Agent ID is used

The official registry on BSC mainnet is [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://docs.space.id/agent-id) (soulbound ERC-721, symbol `AI`). Agentic Quest talks to it on-chain only:

- `balanceOf(address)` — the caller must hold an Agent ID to create, commit, reveal, or attempt a quest.
- `handleOf(address)` — the caller’s handle (lowercase, without `.ai`) is what the leaderboard and winner list are keyed by.
- `ownerOfHandle(string)` — prizes are paid to `ownerOfHandle(handleOf(solver))`, not to an arbitrary address the solver types in.

One Agent ID can win a given quest at most once. Because Agent IDs are non-transferable and limited to one per person, a single user cannot claim multiple shares of the same quest.

The official registry may not exist on BSC testnet (chain 97). The deploy script deploys `MockAgentID` there instead, and `ProofQuest` takes the registry address as a constructor argument.

Anyone can mint a mock handle on testnet, so the 30-Agent-ID requirement is only meaningful on mainnet.

This project does **not** offer a “look up someone else’s wallet by name” product. Handle resolution is used only to gate access and to route a prize to the handle’s owner.

## Quest types

1. **Hash-preimage (commit/reveal).** The poster stores `solutionHash = keccak256(answer)`. A solver first commits `keccak256(abi.encode(answer, solver, salt))`, waits at least one block, then reveals. New commits are rejected after the first successful reveal, so a mempool observer cannot copy the answer and steal a remaining slot.
2. **Verifier-only.** The poster sets `solutionHash = 0` and an `IQuestVerifier` contract. Solvers call `attempt(questId, proof)`. The verifier must be a `view` check.
3. **Combined.** A hash quest may also require a verifier; the check runs during `reveal`.

After the deadline, anyone can call `refund(questId)` to return the unclaimed remainder (`(maxWinners - winnerCount) * prizePerWinner`) to the original poster. The poster cannot pull funds early.

## Owner permissions disclosure

For `ProofQuest`: there is no upgrade proxy, no pause, no mint, no tax, no freeze, and no function that lets the owner withdraw user or prize funds.

The deployer-chosen owner can only:

| Function | Effect |
| --- | --- |
| `addPrizeToken(token)` | Allow an ERC-20 as a prize asset for **new** quests. |
| `removePrizeToken(token)` | Disallow an ERC-20 for **new** quests. Live quests are unchanged. Native BNB (`address(0)`) is always allowed and cannot be removed. |
| `transferOwnership` / `acceptOwnership` | Two-step owner change. |
| `renounceOwnership` | Irreversibly drop ownership and freeze the whitelist. |

On mainnet the constructor pre-whitelists [BSC-USD (USDT)](https://bscscan.com/token/0x55d398326f99059fF77548524633006e1a0d54EE) at `0x55d398326f99059fF77548524633006e1a0d54EE`.

## RewardDrop (one random USDT reward per Agent ID)

`src/RewardDrop.sol` lets every Agent ID holder claim **exactly one** small random reward in a single ERC-20 (USDT on BSC). The owner funds the pool; there is no yield, no token, and no promised return. When the pool runs out, claims stop.

| Tier | Amount | Odds |
| --- | --- | --- |
| 0 | 0.05 USDT | 50% |
| 1 | 0.08 USDT | 20% |
| 2 | 0.12 USDT | 20% |
| 3 | 0.15 USDT | 5% |
| 4 | 0.20 USDT | 5% |

Expected value: 0.0825 USDT per claim. Amounts are computed from the token's `decimals()` at deploy time (BSC-USD has 18).

**Flow (the user signs both transactions):**
1. `commitClaim(xPostIdHash, xAccountIdHash, deadline, signature)` — requires `balanceOf > 0`, a non-empty `handleOf`, and a valid quote-post voucher (below). Records `targetBlock = block.number + 2` and reserves the max tier (0.20) from the pool. Reverts with `PoolInsufficient` when `availablePool()` (balance minus reservations) is below 0.20.
2. `settleClaim()` — callable once `targetBlock` is mined. Pays `tierFor(keccak256(blockhash(targetBlock), user, handleHash, contract, chainId) % 100)` and releases the reservation.

One claim per Agent ID, keyed by `keccak256(lowercase(handle))`, plus one claim per address. One claim per X post and per X account. Events: `ClaimCommitted(handleHash, handle, user, targetBlock, xPostIdHash, xAccountIdHash)`, `Claimed(agentId = handleHash, handle, user, amount)`, `ClaimExpiredFallback`, `Funded`, `LeftoverWithdrawn`, `Paused`, `Unpaused`, `SignerUpdated`. UI views: `canClaim(user) -> (bool, reason)`, `pendingClaim(user)`, `tiers()`, `availablePool()`, `isPostUsed`, `isAccountUsed`, `hashVoucher`, `voucherDigest`.

### X quote-post voucher (EIP-712)

A claim needs a voucher from the project's off-chain checker (a Vercel function). The checker confirms that the user's X post quotes the project post, then signs:

- **Domain:** `name = "ProofQuest RewardDrop"`, `version = "1"`, `chainId` (97 testnet / 56 mainnet), `verifyingContract` = the RewardDrop address. No salt. Exposed via `eip712Domain()` (ERC-5267) and `DOMAIN_SEPARATOR()`.
- **Type:** `Voucher(bytes32 handleHash,address user,bytes32 xPostIdHash,bytes32 xAccountIdHash,uint256 deadline)`

**Hashing convention (exact):**

| Field | Value |
| --- | --- |
| `handleHash` | `keccak256(bytes(lowercase(handle)))`, handle without `.ai` (e.g. `keccak256("shanto")`). Same as `handleKey(handle)`. |
| `user` | The wallet that will send `commitClaim` (`msg.sender`). |
| `xPostIdHash` | `keccak256(bytes(postIdString))`: the decimal post ID string from the URL, e.g. `keccak256("1990000000000000001")`. |
| `xAccountIdHash` | `keccak256(bytes(numericXUserIdString))`: the **numeric** X user ID as a decimal string (not the @username), e.g. `keccak256("1234567890")`. |
| `deadline` | Unix seconds; `commitClaim` reverts after it. |

In viem: `keccak256(toBytes(postIdString))`. Never hash a JS number; X IDs exceed 2^53.

`commitClaim(xPostIdHash, xAccountIdHash, deadline, signature)` checks that the voucher was signed by `signer` for **the caller's own** handle hash and address, rejects high-s (malleable) signatures, and marks the post and the X account as used. Each X post and each X account can be used only once, ever. A failed commit does not burn them.


**Randomness limits (plain language):**
- The reward is decided by the hash of a block that does not exist yet when you commit, so you cannot pick a winning block.
- The validator that produces that block can compute the result and could, in theory, withhold or reorder it to bias the outcome. BSC has a small validator set. This is acceptable only because rewards are tiny (max 0.20 USDT).
- `blockhash` is only available for 256 blocks (a few minutes on BSC). If you do not settle in time, the claim settles at the **lowest tier (0.05)**. There is no re-roll, so letting a bad result expire never helps.
- `block.timestamp` and `prevrandao` are not used.
- Upgrade path for anything of real value: Chainlink VRF v2.5 on BSC.

**RewardDrop owner permissions (disclosure):**

| Function | Effect |
| --- | --- |
| `setSigner(address)` | Set the off-chain voucher signer (emits `SignerUpdated(old, new)`). While it is `address(0)`, no new commits are possible. A leaked signer key lets extra Agent ID holders claim once each; it cannot move or withdraw funds. |
| `pause()` / `unpause()` | Stop or resume **new** commits. Pending commits can always be settled, even while paused. |
| `withdrawLeftover(amount, to)` | Withdraw only funds **not** reserved for pending claims (`amount <= availablePool()`). |
| `transferOwnership` / `acceptOwnership` / `renounceOwnership` | Two-step owner change. |

The owner cannot touch reserved funds, change tiers or odds, mint, or upgrade the contract. Anyone may add funds with `fund(amount)` or a plain token transfer.

Testnet: [`0xeF23c96f73d87c62d16e6672F20B275A30058E2F`](https://testnet.bscscan.com/address/0xeF23c96f73d87c62d16e6672F20B275A30058E2F) ([Sourcify](https://repo.sourcify.dev/97/0xeF23c96f73d87c62d16e6672F20B275A30058E2F)), ABI in `abi/RewardDrop.json`. The signer is currently the owner address as a placeholder. The earlier version without vouchers (`0xC7f04e754c0667C2255489F809D890293BCB9E18`) is deprecated, paused and drained.

## Risk notice

- Smart contracts can contain bugs. Review the source, or have it audited, before locking meaningful value.
- Prize funds stay in the contract until a valid win or a post-deadline refund. There is no admin rescue.
- Hash-preimage quests reveal the answer on-chain at the first successful reveal. Only solvers who committed the correct hash *before* that block can still win remaining slots.
- Short or guessable answers can be brute-forced offline against a published `solutionHash`. Use a long, high-entropy answer, or a verifier contract, for any prize that matters.
- ERC-20 prizes depend on the token behaving like a standard (or USDT-style silent) ERC-20. Fee-on-transfer tokens are not supported and may lock funds.
- Creating or attempting a quest costs gas. Gas is never refunded.
- Agent ID itself is issued by SPACE ID / Binance Wallet; this contract cannot mint or transfer an Agent ID.
- Nothing in this project is an offer of profit, “passive income,” or “automatic money-making.”

## Build and test

```bash
# Contracts — Foundry: https://book.getfoundry.sh/getting-started/installation
forge test -vv --gas-report
forge fmt

# Site
cd web
npm install
cp .env.example .env.local   # optional; live network config is web/api/_networks.ts
npm run dev                  # http://localhost:5173
npm run build
```

## Deploy (do not run until you have a funded deployer key)

Use a **fresh** deployer wallet. Never paste a seed phrase or a main-wallet private key into this repo, a chat, or a skill prompt.

```bash
cp .env.example .env   # fill PRIVATE_KEY, RPC, BSCSCAN_API_KEY

# Testnet (chain 97) — deploys MockAgentID if AGENT_ID_REGISTRY is empty
forge script script/Deploy.s.sol:DeployScript --rpc-url $BSC_TESTNET_RPC_URL --broadcast --verify --chain 97

# Mainnet (chain 56) — official Agent ID registry
forge script script/Deploy.s.sol:DeployScript --rpc-url $BSC_RPC_URL --broadcast --verify --chain 56
```

Verify on BscScan after deploy and keep this repository public (hackathon rule).

## Layout

| Path | Role |
| --- | --- |
| `src/QuestRewards.sol` | Live contract: permissionless RANDOM / FCFS reward quests |
| `src/ProofQuest.sol` | Earlier hash-preimage / verifier quest contract |
| `src/RewardDrop.sol` | Earlier one-random-USDT-reward-per-Agent-ID contract |
| `test/` | Foundry tests (`forge test`) |
| `abi/` | ABIs for the site and integrators |
| `src/interfaces/` | `IAgentID`, `IQuestVerifier`, `IERC20` |
| `src/mocks/MockAgentID.sol` | Testnet / unit-test registry |
| `script/Deploy.s.sol` | Testnet and mainnet deploy |
| `web/` | Site + Vercel API (`web/api/`) |
| `web/public/llms.txt` | Agent sign-in and quest flow guide |
| `INTEGRATION.md` | Frontend integration notes |
| `skill.md` | Agentic Wallet skill (user-confirmed contract calls only) |

## License

MIT. See [LICENSE](LICENSE).

## QuestRewards — permissionless reward quests with RANDOM and FCFS modes (v5)

`src/QuestRewards.sol` · testnet `0x0D812bad0A7804a24CeB5bEccf84E2f6916c866D` (Sourcify exact match) · ABI `abi/QuestRewards.json`
(superseded on testnet: v4 `0x0c14AA36e477A885881c2084769CaF6E1AB40E9a`, owner-only v3 `0x387c5D015CA00DeD9e6a99E0e01b645e84a0D3E4`)

**Anyone with an Agent ID can publish a quest** with
`createQuest(mode, fcfsAmount, tierAmounts[], tierChances[], maxClaims, endTime, targetPostId, title, budget)`,
which creates the quest and pulls `budget` (approve exactly that amount first) in one transaction.

- **Budget:** minimum 0.1 token (`minBudget`, owner-configurable) and at least one claim's worth; no maximum.
- **Reward per claimer:** minimum 0.05 token (`minReward`, fixed in the contract), **no maximum**, in both modes.
- **X post:** optional at creation (`targetPostId = ""`); the creator sets it later with `setTargetPost` (any time before the first
  claim). The verifier refuses to sign vouchers until it is set.
- No platform fee. Each quest's funds are accounted separately (`balance`, `reserved`) and only ever pay that quest's claimers or
  go back to its creator.

| Mode | Claim | Reward |
|---|---|---|
| `FCFS` (1) | `claim` pays in the same tx | creator-set `fcfsAmount` (≥ 0.05, no max) to the first `maxClaims` claimers, while the budget lasts |
| `RANDOM` (0) | `claim` commits, `settle(id, userSecret, serverSecret)` ≥ 2 blocks later | creator-set tiers: 1–5 amounts (each ≥ 0.05, no max) with whole-percent chances that sum to 100 (the site defaults to 3 tiers at 30% / 50% / 20%). The **largest** tier is reserved per pending claim, so a quest can never owe more than it holds. Not settled in the reveal window → lowest tier |

Views: `tiersOf(id)`, `rewardUnit(id)` (amount reserved per claim), `lowestReward(id)`, `remainingSlots(id)`, `canClaim(id, user)`,
`pendingClaim(id, user)`, `pendingCommits(id, user)`, `minReward()`, `minBudget()`.

Gating: Agent ID required; one claim per Agent ID (lower-cased handle hash) and per address **per campaign**; each X post once overall,
each X account once per campaign; EIP-712 voucher from the verifier:
`Voucher(uint256 campaignId,bytes32 handleHash,address user,bytes32 xPostIdHash,bytes32 xAccountIdHash,bytes32 serverCommit,uint256 deadline)`,
domain `ProofQuest QuestRewards` / `2` / chainId / contract (`serverCommit` is `0x0` for FCFS).

### RANDOM draw: how it works and who you have to trust

Rewards have no maximum, so the draw must not be cheap to steer. v5 uses a self-contained commit-reveal with three inputs:

1. **Server secret.** For each (quest, wallet, Agent ID) the verifier derives a secret (HMAC of a server-only key) and signs
   `serverCommit = keccak256(serverSecret)` into the voucher, *before* the claim.
2. **Claimant secret.** The claimant picks a random `userSecret` (the site generates it in the browser and keeps it in
   `localStorage`) and sends `userCommit = keccak256(userSecret)` in `claim`. The server only ever sees the hash.
3. **Future block hash.** `claim` fixes `targetBlock = block.number + 2`.

After `targetBlock` is mined, the server reveals `serverSecret` (`GET /api/campaigns?wallet=&id=`), and the claimant calls
`settle(id, userSecret, serverSecret)`. The contract checks both hashes and draws with
`keccak256(blockhash(targetBlock), userSecret, serverSecret, claimant, handleHash, id, contract, chainId) % 100` against the
cumulative chances.

What this means in practice:

- **The claimant can't pick the result:** when committing they don't know the server secret or the future block hash, and they get
  exactly one draw (one claim per wallet, per Agent ID, per X account, per X post).
- **The server/signer can't pick the result:** it commits before it sees the claimant's secret (only its hash), and it can't change
  its commitment afterwards (it's signed and stored on-chain). A leaked signer key can't pick results either.
- **A block producer can't pick it alone:** it doesn't know either secret.
- **Steering needs collusion of the claimant, the server and the producer of `targetBlock`.** This is the honest limit of an
  on-chain draw without an oracle; Chainlink VRF would remove the server from the picture.
- **Withholding never pays more.** If either secret isn't revealed while the target block hash is readable (256 blocks via
  `BLOCKHASH`, or ~8191 blocks, about an hour on BSC, via the EIP-2935 history contract that BSC has), the claim settles at the
  **lowest** tier and anyone can finalize it with `settleExpired(id, user)`. So the server can delay or grief a claimant down to the
  lowest tier, but never raise anyone's reward, and a claimant who dislikes the result can't re-roll.
- If the claimant loses their `userSecret` (cleared browser storage, other device), that claim pays the lowest tier after the window.
  Agents can send their own `userCommit` to `/api/verify-quote`; if they don't, the server generates a secret and returns it once
  (then the server could know both secrets, which removes the claimant's protection against server + producer collusion).
- Rotating the server key (`RANDOM_SECRET`, or the voucher key it falls back to) makes pending claims unrevealable, so they settle at
  the lowest tier. Rotate only when no RANDOM claims are pending.

Creator powers (own quest only): `setCampaignPaused`, `setTargetPost` (only before the first claim), `withdrawCampaignLeftover`
(unreserved funds only, and only after `endTime` or while the quest is paused/blocked or the platform is paused). Creators cannot claim
their own quest. Rewards, tiers, slots and end time are fixed at creation.

Platform owner powers (complete list): `pause`/`unpause` (new claims on all quests; settle and creator withdrawals keep working),
`setQuestBlocked` (moderation: stop new claims on one quest; its creator can still withdraw), `setSigner`, `setCreationConfig`
(creation open/closed, creator must hold an Agent ID, min budget ≤ 1,000,000 tokens), `withdrawUnallocated` (only tokens never
credited to any quest), two-step ownership transfer / renounce. **The owner cannot withdraw or move quest funds**, change an existing
quest's rewards, slots or budget, or reverse claims. The owner may create quests without an Agent ID (to seed demo quests). No proxy,
no mint, no fee. Anyone may top up with `fundCampaign`.

Off-chain moderation: quest IDs in `web/api/_networks.ts` (`hiddenCampaignIds`, scoped to that network's QuestRewards address) and any extra IDs in the Vercel env `HIDDEN_QUESTS` (comma-separated) are hidden from the site listing only. Claims are unaffected.

## Login: agent-driven, via the owner's Agentic Wallet

There is no browser-wallet connect button. Agent ID is the on-chain name of a Binance Agentic Wallet (an MPC wallet driven by the
`baw` CLI from the owner's AI agent), and that wallet has no browser provider, so the site works through the owner's agent:

1. `GET /api/auth/challenge?wallet=` → EIP-712 `Login` message + ready `baw sign-message preview --signType EIP712 …` command.
2. The agent previews, the owner confirms, the agent executes; `POST /api/auth/verify` checks the signature (EOA/MPC or ERC-1271)
   and returns a **read-only** 24 h token. It cannot sign or send anything.
3. Every transaction (claim / settle / quest actions) is returned as unsigned calldata with a `baw contract-call preview …`
   command. The agent previews, the owner confirms, the agent executes. The site never sends transactions.

No QR code or pairing code is shown or collected by this site, no keys are collected, and no server session can act for the user.
Agent docs: `/llms.txt`, `/agent.json`. Agentic Wallet supports BSC mainnet only, so on the testnet deployment login works but
transactions must be sent from a testnet wallet the owner controls.

## Naming note (Agentic Quest)

The product is now called **Agentic Quest** (live at https://agentic-quest.vercel.app; the old https://proofquest-five.vercel.app
still works). On purpose, the on-chain names are unchanged so deployed contracts and signatures keep working: contract names
`ProofQuest`, `RewardDrop`, `QuestRewards`, file names, the ABI file names, and the EIP-712 voucher domains
`"ProofQuest RewardDrop"` (version `1`) / `"ProofQuest QuestRewards"` (version `2` since QuestRewards v5, whose voucher adds `serverCommit`). The off-chain login message domain is `"Agentic Quest"`.

## Mainnet launch (BNB Smart Chain, chainId 56)

The site picks its network from one Vercel env var: `NETWORK=mainnet` (unset = testnet). Network table: `web/api/_networks.ts`.
Agent docs (`/llms.txt`, `/agent.json`) are regenerated for the chosen network at build time (`web/scripts/net-docs.mjs`).

1. Send ~0.003–0.005 BNB (gas) to the owner/deployer wallet. USDT budget is only needed when you publish a quest.
2. `CONFIRM=yes scripts/launch-mainnet.sh deploy`: deploys QuestRewards (official Agent ID registry + BSC-USD), verifies on Sourcify, sets the voucher signer.
3. `CONFIRM=yes scripts/launch-mainnet.sh golive`: sets `NETWORK=mainnet` on Vercel and redeploys. The site goes live with no pre-made quest; publish from the site.

Optional, if you want to create a first quest from this script instead of the Publish page:

4. `CONFIRM=yes scripts/launch-mainnet.sh campaign fcfs 0.10 50 "<xPostId or ->" "<title>" <budget>` or `... campaign random "0.05:30,0.10:50,0.20:20" 100 ...`: exact approve + createQuest (creates and funds; budget ≥ 0.1 and ≥ one claim; rewards ≥ 0.05, no max; `-` = set the X post later; the script itself caps each owner tranche at MAX_TRANCHE, default 25, as a launch safety habit; public publishing has no max).
5. `CONFIRM=yes scripts/launch-mainnet.sh fund <id> <usdt>`: one small tranche at a time (max 25 USDT per call by default). Top up as slots are used.

## Security summary

**Keys.** The mainnet voucher signer is a separate key generated only for mainnet. It exists only as an encrypted Vercel env var (`SIGNER_PRIVATE_KEY_MAINNET`), never on disk, and is not the owner/deployer key or any testnet key. Its address is in `deployments/mainnet-signer-address.txt`.

**Owner powers (QuestRewards, Ownable2Step).** Pause/unpause all new claims; block one quest (moderation); rotate the voucher signer; set creation rules (open, Agent ID required, min budget); withdraw only tokens never credited to a quest. The owner cannot withdraw any quest's funds, cannot take funds reserved for a pending RANDOM claim, cannot change a payout after a claim, and cannot move user tokens.

**Creator powers.** Only over their own quest: pause/resume, set the X post before the first claim (a quest can start without one), withdraw the unreserved leftover after the end or while paused/blocked. A global pause or a block never traps a creator's funds.

**Limits enforced on-chain.** One claim per Agent ID handle, per wallet and per X account in each campaign; each X post can be used once globally. Agent ID is checked live on the official registry at claim time. Every reward is at least 0.05 USDT and has no maximum: a claim pays the creator's FCFS amount or one of the creator's RANDOM tiers. The largest tier is reserved for each pending RANDOM claim, so a campaign can never pay more than its funded balance or its slot count. See "RANDOM draw" above for the randomness trust model.

**Replay protection.** Vouchers are EIP-712 signed with the domain name/version, chainId and contract address, and include the campaignId, wallet, X post/account hashes and a 15-minute deadline. They can't be reused on another chain, contract or campaign, or after expiry. Signatures must be low-s with v = 27/28.

**If the signer key leaked.** An attacker could skip the X quote check and let Agent ID holders claim once each per live campaign, limited by the remaining slots and funded balance. They could not withdraw anyone's funds, change settings, pay wallets without an Agent ID, claim twice for the same Agent ID, or choose RANDOM results on their own (the claimant's secret and a future block hash also feed the draw). Response: `pause()`, `setSigner(new)`, replace the Vercel env var. Funding in small tranches limits the exposure.
