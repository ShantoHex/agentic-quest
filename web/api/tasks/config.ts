import { getAddress, isAddress } from "viem";
import { body, qrAbi, QUEST_REWARDS, client, send } from "../_lib.js";
import { campaignId, isRateLimited, readTasks, saveTasks, taskSession, validateTasks, type QuestTask } from "../_tasks.js";

export default async function handler(req: any, res: any) {
  if (req.method === "OPTIONS") return send(res, 204, {});
  const id = campaignId(req.query?.campaignId ?? body(req).campaignId);
  if (!id) return send(res, 400, { ok: false, error: "campaignId must be a decimal campaign ID." });
  const session = taskSession(req);
  const caller = session?.w ?? String(req.headers?.["x-forwarded-for"] ?? "anonymous").split(",")[0].trim();
  if (isRateLimited(`${caller}:config-read`, 60)) return send(res, 429, { ok: false, error: "Too many requests. Try again shortly." });
  if (req.method === "GET") return send(res, 200, { ok: true, tasks: await readTasks(id) });
  if (req.method !== "POST") return send(res, 405, { ok: false, error: "Use GET or POST." });
  if (!session) return send(res, 401, { ok: false, error: "Sign in with your wallet first." });
  if (isRateLimited(`${session.w}:config`, 10)) return send(res, 429, { ok: false, error: "Too many updates. Try again shortly." });
  const b = body(req);
  if (b.wallet && (!isAddress(String(b.wallet)) || getAddress(String(b.wallet)).toLowerCase() !== session.w.toLowerCase())) return send(res, 403, { ok: false, error: "Wallet does not match this session." });
  const tasks = validateTasks(b.tasks);
  if (!tasks) return send(res, 400, { ok: false, error: "Tasks must be valid, with at most 10 tasks and bounded target/text lengths." });
  try {
    const creator = await client.readContract({ address: QUEST_REWARDS, abi: qrAbi, functionName: "creatorOf", args: [BigInt(id)] });
    if (creator.toLowerCase() !== session.w.toLowerCase()) return send(res, 403, { ok: false, error: "Only the quest creator can configure tasks." });
    await saveTasks(id, tasks as QuestTask[]);
    return send(res, 200, { ok: true, campaignId: id, tasks });
  } catch { return send(res, 404, { ok: false, error: "Campaign not found or chain read failed." }); }
}
