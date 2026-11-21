// Shared helpers for the Agentic Quest serverless API (files starting with "_" are not routes).
// No wallet sessions that can act for a user, no user keys, no pairing codes: the server only
// (a) verifies signatures a wallet produced itself, (b) signs claim vouchers bound to that
// wallet, and (c) returns unsigned calldata the wallet owner's agent previews and confirms.
import { createHmac, randomBytes, createHash, timingSafeEqual } from "node:crypto";
import { createPublicClient, encodeFunctionData, getAddress, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bsc, bscTestnet } from "viem/chains";
import { pickNetwork } from "./_networks.js";

export const NET = pickNetwork(process.env.NETWORK);
export const CHAIN_ID = NET.chainId;
export const IS_MAINNET = CHAIN_ID === 56;
export const RPC_URL = process.env.RPC_URL || NET.rpc;
const qr = process.env.QUEST_REWARDS_ADDRESS || NET.questRewards;
/** Zero address when not deployed yet on this network (endpoints then answer NOT_DEPLOYED). */
export const QUEST_REWARDS = getAddress(qr || "0x0000000000000000000000000000000000000000");
export const DEPLOYED = !!qr;
export const REWARD_DROP = getAddress(process.env.REWARD_DROP_ADDRESS || "0xeF23c96f73d87c62d16e6672F20B275A30058E2F");
export const REGISTRY = getAddress(process.env.AGENT_ID_REGISTRY || NET.agentIdRegistry);
export const SITE = (process.env.SITE_URL || "https://agentic-quest.vercel.app").replace(/\/$/, "");
/** Agentic Wallet (baw) supports BSC mainnet (binanceChainId 56); it cannot send testnet txs. */
export const BAW_CHAIN = "56";

export const client = createPublicClient({ chain: IS_MAINNET ? bsc : bscTestnet, transport: http(RPC_URL) });

export const registryAbi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "handleOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "string" }] },
] as const;

const campaignTuple = {
  type: "tuple",
  components: [
    { name: "mode", type: "uint8" }, { name: "paused", type: "bool" }, { name: "maxClaims", type: "uint32" },
    { name: "slotsUsed", type: "uint32" }, { name: "settled", type: "uint32" }, { name: "endTime", type: "uint64" },
    { name: "fcfsAmount", type: "uint256" }, { name: "balance", type: "uint256" }, { name: "reserved", type: "uint256" },
    { name: "totalPaid", type: "uint256" }, { name: "targetPostId", type: "string" }, { name: "title", type: "string" },
  ],
} as const;

