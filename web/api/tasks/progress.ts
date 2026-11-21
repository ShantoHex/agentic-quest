import { getAddress, isAddress } from "viem";
import { body, send } from "../_lib.js";
import { campaignId, isRateLimited, readProgress, readTasks, saveProfile, saveProgress, taskSession } from "../_tasks.js";

export default async function handler(req: any, res: any) {
  if (req.method === "OPTIONS") return send(res, 204, {});
  const session = taskSession(req);
  if (!session) return send(res, 401, { ok: false, error: "Sign in first." });
  const b = body(req);
  const id = campaignId(req.query?.campaignId ?? b.campaignId);
  if (!id) return send(res, 400, { ok: false, error: "Invalid campaignId." });
  if (b.wallet && (!isAddress(String(b.wallet)) || getAddress(String(b.wallet)).toLowerCase() !== session.w.toLowerCase())) return send(res, 403, { ok: false, error: "Wallet does not match this session." });
  if (isRateLimited(`${session.w}:${id}:progress`)) return send(res, 429, { ok: false, error: "Too many task requests. Try again shortly." });
  const [tasks, progress] = await Promise.all([readTasks(id), readProgress(id, session.w)]);
  if (req.method === "GET") return send(res, 200, { ok: true, tasks, xHandle: progress.xHandle ?? null, started: progress.started, completed: progress.completed });
  if (req.method !== "POST") return send(res, 405, { ok: false, error: "Use GET or POST." });
  if (b.action === "link") {
    const handle = String(b.handle ?? "").trim().replace(/^@/, "").toLowerCase();
    if (!/^[a-z0-9_]{1,15}$/.test(handle)) return send(res, 400, { ok: false, error: "Enter a valid X handle." });
    progress.xHandle = handle;
    await Promise.all([saveProfile(session.w, { xHandle: handle }), saveProgress(id, session.w, progress)]);
    return send(res, 200, { ok: true, xHandle: handle, note: "Handle is self-reported; post-task verification checks it against public post data." });
  }
  if (b.action === "unlink") {
    progress.xHandle = undefined;
    await Promise.all([saveProfile(session.w, {}), saveProgress(id, session.w, progress)]);
    return send(res, 200, { ok: true, xHandle: null });
  }
  const task = tasks.find((item) => item.id === b.taskId);
  if (!task) return send(res, 404, { ok: false, error: "Task not found." });
  if (b.action === "start") {
    progress.started[task.id] = Date.now();
    await saveProgress(id, session.w, progress);
    return send(res, 200, { ok: true, startedAt: progress.started[task.id] });
  }
  if (b.action !== "verify") return send(res, 400, { ok: false, error: "action must be link, unlink, start, or verify." });
  if (task.type === "follow" || task.type === "like" || task.type === "retweet") {
    const started = progress.started[task.id];
    if (!started || Date.now() - started < 10_000) return send(res, 409, { ok: false, error: "Click Do it, wait at least 10 seconds, then verify." });
    progress.completed = [...new Set([...progress.completed, task.id])];
    await saveProgress(id, session.w, progress);
    return send(res, 200, { ok: true, selfVerified: true, completed: progress.completed });
  }
  const rawUrl = String(b.postUrl ?? "");
  if (rawUrl.length > 300 || !/^https:\/\/(www\.|mobile\.)?(x|twitter)\.com\//i.test(rawUrl)) return send(res, 400, { ok: false, error: "Provide a valid public X post URL." });
  let parsed: URL;
  try { parsed = new URL(rawUrl); } catch { return send(res, 400, { ok: false, error: "Invalid post URL." }); }
  if (!/^(www\.|mobile\.)?(x|twitter)\.com$/i.test(parsed.hostname) || parsed.protocol !== "https:" || !/\/status\/\d{1,25}\/?$/.test(parsed.pathname)) return send(res, 400, { ok: false, error: "Provide a valid public X post URL." });
  const response = await fetch(`https://publish.twitter.com/oembed?url=${encodeURIComponent(parsed.toString())}&omit_script=true`, { signal: AbortSignal.timeout(8000) }).catch(() => null);
  if (!response?.ok) return send(res, 422, { ok: false, error: "X could not verify this post. Ensure it is public and try again." });
  const data = await response.json().catch(() => null) as { author_url?: string; html?: string } | null;
  const author = data?.author_url?.match(/(?:x|twitter)\.com\/([A-Za-z0-9_]{1,15})/i)?.[1]?.toLowerCase();
  if (!data?.html || !author || author !== progress.xHandle) return send(res, 422, { ok: false, error: "Post author must match your linked X handle." });
  const html = data.html;
  const text = html.replace(/<[^>]*>/g, " ").replace(/&amp;/g, "&").replace(/&#39;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/\s+/g, " ").toLowerCase();
  const contains = task.requiredText!.toLowerCase();
  if (task.type === "post" && !text.includes(contains)) return send(res, 422, { ok: false, error: "Your post does not include the required text." });
  const targetId = task.target.match(/\/status\/(\d+)/)?.[1];
  if (task.type === "quote" && (!targetId || !html.includes(`/status/${targetId}`) || !text.includes(contains))) return send(res, 422, { ok: false, error: "Your post must quote the target post and contain the required text." });
  progress.completed = [...new Set([...progress.completed, task.id])];
  await saveProgress(id, session.w, progress);
  return send(res, 200, { ok: true, selfVerified: false, completed: progress.completed });
}
