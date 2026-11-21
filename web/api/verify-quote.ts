// Vercel serverless function: verify that an X post quotes the project post, then
// return an EIP-712 voucher for RewardDrop.commitClaim. No wallet sessions, no user keys.
//
// Env (server only):
//   SIGNER_PRIVATE_KEY (testnet) / SIGNER_PRIVATE_KEY_MAINNET (mainnet, separate key): voucher signer, via _lib.signerAccount()
//   TARGET_POST_ID       decimal ID of the project post that must be quoted (required)
//   REWARD_DROP_ADDRESS  RewardDrop v2 (EIP-712 verifyingContract)
//   AGENT_ID_REGISTRY, RPC_URL, CHAIN_ID  (testnet defaults below)
//   BLOB_READ_WRITE_TOKEN  set by the linked Vercel Blob store (submission log)
import { put } from "@vercel/blob";
import { readProgress, readTasks } from "./_tasks.js";
import { randomBytes } from "node:crypto";
import { getAddress, isAddress, keccak256, toBytes, type Address, type Hex } from "viem";
import { CHAIN_ID, client, DEPLOYED, encodeClaim, IS_MAINNET, isBytes32, qrAbi, QUEST_REWARDS, readSession, REGISTRY, REWARD_DROP, serverSecretFor, signerAccount, txFor, VOUCHER_DOMAIN_NAME, VOUCHER_DOMAIN_VERSION, ZERO32 } from "./_lib.js";

const VOUCHER_TTL_SEC = 15 * 60;

