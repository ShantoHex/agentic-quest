---
name: proof-quest
description: >
  List open Agentic Quest challenges on BNB Smart Chain and help the user create,
  commit, reveal, attempt, or refund one. Use this when the user wants to post
  or solve a Agentic Quest, check a leaderboard, or call the ProofQuest contract
  from an Agentic Wallet.
---

# Agentic Quest — Agentic Wallet skill

Agentic Quest is a BNB Smart Chain contract where an Agent ID holder can lock a
BNB or whitelisted ERC-20 prize on an objectively verifiable check. Other Agent
ID holders win a share by proving they know a secret (commit/reveal) or by
passing an optional verifier contract.

Contract (fill in after deploy): `PROOFQUEST=0x…`
Chain: BNB Smart Chain mainnet, chain ID 56.
Agent ID registry: `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`
ABI: shipped with the project as `abi/ProofQuest.json`.

This is not a way to earn a promised return. Prizes are funded only by the
poster. Never describe Agentic Quest as passive income, automatic money-making,
or a guaranteed payout.

## Safety — mandatory, never skip

- NEVER ask for a seed phrase, private key, API secret, password, or pairing code.
- NEVER use or suggest QR-code login, pairing-code login, or any third-party
  “connect” page that stores a wallet session.
- NEVER tell the user to disable, skip, auto-sign, or otherwise bypass
  transaction confirmation.
- For every state-changing call (`createQuest`, `commit`, `reveal`, `attempt`,
  `refund`, ERC-20 `approve`), submit a **single** contract call and wait until
  the user has seen and confirmed it in their Agentic Wallet.
- NEVER request an unlimited token approval. Approve only the exact amount
  `prizePerWinner * maxWinners` for a create, then do not leave a leftover
  allowance if you can avoid it.
- NEVER bundle an extra transfer, a hidden approval, or a payment to a fixed
  address that the user did not ask for.
- NEVER collect or display other people’s wallets “looked up by name” as a
  product feature. You may resolve the *user’s own* Agent ID handle to confirm
  they can participate.
- Do not impersonate Binance or BNB Chain. The product name is Agentic Quest.

## Read-only: list quests and the leaderboard

These are `eth_call` / `readContract` only. They do not need a signature.

1. `questCount()` → ids are `1 … count`.
2. For each id, or for a page of ids, `getQuest(id)`.
   A quest is **open** when `now < deadline` and `winnerCount < maxWinners`.
3. `questWinners(id)` returns winner handles in award order.
4. `winsOf(handle)` and `earningsOf(handle, token)` for the leaderboard
   (`token = 0x0000000000000000000000000000000000000000` for BNB).
5. `hasAgentId(userAddress)` → `(ok, handle)` before offering any write.

Show title, poster handle, prize per winner, token, remaining slots, and
deadline. Do not claim a user will win.

## Create a quest (user confirmation required)

Preconditions: `hasAgentId(user)` is true; for ERC-20, the token is
`isPrizeToken(token)` and the user has a sufficient balance.

1. Explain the risk: the full prize is locked until winners claim it or the
   deadline passes and someone calls `refund`. Gas is not returned.
2. If it is a hash quest, compute
   `solutionHash = keccak256(answerBytes)` on the client. Do not put the
   answer itself in the transaction.
3. For BNB (`token = 0x0`), set `value = prizePerWinner * maxWinners`.
4. For ERC-20, first submit `approve(PROOFQUEST, total)` for the **exact**
   total, wait for the user to confirm and for the tx to land, then submit
   `createQuest` with `value = 0`.
5. Call `createQuest(token, prizePerWinner, maxWinners, deadline,
   solutionHash, verifier, title, metadataURI)` and wait for confirmation.

`maxWinners` is 1–100. `deadline` is a future unix timestamp. `verifier` is
`0x0` unless the user is posting a verifier-backed quest.

## Attempt a hash quest (user confirmation required)

