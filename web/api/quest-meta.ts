// GET /api/quest-meta?campaignId=<id> → { ok, campaignId, description }
// POST /api/quest-meta {campaignId, wallet, description} → saves the quest description (creator only).
// Descriptions are off-chain metadata (the contract stores only the title); same Blob store as quest tasks.
import { get, list, put } from "@vercel/blob";
import { getAddress, isAddress } from "viem";
import { body, client, qrAbi, QUEST_REWARDS, readSession, send } from "./_lib.js";
import { campaignId } from "./_tasks.js";

const MAX_LEN = 500;

async function readDescription(id: string): Promise<string> {
  const pathname = `quest-meta/${id}.json`;
  const found = await list({ prefix: pathname });
  const blob = found.blobs.find((item) => item.pathname === pathname);
  if (!blob) return "";
  const result = await get(blob.pathname, { access: "private" });
  if (!result || result.statusCode !== 200) return "";
  try {
    const j = JSON.parse(await new Response(result.stream).text());
    return typeof j.description === "string" ? j.description : "";
  } catch { return ""; }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export default async function handler(req: any, res: any) {
  if (req.method === "OPTIONS") return send(res, 204, {});
  const id = campaignId(req.query?.campaignId ?? body(req).campaignId);
  if (!id) return send(res, 400, { ok: false, error: "campaignId must be a decimal campaign ID." });
  if (req.method === "GET") return send(res, 200, { ok: true, campaignId: id, description: await readDescription(id) });
  if (req.method !== "POST") return send(res, 405, { ok: false, error: "Use GET or POST." });
  const session = readSession(req.headers?.authorization);
  if (!session) return send(res, 401, { ok: false, error: "Sign in with your wallet first." });
  const b = body(req);
  if (b.wallet && (!isAddress(String(b.wallet)) || getAddress(String(b.wallet)).toLowerCase() !== session.w.toLowerCase())) return send(res, 403, { ok: false, error: "Wallet does not match this session." });
  const description = String(b.description ?? "").trim().slice(0, MAX_LEN);
  try {
    const creator = await client.readContract({ address: QUEST_REWARDS, abi: qrAbi, functionName: "creatorOf", args: [BigInt(id)] });
    if (creator.toLowerCase() !== session.w.toLowerCase()) return send(res, 403, { ok: false, error: "Only the quest creator can edit its description." });
  } catch { return send(res, 404, { ok: false, error: "Campaign not found or chain read failed." }); }
  try {
    await put(`quest-meta/${id}.json`, JSON.stringify({ description }), { access: "private", contentType: "application/json", addRandomSuffix: false, allowOverwrite: true });
    return send(res, 200, { ok: true, campaignId: id, description });
  } catch { return send(res, 502, { ok: false, error: "Could not save the description. Try again shortly." }); }
}
