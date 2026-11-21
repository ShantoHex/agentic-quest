# Agentic Quest — frontend integration

> Product name: **Agentic Quest**. Contract names and EIP-712 voucher domains (`ProofQuest RewardDrop`, `ProofQuest QuestRewards`) are intentionally unchanged.

Target chain: **BNB Smart Chain mainnet (chain ID 56)**. Testnet is chain 97 and will use a `MockAgentID` if the official registry is not deployed there.

After deploy, replace `PROOFQUEST` with the deployed address. The official Agent ID registry on mainnet is fixed.

```ts
export const PROOFQUEST = "0x…"; // set after deploy
export const AGENT_ID_REGISTRY = "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F";
export const BSC_USDT = "0x55d398326f99059fF77548524633006e1a0d54EE";
```

ABI: [`abi/ProofQuest.json`](abi/ProofQuest.json). Use `wagmi` / `viem`. Every state-changing call must be signed and confirmed by the user in their own wallet. Do not add QR-code or pairing-code login, do not store a wallet session on a server, and do not request unlimited ERC-20 approvals — approve only `prizePerWinner * maxWinners`.

Display Agent IDs as the plain handle (`alice`), not as a general “look up this person’s wallet” tool. Show a risk notice on any page that creates a quest or moves value: prizes are posted by users, there is no promised return, and you can lose gas.

## Constructor (already deployed)

`constructor(address agentId_, address initialOwner, address[] initialTokens)`

## Write functions

| Function | When to call | Notes |
| --- | --- | --- |
| `createQuest(token, prizePerWinner, maxWinners, deadline, solutionHash, verifier, title, metadataURI)` | Poster opens a quest | `token = address(0)` and `msg.value = prizePerWinner * maxWinners` for BNB. For ERC-20, `msg.value` must be 0 and the poster must have `approve`d the exact total. `deadline` is a unix timestamp in the future. `maxWinners` is 1–100. `solutionHash = keccak256(answer)` or `0x0` for verifier-only. `verifier` is an `IQuestVerifier` or `address(0)`. Title 1–128 bytes; `metadataURI` ≤ 256 bytes. |
| `commit(questId, commitHash)` | Solver locks in a hash answer | `commitHash = keccak256(abi.encode(answer, solverAddress, salt))`. `salt` is a secret `bytes32` the client generates and must store until reveal. Overwrite is allowed until the first successful reveal. After that, `CommitsClosed`. |
| `reveal(questId, answer, salt, verifierProof)` | Solver claims a hash quest | Must be at least one block after that address’s commit. Pays `prizePerWinner` to `ownerOfHandle(handleOf(solver))`. `verifierProof` can be `0x` if no verifier is set. |
| `attempt(questId, proof)` | Solver claims a verifier-only quest | Reverts on hash quests. |
| `refund(questId)` | After `deadline` | Sends remaining prize to the original poster. Anyone may call it. |

Owner-only (not needed in the user UI): `addPrizeToken`, `removePrizeToken`, `transferOwnership`, `acceptOwnership`, `renounceOwnership`.

## Read functions

| Function | Returns |
| --- | --- |
| `questCount()` | Number of quests; ids are `1…questCount`. |
| `getQuest(questId)` | Full `Quest` struct (see below). |
| `questWinners(questId)` | `string[]` of winner handles, in award order. |
| `winsOf(handle)` | Lifetime win count for a lowercase handle (no `.ai`). |
| `earningsOf(handle, token)` | Lifetime amount won in that token (`address(0)` = BNB). |
| `hasWonQuest(questId, handle)` | Whether that handle already won this quest. |
| `getCommit(questId, solver)` | `{commitHash, blockNumber}`. `blockNumber == 0` means no commit. |
| `hasAgentId(account)` | `{ok, handle}`. |
| `isPrizeToken(token)` | Whether new quests may use this token. `address(0)` is always true. |
| `agentId()` | Registry address. |
| `computeSolutionHash(answer)` | `keccak256(answer)`. |
| `computeCommitHash(answer, solver, salt)` | Helper; prefer computing locally (see below). |
| `MAX_WINNERS_CAP()` | `100`. |

