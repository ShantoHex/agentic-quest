// POST /api/auth/verify {wallet, message, signature, signatureRecovery?} → read-only session token.
// The token only identifies the wallet to this API (e.g. to list its claim status). It cannot sign or
// send anything; every on-chain action is still signed and confirmed by the wallet owner.
import { getAddress, isAddress, type Address } from "viem";
import { body, makeSession, send, SESSION_TTL_SEC, verifyLogin } from "../_lib.js";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export default async function handler(req: any, res: any) {
  if (req.method === "OPTIONS") return send(res, 204, {});
  if (req.method !== "POST") return send(res, 405, { ok: false, error: "Use POST." });
  const b = body(req);
  const w = String(b.wallet ?? "");
  if (!isAddress(w)) return send(res, 400, { ok: false, code: "BAD_WALLET", error: "Invalid wallet." });
  const wallet = getAddress(w) as Address;
  const v = await verifyLogin(wallet, b.message ?? {}, b.signature, b.signatureRecovery);
  if (!v.ok) return send(res, v.status, { ok: false, code: v.code, error: v.error });
  return send(res, 200, {
    ok: true,
    wallet,
    agentId: v.handle ? `${v.handle}.ai` : null,
    hasAgentId: !!v.handle,
    token: makeSession(wallet, v.handle),
    expiresIn: SESSION_TTL_SEC,
    note: "Read-only token. It cannot move funds or sign transactions.",
  });
}