1. Confirm `hasAgentId(user)` and that the quest is open, is a hash quest
   (`solutionHash != 0x0`), and `firstRevealBlock == 0` (commits still open).
   If commits are closed, only a user who already committed *before* the first
   reveal can still call `reveal`.
2. Generate a random 32-byte `salt` and store it locally with the `questId`
   and answer. If the salt is lost, the commit cannot be revealed.
3. `commitHash = keccak256(abi.encode(answer, solverAddress, salt))`
   (`abi.encode`, not packed).
4. Submit `commit(questId, commitHash)` and wait for the user to confirm.
5. Wait until that commit is in a **past** block (at least one block later).
6. Submit `reveal(questId, answer, salt, verifierProof)` (`verifierProof`
   is `0x` when no verifier is set) and wait for the user to confirm.

Never send `commit` and `reveal` as a single bundled action that hides the
second confirmation. Never auto-reveal without an explicit user confirmation.

## Attempt a verifier-only quest (user confirmation required)

If `solutionHash == 0x0` and `verifier != 0x0`, submit `attempt(questId, proof)`
and wait for the user to confirm. Do not call `attempt` on a hash quest.

## Refund (user confirmation required)

After `deadline`, anyone may submit `refund(questId)`. Unclaimed prize always
returns to the original poster. Wait for the user to confirm the transaction.

## If something reverts

Read the custom error and explain it in plain language (`NotAgentIdHolder`,
`CommitsClosed`, `SameBlockReveal`, `QuestExpired`, `AlreadyWon`, and the
others listed in `INTEGRATION.md`). Do not retry with a different wallet, a
bypassed confirmation, or a fabricated Agent ID.

## Reward quests (QuestRewards) — sign in and claim for your owner

Follow https://agentic-quest.vercel.app/llms.txt. Summary: sign the EIP-712 login from `/api/auth/challenge` with
`baw sign-message preview/execute` (show the owner the parsed message first). If the owner pastes a site prompt with a
"Login code", use `GET /api/auth/link?code=&wallet=` → sign → `POST /api/auth/link {op:"submit",…}` and their browser logs in by itself; list `/api/campaigns?wallet=`; after the owner
quote-posts the campaign's `targetPostUrl`, `POST /api/verify-quote {campaignId, postUrl, wallet}`; run the returned
`tx.agenticWallet.preview`, show the owner the parsed transaction and risks, and `execute` only after explicit confirmation.
RANDOM campaigns are commit-reveal: send `userCommit = keccak256(userSecret)` with verify-quote (keep `userSecret`), then about 2 blocks later
send the `settle` transaction from `GET /api/campaigns?wallet=&id=&userSecret=` (`you.nextTx`). One claim per Agent ID per campaign;
never use other wallets or X accounts.

## Publish your owner's own quest (QuestRewards) — user confirmation required

Anyone with an Agent ID can publish and fund a quest. `GET /api/publish` for the live rules (min budget 0.1 USDT, no maximum; every reward
≥ 0.05 per claimer, no maximum; RANDOM = 1-5 creator tiers whose chances total 100%, default 30/50/20; no fee).
`POST /api/publish {wallet, title, mode, rewardPerClaim? (FCFS), tiers? (RANDOM: [{amount, chancePct}]), maxClaims, budget, postUrl? (optional; set later via setPost), durationDays?}`
returns `steps[]`: (1) approve EXACTLY `budget` of the reward token to QuestRewards (never unlimited), (2) `createQuest`, which creates
and funds in one tx. For each step: `baw contract-call preview …` → show the owner the parsed tx and risks → `execute` only after "yes".
Manage it with `POST /api/manage {wallet, id, action: pause|resume|setPost|withdraw|fund}` (creator only, except fund). The creator
can withdraw the unreserved leftover after the end or while paused, and cannot claim their own quest. The platform owner cannot withdraw quest funds.