### `Quest` struct (return order of `getQuest`)

```
poster          address
token           address      // 0x0 = BNB
verifier        address      // 0x0 = none
solutionHash    bytes32      // 0x0 = verifier-only
prizePerWinner  uint128
remainingPrize  uint128
deadline        uint64
firstRevealBlock uint64      // 0 = no hash reveal yet
maxWinners      uint32
winnerCount     uint32
title           string
metadataURI     string
posterHandle    string
```

A quest is open when `block.timestamp < deadline` and `winnerCount < maxWinners`. Hash commits are accepted only while `firstRevealBlock == 0`.

## Events (index / leaderboard)

Listen from the Agentic Quest contract, not the registry.

- `QuestCreated(questId, poster, posterHandle, token, prizePerWinner, maxWinners, deadline, solutionHash, verifier, title, metadataURI)`
- `Committed(questId, solver, solverHandle, commitHash)`
- `Won(questId, solver, solverHandle, token, amount, winnerIndex)`
- `Refunded(questId, poster, token, amount)`
- `PrizeTokenUpdated(token, allowed)`

Leaderboard: either subscribe to `Won` or call `winsOf` / `earningsOf` / `questWinners`. Key rows by handle.

## Client flows

### Create a hash quest

```ts
import { keccak256, stringToBytes, toHex, encodeAbiParameters, parseEther } from "viem";

const answer = stringToBytes("the-secret-answer"); // raw bytes hashed on-chain
const solutionHash = keccak256(answer);
// For BNB:
const prizePerWinner = parseEther("0.02");
const maxWinners = 30;
const deadline = BigInt(Math.floor(Date.now() / 1000) + 7 * 24 * 3600);
const value = prizePerWinner * BigInt(maxWinners);

await walletClient.writeContract({
  address: PROOFQUEST,
  abi,
  functionName: "createQuest",
  args: [
    "0x0000000000000000000000000000000000000000",
    prizePerWinner,
    maxWinners,
    deadline,
    solutionHash,
    "0x0000000000000000000000000000000000000000",
    "Find the phrase",
    "ipfs://…",
  ],
  value,
});
```

For USDT, first `approve(PROOFQUEST, prizePerWinner * maxWinners)` (exact amount only), then the same `createQuest` with `token = BSC_USDT` and no `value`.

Keep the answer off-chain until solvers should be able to find it (riddle, linked write-up, in-app puzzle, etc.). Once one solver reveals, the answer is public on-chain.

### Commit, then reveal

```ts
import { keccak256, encodeAbiParameters, stringToBytes } from "viem";

const salt = crypto.getRandomValues(new Uint8Array(32)); // persist this with the questId
const answer = stringToBytes("the-secret-answer");
const commitHash = keccak256(
  encodeAbiParameters(
    [{ type: "bytes" }, { type: "address" }, { type: "bytes32" }],
    [toHex(answer), solverAddress, toHex(salt)],
  ),
);

await walletClient.writeContract({
  address: PROOFQUEST, abi, functionName: "commit",
  args: [questId, commitHash],
});
// Wait for the commit transaction to be in a past block, then:
await walletClient.writeContract({
  address: PROOFQUEST, abi, functionName: "reveal",
  args: [questId, toHex(answer), toHex(salt), "0x"],
});
```

Encoding must be `abi.encode(answer, solver, salt)` — the same as Solidity — not `encodePacked`. The `solver` address is the wallet that sends `commit` and `reveal`.

Short or guessable answers can be brute-forced offline against a published `solutionHash`. Use a long, high-entropy answer, or a verifier contract, for any prize that matters.

### Verifier-only

```ts
await walletClient.writeContract({
  address: PROOFQUEST, abi, functionName: "attempt",
  args: [questId, proofBytes],
});
```

## Agent ID checks in the UI

