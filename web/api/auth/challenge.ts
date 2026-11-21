// GET /api/auth/challenge?wallet=0x…  → EIP-712 login message for the wallet's owner (or their agent) to sign.
import { getAddress, isAddress, type Address } from "viem";
import { BAW_CHAIN, makeChallenge, send } from "../_lib.js";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export default function handler(req: any, res: any) {
  if (req.method === "OPTIONS") return send(res, 204, {});
  const w = String(req.query?.wallet ?? "");
  if (!isAddress(w)) return send(res, 400, { ok: false, code: "BAD_WALLET", error: "Pass ?wallet=0x… (your own Agentic Wallet address)." });
  const wallet = getAddress(w) as Address;
  const { message, typedData } = makeChallenge(wallet);
  const rpc = JSON.stringify({ method: "eth_signTypedData_v4", params: [wallet, JSON.stringify(typedData)] });
  return send(res, 200, {
    ok: true,
    wallet,
    message,
    typedData,
    howToSign: {
      agenticWallet: {
        preview: `baw sign-message preview --binanceChainId ${BAW_CHAIN} --signType EIP712 --message '${rpc.replace(/'/g, "'\\''")}' --json`,
        execute: "baw sign-message execute --requestId <requestId> --json   (if PENDING_CONFIRMATION: baw sign-message result --order-id <orderId> --json)",
        rule: "Show the owner the parsed message first. It is a read-only login and grants no spending rights.",
      },
      browserWallet: "eth_signTypedData_v4 with the typedData above",
    },
    next: { method: "POST", url: "/api/auth/verify", body: { wallet, message, signature: "<hex>", signatureRecovery: "<optional, Agentic Wallet output>" } },
  });
}