export const qrAbi = [
  { type: "function", name: "campaignCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "getCampaign", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [campaignTuple] },
  { type: "function", name: "remainingSlots", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "canClaim", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "address" }], outputs: [{ type: "bool" }, { type: "string" }] },
  { type: "function", name: "pendingClaim", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "address" }], outputs: [{ type: "bool" }, { type: "uint64" }, { type: "bytes32" }, { type: "string" }, { type: "bool" }, { type: "bool" }] },
  { type: "function", name: "addressClaimed", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "rewardOfHandle", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "bytes32" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "isPostUsed", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "isAccountUsed", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "bytes32" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "signer", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "token", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "tiers", stateMutability: "view", inputs: [], outputs: [{ type: "uint256[5]" }, { type: "uint8[5]" }] },
  { type: "function", name: "creatorOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] },
  { type: "function", name: "questBlocked", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "creationOpen", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "creatorNeedsAgentId", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "minBudget", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maxFcfsAmount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "createQuest", stateMutability: "nonpayable", inputs: [{ name: "mode", type: "uint8" }, { name: "fcfsAmount", type: "uint256" }, { name: "maxClaims", type: "uint32" }, { name: "endTime", type: "uint64" }, { name: "targetPostId", type: "string" }, { name: "title", type: "string" }, { name: "budget", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "fundCampaign", stateMutability: "nonpayable", inputs: [{ name: "id", type: "uint256" }, { name: "amount", type: "uint256" }], outputs: [] },
  { type: "function", name: "setCampaignPaused", stateMutability: "nonpayable", inputs: [{ name: "id", type: "uint256" }, { name: "p", type: "bool" }], outputs: [] },
  { type: "function", name: "setTargetPost", stateMutability: "nonpayable", inputs: [{ name: "id", type: "uint256" }, { name: "targetPostId", type: "string" }], outputs: [] },
  { type: "function", name: "withdrawCampaignLeftover", stateMutability: "nonpayable", inputs: [{ name: "id", type: "uint256" }, { name: "amount", type: "uint256" }, { name: "to", type: "address" }], outputs: [] },
  { type: "function", name: "claim", stateMutability: "nonpayable", inputs: [{ name: "id", type: "uint256" }, { name: "xPostIdHash", type: "bytes32" }, { name: "xAccountIdHash", type: "bytes32" }, { name: "deadline", type: "uint256" }, { name: "signature", type: "bytes" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "settle", stateMutability: "nonpayable", inputs: [{ name: "id", type: "uint256" }], outputs: [{ type: "uint256" }] },
] as const;

export type Json = Record<string, unknown>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function send(res: any, status: number, body: Json) {
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  res.status(status).send(JSON.stringify(body, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function body(req: any): any {
  let b = req.body;
  if (typeof b === "string") { try { b = JSON.parse(b); } catch { b = {}; } }
  return b ?? {};
}

/** Voucher signer key. Mainnet uses its own dedicated key (never the deployer/owner key, never a testnet key). */
function signerKey(): string {
  return ((IS_MAINNET ? process.env.SIGNER_PRIVATE_KEY_MAINNET : process.env.SIGNER_PRIVATE_KEY) || "").trim();
}
export function signerAccount() {
  const k = signerKey();
  if (!/^0x[0-9a-fA-F]{64}$/.test(k)) return null;
  return privateKeyToAccount(k as Hex);
}

/** HMAC key for stateless login challenges and read-only session tokens. */
function authKey(): Buffer {
  const s = (process.env.AUTH_SECRET || "").trim();
  if (s.length >= 32) return Buffer.from(s);
  // Fallback: domain-separated hash of the voucher key (never exposed, never used to sign tokens directly).
  return createHash("sha256").update("proofquest-auth-v1|" + (signerKey() || "dev-only")).digest();
}
const b64u = (b: Buffer | string) => Buffer.from(b).toString("base64url");
export function hmac(data: string) { return createHmac("sha256", authKey()).update(data).digest("base64url"); }
export function safeEq(a: string, b: string) {
  const x = Buffer.from(a); const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

// ---------------------------------------------------------------- login (EIP-712, SIWE-style)

export const LOGIN_TTL_SEC = 10 * 60;
export const SESSION_TTL_SEC = 24 * 60 * 60;
export const LOGIN_STATEMENT =
  "Sign in to Agentic Quest with this wallet. This is a read-only login: it does not authorize any transaction, transfer or approval.";
export const loginDomain = { name: "Agentic Quest", version: "1", chainId: 56 } as const; // off-chain message; 56 so Agentic Wallet accepts it
export const loginTypes = {
  Login: [
    { name: "wallet", type: "address" },
    { name: "statement", type: "string" },
    { name: "uri", type: "string" },
    { name: "nonce", type: "string" },
    { name: "issuedAt", type: "uint256" },
    { name: "expiresAt", type: "uint256" },
  ],
} as const;

/** `boundRand` (24 hex chars) lets the one-click link flow bind a challenge to its link code; the message format is unchanged. */
export function makeChallenge(wallet: Address, boundRand?: string) {
  const issuedAt = Math.floor(Date.now() / 1000);
  const expiresAt = issuedAt + LOGIN_TTL_SEC;
  const rand = boundRand && /^[0-9a-f]{24}$/.test(boundRand) ? boundRand : randomBytes(12).toString("hex");
  const mac = hmac(`login|${wallet.toLowerCase()}|${issuedAt}|${expiresAt}|${rand}`).slice(0, 22);
  const nonce = `${rand}.${mac}`;
  const message = { wallet, statement: LOGIN_STATEMENT, uri: SITE, nonce, issuedAt: String(issuedAt), expiresAt: String(expiresAt) };
  const typedData = { domain: loginDomain, types: { EIP712Domain: [
    { name: "name", type: "string" }, { name: "version", type: "string" }, { name: "chainId", type: "uint256" },
  ], ...loginTypes }, primaryType: "Login", message };
  return { message, typedData };
}

export function checkChallengeNonce(wallet: Address, m: { nonce: string; issuedAt: string; expiresAt: string }) {
  const [rand, mac] = String(m.nonce).split(".");
  if (!rand || !mac) return "bad nonce";
  const exp = hmac(`login|${wallet.toLowerCase()}|${m.issuedAt}|${m.expiresAt}|${rand}`).slice(0, 22);
  if (!safeEq(mac, exp)) return "nonce was not issued by this site";
  const now = Math.floor(Date.now() / 1000);
  if (Number(m.expiresAt) < now) return "challenge expired, request a new one";
  if (Number(m.expiresAt) - Number(m.issuedAt) !== LOGIN_TTL_SEC) return "bad challenge window";
  return null;
}

/** Accept 65-byte 0x sigs, or Agentic Wallet output (`signature` r||s hex + `signatureRecovery` "00"/"01"). */
export function normalizeSig(sig: string, recovery?: string): Hex | null {
  let s = String(sig || "").trim().toLowerCase().replace(/^0x/, "");
  if (!/^[0-9a-f]+$/.test(s)) return null;
  if (s.length === 128) {
    const r = Number.parseInt(String(recovery ?? "").replace(/^0x/, "") || "NaN", 16);
    if (!(r === 0 || r === 1 || r === 27 || r === 28)) return null;
    s += (r < 27 ? r + 27 : r).toString(16);
  }
  if (s.length !== 130) return s.length > 130 ? (`0x${s}` as Hex) : null; // >65 bytes: contract-wallet (ERC-1271/6492)
  const v = Number.parseInt(s.slice(128), 16);
  if (v === 0 || v === 1) s = s.slice(0, 128) + (v + 27).toString(16);
  return `0x${s}` as Hex;
}

/** Shared login-signature check used by /api/auth/verify and /api/auth/link (same rules, same error codes). */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function verifyLogin(wallet: Address, m: any, signature: unknown, signatureRecovery: unknown):
  Promise<{ ok: true; handle: string } | { ok: false; status: number; code: string; error: string }> {
  if (String(m?.wallet ?? "").toLowerCase() !== wallet.toLowerCase() || m.statement !== LOGIN_STATEMENT || m.uri !== SITE)
    return { ok: false, status: 400, code: "BAD_MESSAGE", error: "Message does not match the challenge. Request a new one." };
  const nonceErr = checkChallengeNonce(wallet, m);
  if (nonceErr) return { ok: false, status: 400, code: "BAD_CHALLENGE", error: nonceErr };
  const sig = normalizeSig(String(signature ?? ""), signatureRecovery as string | undefined);
  if (!sig) return { ok: false, status: 400, code: "BAD_SIGNATURE", error: "Signature must be 65-byte hex, or r||s plus signatureRecovery." };
  try {
    const valid = await client.verifyTypedData({
      address: wallet, domain: loginDomain, types: loginTypes, primaryType: "Login",
      message: { wallet, statement: m.statement, uri: m.uri, nonce: String(m.nonce), issuedAt: BigInt(m.issuedAt), expiresAt: BigInt(m.expiresAt) },
      signature: sig,
    });
    if (!valid) return { ok: false, status: 401, code: "SIGNATURE_MISMATCH", error: "Signature was not made by this wallet." };
    return { ok: true, handle: await agentIdOf(wallet) };
  } catch (e) {
    console.error("auth verify error:", e instanceof Error ? e.message : "unknown");
    return { ok: false, status: 502, code: "UPSTREAM", error: "Could not verify right now. Try again." };
  }
}

export function makeSession(wallet: Address, handle: string) {
  const payload = b64u(JSON.stringify({ w: wallet, h: handle, exp: Math.floor(Date.now() / 1000) + SESSION_TTL_SEC, c: CHAIN_ID }));
  return `${payload}.${hmac("session|" + payload)}`;
}
export function readSession(token?: string): { w: Address; h: string; exp: number } | null {
  if (!token) return null;
  const t = token.replace(/^Bearer\s+/i, "").trim();
  const [p, mac] = t.split(".");
  if (!p || !mac || !safeEq(mac, hmac("session|" + p))) return null;
  try {
    const j = JSON.parse(Buffer.from(p, "base64url").toString());
    if (j.exp < Date.now() / 1000 || j.c !== CHAIN_ID) return null;
    return { w: getAddress(j.w), h: String(j.h), exp: j.exp };
  } catch { return null; }
}

export async function agentIdOf(user: Address): Promise<string> {
  const [bal, h] = await Promise.all([
    client.readContract({ address: REGISTRY, abi: registryAbi, functionName: "balanceOf", args: [user] }),
    client.readContract({ address: REGISTRY, abi: registryAbi, functionName: "handleOf", args: [user] }),
  ]);
  return bal > 0n && h ? h.toLowerCase() : "";
}

// ---------------------------------------------------------------- unsigned tx for the user's own agent

export const erc20Abi = [
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
] as const;

/** Off-chain moderation: quest IDs hidden from listings (comma list in env HIDDEN_QUESTS). Claims are unaffected. */
export const HIDDEN = new Set(String(process.env.HIDDEN_QUESTS || "").split(",").map((x) => x.trim()).filter(Boolean));

export function txFor(from: Address, data: Hex, label: string, toAddr?: Address) {
  const to = toAddr ?? QUEST_REWARDS;
  return {
    label,
    chainId: CHAIN_ID,
    from,
    to,
    value: "0",
    data,
    // Two-step, user-confirmed flow from the official Agentic Wallet skill (Developer Mode required).
    agenticWallet: {
      supportedOnThisNetwork: IS_MAINNET,
      preview: `baw contract-call preview --binanceChainId ${BAW_CHAIN} --from ${from} --to ${to} --value 0 --inputData ${data} --json`,
      execute: "baw contract-call execute --requestId <requestId from preview> --json",
      rule: "Show the owner the parsed transaction and risks from preview and wait for their explicit confirmation before execute.",
      note: IS_MAINNET ? undefined : "This deployment is BSC testnet (97). Agentic Wallet only sends on mainnet; use any testnet wallet/tool you control to send this same calldata.",
    },
    castExample: `cast send ${to} ${data} --rpc-url ${RPC_URL} --account <your-own-keystore>`,
  };
}

export const encodeClaim = (id: bigint, post: Hex, acct: Hex, deadline: bigint, sig: Hex) =>
  encodeFunctionData({ abi: qrAbi, functionName: "claim", args: [id, post, acct, deadline, sig] });
export const encodeSettle = (id: bigint) => encodeFunctionData({ abi: qrAbi, functionName: "settle", args: [id] });

/** Accepts an X post link (https://x.com/u/status/123) or a bare numeric ID. Returns the decimal ID or null. */
export function parsePostRef(raw: unknown): string | null {
  const v = String(raw ?? "").trim();
  if (/^\d{1,25}$/.test(v)) return v;
  let u: URL;
  try { u = new URL(v); } catch { return null; }
  if (u.protocol !== "https:" || !/^(www\.|mobile\.)?(x|twitter)\.com$/i.test(u.hostname)) return null;
  const m = u.pathname.match(/^\/(?:[A-Za-z0-9_]{1,15}|i\/web|i)\/status\/(\d{1,25})\/?$/);
  return m ? m[1] : null;
}

/** Creation rules read live from the contract. */
export async function creationConfig() {
  const c = { address: QUEST_REWARDS, abi: qrAbi } as const;
  const [open, needsAgentId, minBudget, maxFcfs, owner, token] = await Promise.all([
    client.readContract({ ...c, functionName: "creationOpen" }),
    client.readContract({ ...c, functionName: "creatorNeedsAgentId" }),
    client.readContract({ ...c, functionName: "minBudget" }),
    client.readContract({ ...c, functionName: "maxFcfsAmount" }),
    client.readContract({ ...c, functionName: "owner" }),
    client.readContract({ ...c, functionName: "token" }),
  ]);
  const [decimals, symbol] = await Promise.all([
    client.readContract({ address: token, abi: erc20Abi, functionName: "decimals" }),
    client.readContract({ address: token, abi: erc20Abi, functionName: "symbol" }),
  ]);
  return { open, needsAgentId, minBudget, maxFcfs, owner, token, decimals, symbol };
}