```ts
const [ok, handle] = await publicClient.readContract({
  address: PROOFQUEST, abi, functionName: "hasAgentId", args: [address],
});
```

If `ok` is false, prompt the user to claim an Agent ID in the Binance App (Wallet → homepage banner → Agent ID). This dApp cannot issue one.

On testnet, anyone can mint a mock handle, so the 30-Agent-ID requirement is only meaningful on mainnet.

## `IQuestVerifier`

```solidity
function verify(uint256 questId, address solver, bytes calldata proof)
    external view returns (bool);
```

The frontend only needs to pass `proof` through. ProofQuest never sends value to the verifier.

## Common revert reasons

| Error | Likely cause |
| --- | --- |
| `NotAgentIdHolder` | Wallet has no Agent ID. |
| `TokenNotAllowed` | ERC-20 is not whitelisted. |
| `IncorrectValue` | Wrong `msg.value` (BNB total, or non-zero on an ERC-20 create). |
| `QuestExpired` / `QuestFull` | No longer open. |
| `CommitsClosed` | A correct reveal already happened; too late to commit. |
| `SameBlockReveal` | Reveal was sent in the same block as the commit. Wait one block. |
| `BadCommit` / `WrongSolution` | Salt, sender, or answer does not match. |
| `AlreadyWon` | This handle already won this quest. |
| `QuestNotExpired` | `refund` called before the deadline. |


## RewardDrop — quote-post voucher

Testnet RewardDrop: `0xeF23c96f73d87c62d16e6672F20B275A30058E2F` (ABI `abi/RewardDrop.json`). Deprecated: `0xC7f04e754c0667C2255489F809D890293BCB9E18`.

User flow: (1) the user posts a quote of the project post on X; (2) the frontend sends the post URL and the user's wallet to the Vercel function; (3) the function checks the quote with the X API and returns a voucher; (4) the user's wallet sends `commitClaim(xPostIdHash, xAccountIdHash, deadline, signature)`; (5) after `pendingClaim(user).ready` is true (2+ blocks), the user sends `settleClaim()`. Show `canClaim(user)` reasons before step 1, and `isPostUsed` / `isAccountUsed` to give an early error.

### Hashing convention and EIP-712

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

### Server signing (viem)

```ts
import { keccak256, toBytes, getAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const signer = privateKeyToAccount(process.env.VOUCHER_SIGNER_KEY as `0x${string}`); // server env only

export async function makeVoucher(opts: {
  handle: string;          // Agent ID handle from handleOf(user), no ".ai"
  user: `0x${string}`;     // wallet that will call commitClaim
  postId: string;          // e.g. "1990000000000000001" (string, not number)
  xUserId: string;         // numeric X user id as string, e.g. "1234567890"
  rewardDrop: `0x${string}`;
  chainId: 97 | 56;
}) {
  const handleHash = keccak256(toBytes(opts.handle.toLowerCase()));
  const xPostIdHash = keccak256(toBytes(opts.postId));
  const xAccountIdHash = keccak256(toBytes(opts.xUserId));
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 15 * 60);

  const signature = await signer.signTypedData({
    domain: {
      name: "ProofQuest RewardDrop",
      version: "1",
      chainId: opts.chainId,
      verifyingContract: getAddress(opts.rewardDrop),
    },
    types: {
      Voucher: [
        { name: "handleHash", type: "bytes32" },
        { name: "user", type: "address" },
        { name: "xPostIdHash", type: "bytes32" },
        { name: "xAccountIdHash", type: "bytes32" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Voucher",
    message: { handleHash, user: getAddress(opts.user), xPostIdHash, xAccountIdHash, deadline },
  });
  return { xPostIdHash, xAccountIdHash, deadline: deadline.toString(), signature };
}
```

Before signing, the server should: read `handleOf(user)` on-chain (do not trust a client-sent handle), confirm the post's author ID equals `xUserId` and that it quotes the project post, and optionally pre-check `isPostUsed` / `isAccountUsed`. You can cross-check a voucher with `voucherDigest(handleHash, user, xPostIdHash, xAccountIdHash, deadline)` on-chain. viem/ethers produce low-s signatures by default; high-s ones are rejected.

