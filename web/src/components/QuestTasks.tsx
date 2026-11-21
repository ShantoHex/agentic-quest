import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import type { Session } from "../lib/session";

type QuestTask = { id: string; type: "follow" | "like" | "retweet" | "quote" | "post"; target: string; requiredText?: string };
type TaskState = { tasks: QuestTask[]; xHandle: string | null; completed: string[] };

export function useQuestTaskState(campaignId: string, session: Session | null) {
  return useQuery({
    queryKey: ["quest-tasks", campaignId, session?.wallet],
    enabled: !!campaignId,
    queryFn: async (): Promise<TaskState> => {
      const configRes = await fetch(`/api/tasks/config?campaignId=${campaignId}`);
      const config = await configRes.json();
      if (!configRes.ok) throw new Error(config.error || "Could not load tasks.");
      if (!session) return { tasks: config.tasks ?? [], xHandle: null, completed: [] };
      const progressRes = await fetch(`/api/tasks/progress?campaignId=${campaignId}`, { headers: { Authorization: `Bearer ${session.token}` } });
      const progress = await progressRes.json();
      if (!progressRes.ok) throw new Error(progress.error || "Could not load task progress.");
      return { tasks: config.tasks ?? [], xHandle: progress.xHandle, completed: progress.completed ?? [] };
    },
  });
}

export function QuestTasks({ campaignId, session }: { campaignId: string; session: Session | null }) {
  const cache = useQueryClient();
  const [handle, setHandle] = useState("");
  const [editing, setEditing] = useState(false);
  const [postUrls, setPostUrls] = useState<Record<string, string>>({});
  const [notice, setNotice] = useState("");
  const state = useQuestTaskState(campaignId, session);
  if (!state.data?.tasks.length) return null;
  const completed = new Set(state.data.completed);

  async function action(payload: Record<string, string>) {
    const result = await fetch("/api/tasks/progress", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session!.token}` }, body: JSON.stringify({ campaignId, ...payload }) });
    const json = await result.json();
    if (!result.ok) throw new Error(json.error || "Task request failed.");
    await cache.invalidateQueries({ queryKey: ["quest-tasks", campaignId, session?.wallet] });
    return json;
  }

  async function start(task: QuestTask) {
    let intent = "https://x.com/intent/tweet";
    if (task.type === "follow") intent = `https://x.com/intent/follow?screen_name=${encodeURIComponent(task.target.replace(/^@/, ""))}`;
    if (["like", "retweet"].includes(task.type)) {
      const tweetId = task.target.match(/\/status\/(\d+)/)?.[1] ?? "";
      intent = `https://x.com/intent/${task.type}?tweet_id=${tweetId}`;
    }
    if (task.type === "quote") intent = `https://x.com/intent/tweet?url=${encodeURIComponent(task.target)}&text=${encodeURIComponent(task.requiredText ?? "")}`;
    if (task.type === "post") intent = `https://x.com/intent/tweet?text=${encodeURIComponent(task.requiredText ?? "")}`;
    window.open(intent, "_blank", "noopener,noreferrer");
    try { await action({ action: "start", taskId: task.id }); setNotice("Task started. You can verify after 10 seconds."); }
    catch (e) { setNotice(e instanceof Error ? e.message : "Could not start task."); }
  }

  async function verify(task: QuestTask) {
    try {
      await action({ action: "verify", taskId: task.id, ...(postUrls[task.id] ? { postUrl: postUrls[task.id] } : {}) });
      setNotice(task.type === "follow" || task.type === "like" || task.type === "retweet" ? "Marked self-verified." : "Post verified.");
    } catch (e) { setNotice(e instanceof Error ? e.message : "Verification failed."); }
  }

  async function linkHandle() {
    try { await action({ action: "link", handle }); setEditing(false); setNotice("X handle linked."); }
    catch (e) { setNotice(e instanceof Error ? e.message : "Could not link handle."); }
  }

  async function unlinkHandle() {
    try { await action({ action: "unlink" }); setHandle(""); setEditing(false); setNotice("X handle unlinked."); }
    catch (e) { setNotice(e instanceof Error ? e.message : "Could not unlink handle."); }
  }

  if (!session) return <section className="panel stack"><h2>Quest tasks</h2><p className="small muted">Sign in to track task progress before claiming.</p></section>;
  if (state.isLoading) return <section className="panel stack"><h2>Quest tasks</h2><p className="small muted">Loading task checklist…</p></section>;
  if (state.isError) return <section className="panel stack"><h2>Quest tasks</h2><p className="small err">{state.error.message}</p></section>;

  return <section className="panel stack" aria-labelledby="task-heading">
    <h2 id="task-heading">Quest tasks</h2>
    <p className="small muted">Finish every required task to unlock claiming. Follow, like, and retweet checks are self-verified.</p>
    {(!state.data.xHandle || editing) ? <div className="row-wrap"><label className="field"><span className="field-label">Your X handle</span><input value={handle} maxLength={16} onChange={(e) => setHandle(e.target.value)} placeholder="@yourhandle" /></label><button className="btn btn-secondary btn-fit" onClick={linkHandle} disabled={!handle.trim()}>{state.data.xHandle ? "Save handle" : "Link handle"}</button>{editing ? <button className="btn btn-sm btn-secondary" onClick={() => { setEditing(false); setHandle(""); }}>Cancel</button> : null}</div>
      : <div className="row-wrap"><p className="small muted">Linked X handle: <strong>@{state.data.xHandle}</strong> · self-reported</p><button className="btn btn-sm btn-secondary" onClick={() => { setHandle(state.data.xHandle ?? ""); setEditing(true); }}>Change</button><button className="btn btn-sm btn-secondary" onClick={unlinkHandle}>Unlink</button></div>}
    <ul className="stack">
      {state.data.tasks.map((task) => <li className="task-row" key={task.id}>
        <div className="row-wrap task-heading"><strong>{task.type === "post" ? "Post" : task.type[0].toUpperCase() + task.type.slice(1)} on X</strong><span className={`small ${completed.has(task.id) ? "ok" : "muted"}`}>{completed.has(task.id) ? "Complete" : task.type === "follow" || task.type === "like" || task.type === "retweet" ? "Self-verified" : "Needs verification"}</span></div>
        <p className="small muted">{task.type === "follow" ? `Follow @${task.target.replace(/^@/, "")}` : task.type === "post" ? task.requiredText : `${task.target}${task.requiredText ? ` · include “${task.requiredText}”` : ""}`}</p>
        {task.type === "quote" || task.type === "post" ? <label className="field"><span className="field-label">Your X post URL</span><input type="url" maxLength={300} value={postUrls[task.id] ?? ""} onChange={(e) => setPostUrls({ ...postUrls, [task.id]: e.target.value })} placeholder="https://x.com/you/status/…" /></label> : null}
        <div className="row-wrap"><button className="btn btn-sm btn-secondary" disabled={completed.has(task.id)} onClick={() => start(task)}>Do it ↗</button><button className="btn btn-sm btn-primary" disabled={completed.has(task.id) || ((task.type === "quote" || task.type === "post") && !postUrls[task.id])} onClick={() => verify(task)}>Verify</button></div>
      </li>)}
    </ul>
    {notice && <p role="status" className="small muted">{notice}</p>}
    <p className="small muted">X handle linking is self-reported. Post tasks are checked against X&apos;s public embed data.</p>
  </section>;
}