const registryAbi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "handleOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "string" }] },
] as const;
const dropAbi = [
  { type: "function", name: "isPostUsed", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "isAccountUsed", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "canClaim", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "bool" }, { type: "string" }] },
  { type: "function", name: "signer", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;



type Json = Record<string, unknown>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function send(res: any, status: number, body: Json) {
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.status(status).send(JSON.stringify(body));
}

/** Parse https://x.com/<user>/status/<id> (also twitter.com, mobile., ?s= params). ID stays a string. */
export function parsePostUrl(raw: string): { postId: string } | null {
  let u: URL;
  try { u = new URL(raw.trim()); } catch { return null; }
  if (u.protocol !== "https:") return null;
  if (!/^(www\.|mobile\.)?(x|twitter)\.com$/i.test(u.hostname)) return null;
  const m = u.pathname.match(/^\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/(\d{1,25})\/?$/);
  return m ? { postId: m[1] } : null;
}

// Free public embed data (no API key). Token formula as used by public embed clients.
async function fetchPost(postId: string) {
  const token = ((Number(postId) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "");
  const r = await fetch(`https://cdn.syndication.twimg.com/tweet-result?id=${postId}&lang=en&token=${token}`, {
    headers: { "User-Agent": "Mozilla/5.0 (compatible; AgenticQuestVerifier/1.0)" },
  });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`X embed data unavailable (HTTP ${r.status})`);
  const text = await r.text();
  if (!text) return null;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const j: any = JSON.parse(text);
  if (j.__typename === "TweetTombstone" || !j.id_str) return null;
  return {
    id: String(j.id_str),
    authorId: j.user?.id_str ? String(j.user.id_str) : "",
    username: j.user?.screen_name ? String(j.user.screen_name) : "",
    quotedId: j.quoted_tweet?.id_str ? String(j.quoted_tweet.id_str) : "",
    createdAt: j.created_at ? String(j.created_at) : "",
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export default async function handler(req: any, res: any) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") return res.status(204).end();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let b0: any = req.body;
  if (typeof b0 === "string") { try { b0 = JSON.parse(b0); } catch { b0 = {}; } }
  if (req.method === "POST" && b0?.campaignId !== undefined && b0?.campaignId !== null && b0?.campaignId !== "") return campaignVoucher(req, res, b0);
  return legacy(req, res);
}

/** QuestRewards: one voucher per campaign. The X post to quote is read from the campaign on-chain.
 *  RANDOM vouchers also carry serverCommit = keccak256(server secret) for the commit-reveal draw. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function campaignVoucher(req: any, res: any, body: any) {
  if (!DEPLOYED) return send(res, 503, { ok: false, code: "NOT_DEPLOYED", error: "Quests are not live on this network yet." });
  const signer = signerAccount();
  if (!signer) return send(res, 503, { ok: false, code: "SIGNER_MISSING", error: "Verifier is not configured yet." });
  let id: bigint;
  try { id = BigInt(String(body.campaignId)); } catch { return send(res, 400, { ok: false, code: "BAD_CAMPAIGN", error: "campaignId must be a number." }); }
  const sess = readSession(req.headers?.authorization);
  const wallet = String(body?.wallet ?? sess?.w ?? "");
  if (!isAddress(wallet)) return send(res, 400, { ok: false, code: "BAD_WALLET", error: "Invalid wallet address." });
  const user = getAddress(wallet) as Address;
  if (sess && sess.w.toLowerCase() !== user.toLowerCase()) return send(res, 403, { ok: false, code: "WALLET_MISMATCH", error: "Signed-in wallet differs from the wallet in the request." });
  const parsed = parsePostUrl(String(body?.postUrl ?? "").slice(0, 300));
  if (!parsed) return send(res, 400, { ok: false, code: "BAD_URL", error: "Paste the full link to your post, like https://x.com/you/status/123…" });
  const c = { address: QUEST_REWARDS, abi: qrAbi } as const;
  try {
    const camp = await client.readContract({ ...c, functionName: "getCampaign", args: [id] }).catch(() => null);
    if (!camp) return send(res, 404, { ok: false, code: "UNKNOWN_CAMPAIGN", error: "No such campaign." });
    const target = camp.targetPostId;
    if (!/^\d+$/.test(target)) return send(res, 503, { ok: false, code: "TARGET_MISSING", error: "This campaign's post to quote has not been announced yet." });
    const [bal, handleRaw] = await Promise.all([
      client.readContract({ address: REGISTRY, abi: registryAbi, functionName: "balanceOf", args: [user] }),
      client.readContract({ address: REGISTRY, abi: registryAbi, functionName: "handleOf", args: [user] }),
    ]);
    const handle = handleRaw.toLowerCase();
    if (bal === 0n || !handle) return send(res, 400, { ok: false, code: "NO_AGENT_ID", error: "This wallet has no Agent ID." });
    const tasks = await readTasks(id.toString());
    if (tasks.length) {
      const progress = await readProgress(id.toString(), user);
      const missing = tasks.filter((task) => !progress.completed.includes(task.id));
      if (missing.length) return send(res, 403, { ok: false, code: "TASKS_INCOMPLETE", error: "Complete all required quest tasks before claiming.", remainingTasks: missing.map((task) => task.id) });
    }
    const can = await client.readContract({ ...c, functionName: "canClaim", args: [id, user] });
    if (!can[0]) return send(res, 409, { ok: false, code: "CANNOT_CLAIM", error: `Cannot claim: ${can[1]}.` });

    const post = await fetchPost(parsed.postId);
    if (!post) return send(res, 404, { ok: false, code: "POST_NOT_FOUND", error: "Post not found. Make sure it is public and not deleted." });
    if (post.id !== parsed.postId || !/^\d+$/.test(post.authorId)) return send(res, 502, { ok: false, code: "BAD_DATA", error: "Could not read the post author." });
    if (post.quotedId !== target) return send(res, 400, { ok: false, code: "NOT_A_QUOTE", error: `This post doesn't quote the campaign post (https://x.com/i/status/${target}).` });

    const handleHash = keccak256(toBytes(handle));
    const xPostIdHash = keccak256(toBytes(post.id));
    const xAccountIdHash = keccak256(toBytes(post.authorId));
    const [postUsed, accountUsed] = await Promise.all([
      client.readContract({ ...c, functionName: "isPostUsed", args: [xPostIdHash] }),
      client.readContract({ ...c, functionName: "isAccountUsed", args: [id, xAccountIdHash] }),
    ]);
    if (postUsed) return send(res, 409, { ok: false, code: "POST_USED", error: "This post was already used for a claim." });
    if (accountUsed) return send(res, 409, { ok: false, code: "ACCOUNT_USED", error: "This X account was already used in this campaign." });

    const mode = camp.mode === 1 ? "FCFS" : "RANDOM";
    // RANDOM commit-reveal: the server commits to its secret now (signed), the claimant commits to theirs in the
    // claim tx. Best practice: the claimant sends its own userCommit = keccak256(userSecret) and keeps userSecret.
    // If none is sent, one is generated here and returned once (then this server could know it; see README).
    let serverCommit: Hex = ZERO32, userCommit: Hex = ZERO32, generatedUserSecret: Hex | null = null;
    if (mode === "RANDOM") {
      serverCommit = keccak256(serverSecretFor(id, user, handleHash));
      if (body?.userCommit !== undefined && body?.userCommit !== null && body?.userCommit !== "") {
        if (!isBytes32(body.userCommit)) return send(res, 400, { ok: false, code: "BAD_COMMIT", error: "userCommit must be keccak256(userSecret) as 0x + 64 hex (not zero)." });
        userCommit = body.userCommit as Hex;
      } else {
        generatedUserSecret = `0x${randomBytes(32).toString("hex")}` as Hex;
        userCommit = keccak256(generatedUserSecret);
      }
    }
    const deadline = BigInt(Math.floor(Date.now() / 1000) + VOUCHER_TTL_SEC);
    const signature = await signer.signTypedData({
      domain: { name: VOUCHER_DOMAIN_NAME, version: VOUCHER_DOMAIN_VERSION, chainId: CHAIN_ID, verifyingContract: QUEST_REWARDS },
      types: {
        Voucher: [
          { name: "campaignId", type: "uint256" },
          { name: "handleHash", type: "bytes32" },
          { name: "user", type: "address" },
          { name: "xPostIdHash", type: "bytes32" },
          { name: "xAccountIdHash", type: "bytes32" },
          { name: "serverCommit", type: "bytes32" },
          { name: "deadline", type: "uint256" },
        ],
      },
      primaryType: "Voucher",
      message: { campaignId: id, handleHash, user, xPostIdHash, xAccountIdHash, serverCommit, deadline },
    });
    if (process.env.BLOB_READ_WRITE_TOKEN) {
      const record = { campaignId: id.toString(), handle, xUsername: post.username, xUserId: post.authorId, postId: post.id, wallet: user, quotedPostId: post.quotedId, postCreatedAt: post.createdAt, verifiedAt: new Date().toISOString(), chainId: CHAIN_ID, contract: QUEST_REWARDS, via: sess ? "agent-session" : "anonymous" };
      await put(`submissions/${CHAIN_ID}/v3/${id}/${handle}/${post.id}.json`, JSON.stringify(record), {
        access: "private", contentType: "application/json", addRandomSuffix: false, allowOverwrite: true,
      }).catch((e) => console.error("blob log failed:", e instanceof Error ? e.message : "unknown"));
    }
    return send(res, 200, {
      ok: true, campaignId: id.toString(), mode, handle, username: post.username, xUserId: post.authorId, postId: post.id,
      voucher: { campaignId: id.toString(), xPostIdHash, xAccountIdHash, serverCommit, userCommit, deadline: deadline.toString(), signature },
      tx: txFor(user, encodeClaim(id, xPostIdHash, xAccountIdHash, serverCommit, userCommit, deadline, signature), mode === "FCFS" ? `Claim FCFS reward (campaign ${id})` : `Commit RANDOM claim (campaign ${id}); settle after 2 blocks`),
      ...(generatedUserSecret ? { userSecret: generatedUserSecret, userSecretNote: "KEEP THIS: needed to settle. It is not stored on the server. Lost secret = lowest tier after the reveal window." } : {}),
      expiresAt: Number(deadline),
      next: mode === "RANDOM" ? "After the claim tx is mined, wait ~3 blocks, then GET /api/campaigns?wallet=<you>&id=<id>&userSecret=<your userSecret> and send you.nextTx (settle reveals both secrets)." : "FCFS pays in the same transaction.",
    });
  } catch (e) {
    console.error("campaign voucher error:", e instanceof Error ? e.message : "unknown");
    return send(res, 502, { ok: false, code: "UPSTREAM", error: "Verification service is temporarily unavailable. Try again shortly." });
  }
}

/** RewardDrop v2 (single global drop) — unchanged legacy path. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function legacy(req: any, res: any) {
  const signer = signerAccount();
  if (IS_MAINNET && req.method !== "GET") return send(res, 410, { ok: false, code: "LEGACY_TESTNET_ONLY", error: "Send campaignId (QuestRewards)." });
  const target = (process.env.TARGET_POST_ID || "").trim();

  if (req.method === "GET") {
    return send(res, 200, {
      ok: true,
      signer: signer?.address ?? null,
      targetConfigured: /^\d+$/.test(target),
      targetPostId: /^\d+$/.test(target) ? target : null,
      rewardDrop: IS_MAINNET ? null : REWARD_DROP,
      questRewards: QUEST_REWARDS,
      chainId: CHAIN_ID,
      usage: "POST {campaignId, postUrl, wallet} for QuestRewards campaigns (see /agent.json). Without campaignId: legacy RewardDrop v2.",
    });
  }
  if (req.method !== "POST") return send(res, 405, { ok: false, error: "Use POST." });
  if (!signer) return send(res, 503, { ok: false, code: "SIGNER_MISSING", error: "Verifier is not configured yet." });
  if (!/^\d+$/.test(target)) return send(res, 503, { ok: false, code: "TARGET_MISSING", error: "The project post to quote has not been announced yet." });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let body: any = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch { body = {}; } }
  const postUrl = String(body?.postUrl ?? "").slice(0, 300);
  const wallet = String(body?.wallet ?? "");
  if (!isAddress(wallet)) return send(res, 400, { ok: false, code: "BAD_WALLET", error: "Invalid wallet address." });
  const user = getAddress(wallet) as Address;
  const parsed = parsePostUrl(postUrl);
  if (!parsed) return send(res, 400, { ok: false, code: "BAD_URL", error: "Paste the full link to your post, like https://x.com/you/status/123…" });

  try {
    // Agent ID is read on-chain; never trust a client-sent handle.
    const [bal, handleRaw] = await Promise.all([
      client.readContract({ address: REGISTRY, abi: registryAbi, functionName: "balanceOf", args: [user] }),
      client.readContract({ address: REGISTRY, abi: registryAbi, functionName: "handleOf", args: [user] }),
    ]);
    const handle = handleRaw.toLowerCase();
    if (bal === 0n || !handle) return send(res, 400, { ok: false, code: "NO_AGENT_ID", error: "This wallet has no Agent ID." });

    const post = await fetchPost(parsed.postId);
    if (!post) return send(res, 404, { ok: false, code: "POST_NOT_FOUND", error: "Post not found. Make sure it is public and not deleted." });
    if (post.id !== parsed.postId || !/^\d+$/.test(post.authorId)) return send(res, 502, { ok: false, code: "BAD_DATA", error: "Could not read the post author." });
    if (post.quotedId !== target) {
      return send(res, 400, { ok: false, code: "NOT_A_QUOTE", error: "This post doesn't quote the project post. Use “Quote” on the announcement, then paste your post's link." });
    }

    const handleHash = keccak256(toBytes(handle));
    const xPostIdHash = keccak256(toBytes(post.id));
    const xAccountIdHash = keccak256(toBytes(post.authorId));
    const [postUsed, accountUsed, can, onchainSigner] = await Promise.all([
      client.readContract({ address: REWARD_DROP, abi: dropAbi, functionName: "isPostUsed", args: [xPostIdHash] }),
      client.readContract({ address: REWARD_DROP, abi: dropAbi, functionName: "isAccountUsed", args: [xAccountIdHash] }),
      client.readContract({ address: REWARD_DROP, abi: dropAbi, functionName: "canClaim", args: [user] }),
      client.readContract({ address: REWARD_DROP, abi: dropAbi, functionName: "signer", args: [] }),
    ]);
    if (postUsed) return send(res, 409, { ok: false, code: "POST_USED", error: "This post was already used for a claim." });
    if (accountUsed) return send(res, 409, { ok: false, code: "ACCOUNT_USED", error: "This X account was already used for a claim." });

    const deadline = BigInt(Math.floor(Date.now() / 1000) + VOUCHER_TTL_SEC);
    const signature = await signer.signTypedData({
      domain: { name: "ProofQuest RewardDrop", version: "1", chainId: CHAIN_ID, verifyingContract: REWARD_DROP },
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
      message: { handleHash, user, xPostIdHash, xAccountIdHash, deadline },
    });

    // Log the submission privately so follow/like checks can run later. Failure here doesn't block the claim.
    if (process.env.BLOB_READ_WRITE_TOKEN) {
      const record = { handle, xUsername: post.username, xUserId: post.authorId, postId: post.id, postUrl, wallet: user, quotedPostId: post.quotedId, postCreatedAt: post.createdAt, verifiedAt: new Date().toISOString(), chainId: CHAIN_ID, rewardDrop: REWARD_DROP };
      await put(`submissions/${CHAIN_ID}/${handle}/${post.id}.json`, JSON.stringify(record), {
        access: "private", contentType: "application/json", addRandomSuffix: false, allowOverwrite: true,
      }).catch((e) => console.error("blob log failed:", e instanceof Error ? e.message : "unknown"));
    }

    return send(res, 200, {
      ok: true,
      handle,
      username: post.username,
      xUserId: post.authorId,
      postId: post.id,
      voucher: { xPostIdHash, xAccountIdHash, deadline: deadline.toString(), signature },
      signer: signer.address,
      onchainSigner,
      signerMatches: onchainSigner.toLowerCase() === signer.address.toLowerCase(),
      canClaim: { ok: can[0], reason: can[1] },
    });
  } catch (e) {
    console.error("verify-quote error:", e instanceof Error ? e.message : "unknown");
    return send(res, 502, { ok: false, code: "UPSTREAM", error: "Verification service is temporarily unavailable. Try again shortly." });
  }
}