### Frontend call

```ts
await writeContract({
  address: REWARD_DROP, abi: rewardDropAbi, functionName: "commitClaim",
  args: [v.xPostIdHash, v.xAccountIdHash, BigInt(v.deadline), v.signature],
});
```

### RewardDrop revert reasons

| Error | Meaning |
| --- | --- |
| `SignerNotSet` | Owner has not configured a voucher signer. |
| `VoucherExpired` | `block.timestamp > deadline`; get a fresh voucher. |
| `InvalidSignature` | Wrong signer, voucher made for another wallet/handle, edited fields, bad length, or high-s. |
| `PostAlreadyUsed` / `AccountAlreadyUsed` | This X post / X account already claimed. |
| `NoAgentId` | No Agent ID (zero balance or empty handle). |
| `AddressAlreadyClaimed` / `HandleAlreadyClaimed` / `ClaimPending` | One claim per wallet and per Agent ID. |
| `PoolInsufficient` | Pool (minus reservations) below 0.20; owner must top up. |
| `IsPaused` | New commits paused. Pending claims can still settle. |
| `TooEarly` / `NoPendingClaim` | Settle called before the target block, or without a commit. |

## QuestRewards API (agents)

Base: `https://agentic-quest.vercel.app` · full spec `/agent.json` · prose guide `/llms.txt`

| Endpoint | Purpose |
|---|---|
| `GET /api/auth/challenge?wallet=0x…` | EIP-712 login challenge (10 min) + `baw sign-message preview` command |
| `POST /api/auth/verify` `{wallet,message,signature,signatureRecovery?}` | verifies, returns read-only bearer token (24 h) |
| `GET /api/campaigns?wallet=0x…[&id=N]` | campaigns (mode, reward, remainingSlots, targetPostUrl) + per-wallet status; `you.nextTx` = settle calldata when ready |
| `POST /api/verify-quote` `{campaignId,postUrl,wallet}` | checks the quote post against the campaign's on-chain `targetPostId`, returns voucher + claim calldata (`tx`) |
| `POST /api/verify-quote` without `campaignId` | legacy RewardDrop v2 voucher (unchanged) |
| `GET /api/publish` | live creation rules (min budget 1, no max budget, max fixed reward, Agent ID required, open) |
| `POST /api/publish` `{wallet,title,mode,rewardPerClaim?,maxClaims,budget,postUrl?,durationDays?\|endTime?}` | `steps[]`: exact `approve(QuestRewards, budget)` (skipped if allowance suffices) + `createQuest` calldata, each with `agenticWallet.preview`; `warnings[]` |
| `POST /api/manage` `{wallet,id,action,postUrl?,amount?}` | creator actions `pause`/`resume`/`setPost`/`withdraw`, or `fund` (anyone): `steps[]` |
| `GET /api/campaigns?creator=0x…` | quests published by a wallet; every campaign includes `creator` and `blocked` |

Signatures from `baw sign-message execute` (`signature` = r‖s hex, `signatureRecovery` = `00`/`01`) are accepted as-is.
Send transactions with `baw contract-call preview --binanceChainId 56 --from <wallet> --to <contract> --value 0 --inputData <data> --json`,
show the owner the parsed tx and risks, then `baw contract-call execute --requestId <id> --json` only after explicit confirmation.
Developer Mode must be enabled in the Agentic Wallet (Binance App) for both commands.

Server env: `SIGNER_PRIVATE_KEY` (voucher signer, already set), optional `AUTH_SECRET` (≥32 chars, HMAC for login/session;
falls back to a hash derived from the signer key), `QUEST_REWARDS_ADDRESS` (default from `web/api/_networks.ts`), `HIDDEN_QUESTS` (comma-separated quest IDs hidden from listings).
The campaign's X post to quote is read on-chain (`targetPostId`), so `TARGET_POST_ID` is only used by the legacy v2 path.
