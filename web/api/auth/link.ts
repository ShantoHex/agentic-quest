// One-click agent login ("link code"). Adds a flow; /api/auth/challenge and /api/auth/verify are unchanged.
//
//  1. Browser:  POST /api/auth/link {op:"start"}            → {code, pollSecret, expiresAt}
//               code = rand.exp.mac (HMAC, stateless, 10 min). pollSecret = HMAC(code), returned ONLY here,
//               kept in that browser's memory. The agent only ever sees `code`.
//  2. Agent:    GET  /api/auth/link?code=…&wallet=0x…       → the normal EIP-712 login message (same format),
//               with its nonce bound to this code + wallet, plus the exact baw sign command.
//  3. Agent:    POST /api/auth/link {op:"submit", code, wallet, message, signature, signatureRecovery?}
//               → same checks as /api/auth/verify; on success a private Blob record is written once
//               (allowOverwrite:false = single use). No session token is returned to the agent here.
//  4. Browser:  POST /api/auth/link {op:"poll", code, pollSecret} every few seconds
//               → {status:"pending"} … then {status:"done", token, …} exactly once (record is tombstoned).
import { del, get, put } from "@vercel/blob";
import { getAddress, isAddress, type Address } from "viem";
import { randomBytes } from "node:crypto";
import { BAW_CHAIN, body, hmac, LOGIN_TTL_SEC, makeChallenge, makeSession, safeEq, send, SESSION_TTL_SEC, SITE, verifyLogin } from "../_lib.js";

const POLL_MS = 2500;
const parse = (code: string) => {
  const [rand, exp, mac] = String(code || "").split(".");
  if (!rand || !exp || !mac || !/^[A-Za-z0-9_-]{22}$/.test(rand) || !/^\d{10}$/.test(exp)) return null;
  if (!safeEq(mac, hmac(`link|${rand}|${exp}`).slice(0, 22))) return null;
  return { rand, exp: Number(exp) };
};
const pollSecretOf = (code: string) => hmac(`linkpoll|${code}`);
const boundRand = (code: string, wallet: string) => Buffer.from(hmac(`linkbind|${code}|${wallet.toLowerCase()}`), "base64url").toString("hex").slice(0, 24);
const pathOf = (rand: string) => `auth-link/${hmac(`linkpath|${rand}`).slice(0, 32)}.json`;
const now = () => Math.floor(Date.now() / 1000);
const blobOk = () => !!process.env.BLOB_READ_WRITE_TOKEN;

