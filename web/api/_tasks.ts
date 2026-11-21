import { get, list, put } from "@vercel/blob";
import { readSession } from "./_lib.js";

export type TaskType = "follow" | "like" | "retweet" | "quote" | "post";
export type QuestTask = { id: string; type: TaskType; target: string; requiredText?: string };
type TaskProgress = { xHandle?: string; started: Record<string, number>; completed: string[] };
const MAX_TASKS = 10;
const rate = new Map<string, { count: number; reset: number }>();

export function isRateLimited(key: string, max = 30) {
  const now = Date.now();
  const current = rate.get(key);
  if (!current || current.reset < now) { rate.set(key, { count: 1, reset: now + 60_000 }); }
  else current.count += 1;
  if (rate.size > 1000) for (const [entry, value] of rate) if (value.reset < now) rate.delete(entry);
  return (rate.get(key)?.count ?? 0) > max;
}

export function taskSession(req: any) {
  const session = readSession(req.headers?.authorization);
  return session;
}

export function validUrl(raw: unknown) {
  if (typeof raw !== "string" || raw.length > 300) return null;
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || !/^(www\.|mobile\.)?(x|twitter)\.com$/i.test(url.hostname)) return null;
    return url;
  } catch { return null; }
}

export function validateTasks(value: unknown): QuestTask[] | null {
  if (!Array.isArray(value) || value.length > MAX_TASKS) return null;
  const tasks: QuestTask[] = [];
  for (let i = 0; i < value.length; i++) {
    const item = value[i];
    if (!item || typeof item !== "object") return null;
    const type = item.type as TaskType;
    if (!["follow", "like", "retweet", "quote", "post"].includes(type)) return null;
    const target = String(item.target ?? "").trim();
    if (target.length > 300 || !target) return null;
    if (type === "follow") {
      if (!/^@?[A-Za-z0-9_]{1,15}$/.test(target)) return null;
    } else if (!validUrl(target) || !/\/status\/\d{1,25}\/?$/.test(new URL(target).pathname)) return null;
    const requiredText = type === "quote" || type === "post" ? String(item.requiredText ?? "").trim() : undefined;
    if ((type === "quote" || type === "post") && (!requiredText || requiredText.length > 160)) return null;
    tasks.push({ id: `t${i + 1}`, type, target, ...(requiredText ? { requiredText } : {}) });
  }
  return tasks;
}

async function readJson<T>(pathname: string, fallback: T): Promise<T> {
  const found = await list({ prefix: pathname });
  const blob = found.blobs.find((item) => item.pathname === pathname);
  if (!blob) return fallback;
  const result = await get(blob.pathname, { access: "private" });
  if (!result || result.statusCode !== 200) throw new Error("Task data is unavailable.");
  return JSON.parse(await new Response(result.stream).text()) as T;
}

export async function readTasks(campaignId: string): Promise<QuestTask[]> {
  return readJson(`quest-tasks/${campaignId}.json`, []);
}

export async function saveTasks(campaignId: string, tasks: QuestTask[]) {
  await put(`quest-tasks/${campaignId}.json`, JSON.stringify(tasks), { access: "private", contentType: "application/json", addRandomSuffix: false, allowOverwrite: true });
}

export async function readProfile(wallet: string): Promise<{ xHandle?: string }> {
  return readJson(`quest-task-profiles/${wallet.toLowerCase()}.json`, {});
}

export async function saveProfile(wallet: string, profile: { xHandle?: string }) {
  await put(`quest-task-profiles/${wallet.toLowerCase()}.json`, JSON.stringify(profile), { access: "private", contentType: "application/json", addRandomSuffix: false, allowOverwrite: true });
}

export async function readProgress(campaignId: string, wallet: string): Promise<TaskProgress> {
  const [progress, profile] = await Promise.all([
    readJson<TaskProgress>(`quest-task-progress/${campaignId}/${wallet.toLowerCase()}.json`, { started: {}, completed: [] }),
    readProfile(wallet),
  ]);
  return { ...progress, xHandle: profile.xHandle ?? progress.xHandle };
}

export async function saveProgress(campaignId: string, wallet: string, progress: TaskProgress) {
  await put(`quest-task-progress/${campaignId}/${wallet.toLowerCase()}.json`, JSON.stringify(progress), { access: "private", contentType: "application/json", addRandomSuffix: false, allowOverwrite: true });
}

export function campaignId(value: unknown) {
  const id = String(value ?? "");
  return /^\d{1,20}$/.test(id) ? id : null;
}