async function readRecord(path: string): Promise<Record<string, unknown> | null> {
  const r = await get(path, { access: "private", useCache: false }).catch(() => null);
  if (!r || r.statusCode !== 200 || !r.stream) return null;
  return JSON.parse(await new Response(r.stream).text());
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export default async function handler(req: any, res: any) {
  if (req.method === "OPTIONS") return send(res, 204, {});
  if (!blobOk()) return send(res, 503, { ok: false, code: "UNAVAILABLE", error: "One-click login is not configured. Use /api/auth/challenge + /api/auth/verify." });

  // Agent step 2: login message bound to this code.
  if (req.method === "GET") {
    const code = String(req.query?.code ?? "");
    const c = parse(code);
    if (!c) return send(res, 400, { ok: false, code: "BAD_CODE", error: "Unknown login code. Ask the user to copy a fresh prompt from the site." });
    if (c.exp < now()) return send(res, 410, { ok: false, code: "EXPIRED", error: "This login code expired. Ask the user to copy a fresh prompt." });
    const w = String(req.query?.wallet ?? "");
    if (!isAddress(w)) return send(res, 400, { ok: false, code: "BAD_WALLET", error: "Add &wallet=0x… (your Agentic Wallet address from: baw wallet status --json)." });
    const wallet = getAddress(w) as Address;
    const { message, typedData } = makeChallenge(wallet, boundRand(code, wallet));
    const rpc = JSON.stringify({ method: "eth_signTypedData_v4", params: [wallet, JSON.stringify(typedData)] });
    return send(res, 200, {
      ok: true, wallet, message, typedData,
      howToSign: {
        agenticWallet: {
          preview: `baw sign-message preview --binanceChainId ${BAW_CHAIN} --signType EIP712 --message '${rpc.replace(/'/g, "'\\''")}' --json`,
          execute: "baw sign-message execute --requestId <requestId> --json   (if PENDING_CONFIRMATION: baw sign-message result --order-id <orderId> --json)",
          rule: "Show the owner the parsed message first. It is a read-only login and grants no spending rights.",
        },
      },
      next: { method: "POST", url: `${SITE}/api/auth/link`, body: { op: "submit", code, wallet, message, signature: "<hex from baw>", signatureRecovery: "<signatureRecovery from baw, if present>" } },
    });
  }
  if (req.method !== "POST") return send(res, 405, { ok: false, error: "Use GET or POST." });
  const b = body(req);
  const op = String(b.op ?? "");

  // Browser step 1.
  if (op === "start") {
    const rand = randomBytes(16).toString("base64url");
    const exp = now() + LOGIN_TTL_SEC;
    const code = `${rand}.${exp}.${hmac(`link|${rand}|${exp}`).slice(0, 22)}`;
    return send(res, 200, { ok: true, code, pollSecret: pollSecretOf(code), expiresAt: exp, pollEveryMs: POLL_MS });
  }

  const code = String(b.code ?? "");
  const c = parse(code);
  if (!c) return send(res, 400, { ok: false, code: "BAD_CODE", error: "Unknown login code." });
  const path = pathOf(c.rand);

  // Agent step 3.
  if (op === "submit") {
    if (c.exp < now()) return send(res, 410, { ok: false, code: "EXPIRED", error: "This login code expired. Ask the user to copy a fresh prompt." });
    const w = String(b.wallet ?? "");
    if (!isAddress(w)) return send(res, 400, { ok: false, code: "BAD_WALLET", error: "Invalid wallet." });
    const wallet = getAddress(w) as Address;
    const m = b.message ?? {};
    if (String(m.nonce ?? "").split(".")[0] !== boundRand(code, wallet))
      return send(res, 400, { ok: false, code: "NOT_BOUND", error: "Sign the message from GET /api/auth/link?code=…&wallet=… for this code." });
    const v = await verifyLogin(wallet, m, b.signature, b.signatureRecovery);
    if (!v.ok) return send(res, v.status, { ok: false, code: v.code, error: v.error });
    try {
      await put(path, JSON.stringify({ wallet, handle: v.handle, at: now() }), {
        access: "private", contentType: "application/json", addRandomSuffix: false, allowOverwrite: false, ttlDays: 1,
      });
    } catch {
      return send(res, 409, { ok: false, code: "USED", error: "This login code was already used. Ask the user to copy a fresh prompt." });
    }
    return send(res, 200, { ok: true, wallet, agentId: v.handle ? `${v.handle}.ai` : null, message: "Signed in. The user's browser will finish logging in automatically within a few seconds." });
  }

  // Browser step 4.
  if (op === "poll") {
    if (!safeEq(String(b.pollSecret ?? ""), pollSecretOf(code))) return send(res, 403, { ok: false, code: "FORBIDDEN", error: "Wrong poll secret." });
    const rec = await readRecord(path);
    if (!rec) return c.exp < now() ? send(res, 410, { ok: false, code: "EXPIRED", error: "Login code expired. Start again." }) : send(res, 200, { ok: true, status: "pending" });
    if (rec.used) return send(res, 410, { ok: false, code: "USED", error: "This login was already completed." });
    // Single use: tombstone first, then issue the session to the secret holder.
    await put(path, JSON.stringify({ used: true, at: now() }), { access: "private", contentType: "application/json", addRandomSuffix: false, allowOverwrite: true, ttlDays: 1 })
      .catch(() => del(path).catch(() => {}));
    const wallet = getAddress(String(rec.wallet)) as Address;
    const handle = String(rec.handle ?? "");
    return send(res, 200, {
      ok: true, status: "done", wallet,
      agentId: handle ? `${handle}.ai` : null, hasAgentId: !!handle,
      token: makeSession(wallet, handle), expiresIn: SESSION_TTL_SEC,
      note: "Read-only token. It cannot move funds or sign transactions.",
    });
  }
  return send(res, 400, { ok: false, code: "BAD_OP", error: 'op must be "start", "submit" or "poll".' });
}
