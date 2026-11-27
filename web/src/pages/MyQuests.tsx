import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router-dom";
import { parseUnits } from "viem";
import { useConfig } from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { useAgentTx } from "../components/AgentTx";
import { explorerTx } from "../config";
import { fmtAmount, fmtDate, short } from "../lib/format";
import { useTokenInfo, type Camp, type CampResp, type Tx } from "../lib/hooks";
import { useSession } from "../lib/session";
import { isEnded, rewardText, statusBadge, useFmt } from "./Home";

type TaskDraft = { type: "follow" | "like" | "retweet" | "quote" | "post"; target: string; requiredText: string };
type TaskType = TaskDraft["type"];

export function MyQuests() {
  const { session, openSignIn } = useSession();
  const q = useQuery({
    queryKey: ["my-quests", session?.wallet ?? ""],
    enabled: !!session,
    queryFn: async (): Promise<CampResp> => (await fetch(`/api/campaigns?creator=${session!.wallet}`, { headers: { Authorization: `Bearer ${session!.token}` } })).json(),
    refetchInterval: 10000,
  });
  const fmt = useFmt(q.data?.token);
  const list = q.data?.campaigns ?? [];
  if (!session) return (
    <div className="page narrow">
      <p className="crumb"><Link to="/">← All quests</Link></p>
      <section className="panel stack">
        <h2>My quests</h2>
        <p className="small muted">Sign in to see the quests your wallet created.</p>
        <button className="btn btn-primary btn-fit" onClick={() => openSignIn(true)}>Sign in</button>
      </section>
    </div>
  );
  return (
    <div className="page">
      <p className="crumb"><Link to="/">← All quests</Link></p>
      <section className="hero">
        <div className="hero-deco" aria-hidden="true" />
        <p className="eyebrow"><i />Your wallet · {short(session.wallet)}</p>
        <h1 className="hero-title">My <em>quests</em></h1>
        <p className="lede">Every quest this wallet created. Pause or resume it, add funds, withdraw what's left, set its X post, or edit its description and tasks.</p>
      </section>
      {q.isLoading ? <p className="empty">Loading your quests…</p>
        : !q.data?.ok ? <p className="callout">Could not load quests. Try again.</p>
        : list.length === 0 ? (
          <div className="empty empty-quests">
            <p>You haven't published a quest yet</p>
            <Link className="btn btn-primary" to="/publish">Publish a quest</Link>
          </div>
        ) : list.map((c) => <QuestCard key={c.id} c={c} fmt={fmt} token={q.data?.token} />)}
    </div>
  );
}

function QuestCard({ c, fmt, token }: { c: Camp; fmt: (v?: string) => string; token?: `0x${string}` }) {
  const { session } = useSession();
  const config = useConfig();
  const { request } = useAgentTx();
  const qc = useQueryClient();
  const info = useTokenInfo(token);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: "ok" | "err" | "muted"; text: string; hash?: string } | null>(null);
  const [fundAmt, setFundAmt] = useState("");
  const [withdrawAmt, setWithdrawAmt] = useState("");
  const [postUrl, setPostUrl] = useState("");
  const [showPost, setShowPost] = useState(false);
  const [editing, setEditing] = useState(false);
  const [description, setDescription] = useState<string | null>(null);
  const [tasks, setTasks] = useState<TaskDraft[] | null>(null);
  const [editNote, setEditNote] = useState("");

  const unitRaw = c.reward.type === "fixed" ? BigInt(c.reward.amount) : BigInt(c.reward.reservedPerClaim ?? c.reward.tiers[0]?.amount ?? "0");
  const freeRaw = BigInt(c.budget.balance) - BigInt(c.budget.reserved);
  const freeSlots = c.maxClaims - c.slotsUsed;
  const fundSlots = (() => {
    if (!info || !(Number(fundAmt) > 0) || unitRaw <= 0n) return 0;
    try { return Math.min(Number(parseUnits(fundAmt, info.decimals) / unitRaw), freeSlots); } catch { return 0; }
  })();
  const ended = isEnded(c);
  const withdrawable = !c.blocked && (ended || c.paused);
  const freeFormatted = info ? `${fmtAmount(freeRaw, info.decimals)} ${info.symbol}` : fmt(c.budget.balance);

  async function sendTx(tx: Tx) {
    const h = await request({ label: tx.label, from: tx.from, to: tx.to, data: tx.data, value: BigInt(tx.value || "0") });
    if (!h) { qc.invalidateQueries({ queryKey: ["my-quests"] }); return; }
    setMsg({ tone: "muted", text: "Waiting for confirmation…", hash: h });
    const r = await waitForTransactionReceipt(config, { hash: h, timeout: 180_000 }).catch(() => null);
    setMsg(r?.status === "success" ? { tone: "ok", text: "Confirmed.", hash: h } : { tone: "err", text: "Transaction failed or not found.", hash: h });
    qc.invalidateQueries({ queryKey: ["my-quests"] });
  }

  async function manage(action: string, extra: Record<string, string> = {}) {
    if (!session) return;
    setBusy(true); setMsg(null);
    try {
      const r = await fetch("/api/manage", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.token}` }, body: JSON.stringify({ wallet: session.wallet, id: c.id, action, ...extra }) });
      const j = await r.json();
      if (!j.ok) throw new Error(j.error || "Failed.");
      for (const s of j.steps as Tx[]) await sendTx(s);
    } catch (e) { setMsg({ tone: "err", text: e instanceof Error ? e.message : "Failed." }); }
    setBusy(false);
  }

  async function loadEdit() {
    setEditNote("");
    try {
      const [m, t] = await Promise.all([
        (await fetch(`/api/quest-meta?campaignId=${c.id}`)).json(),
        (await fetch(`/api/tasks/config?campaignId=${c.id}`)).json(),
      ]);
      setDescription(m.description ?? "");
      setTasks(((t.tasks ?? []) as { type: TaskType; target: string; requiredText?: string }[]).map((task) => ({ type: task.type, target: task.target ?? "", requiredText: task.requiredText ?? "" })));
    } catch { setEditNote("Could not load the current description and tasks."); }
  }

  async function saveEdit() {
    if (!session) return;
    setBusy(true); setEditNote("");
    try {
      const m = await fetch("/api/quest-meta", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.token}` }, body: JSON.stringify({ campaignId: c.id, wallet: session.wallet, description: description ?? "" }) });
      const mj = await m.json();
      if (!m.ok) throw new Error(mj.error || "Could not save the description.");
      const t = await fetch("/api/tasks/config", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.token}` }, body: JSON.stringify({ campaignId: c.id, wallet: session.wallet, tasks: tasks ?? [] }) });
      const tj = await t.json();
      if (!t.ok) throw new Error(tj.error || "Could not save the tasks.");
      setEditNote("Saved.");
      qc.invalidateQueries({ queryKey: ["quest-meta", c.id] });
    } catch (e) { setEditNote(e instanceof Error ? e.message : "Save failed."); }
    setBusy(false);
  }

  return (
    <section className="panel stack" aria-label={`Quest ${c.id}`}>
      <div className="row-wrap">
        <span className="q-id">#{c.id}</span>
        <h3 className="q-title">{c.title}</h3>
        {statusBadge(c)}
      </div>
      <dl className="hero-stats q-figure">
        <div className="wide"><dt>Reward per claim</dt><dd>{rewardText(c, fmt)}</dd></div>
        <div><dt>Claims</dt><dd>{c.slotsUsed}/{c.maxClaims}</dd></div>
        <div><dt>Slots left</dt><dd>{c.remainingSlots}</dd></div>
        <div><dt>Funds left</dt><dd>{fmt(c.budget.balance)}</dd></div>
        <div><dt>Total paid</dt><dd>{fmt(c.budget.totalPaid)}</dd></div>
        <div className="date"><dt>Ends</dt><dd>{c.endTime ? fmtDate(c.endTime) : "No end date"}</dd></div>
      </dl>
      <p className="small muted">
        {c.targetPostId ? <>X post set: <a href={c.targetPostUrl ?? ""} target="_blank" rel="noreferrer">view post ↗</a></> : "No X post set — claims are open with no quote step."}
        {c.slotsUsed > 0 && " The post can only be changed before the first claim (contract limit)."}
      </p>
      <div className="row-wrap">
        <Link className="btn btn-sm btn-secondary" to={`/q/${c.id}`}>View quest ↗</Link>
        <button className="btn btn-sm btn-secondary" disabled={busy} onClick={() => manage(c.paused ? "resume" : "pause")}>{c.paused ? "Resume" : "Pause"}</button>
        {c.slotsUsed === 0 && <button className="btn btn-sm btn-secondary" disabled={busy} onClick={() => setShowPost((s) => !s)}>{showPost ? "Cancel" : "Set X post"}</button>}
        <button className="btn btn-sm btn-secondary" disabled={busy} onClick={() => { setEditing((e) => !e); if (!editing) loadEdit(); }}>{editing ? "Close editor" : "Edit description & tasks"}</button>
      </div>
      {showPost && c.slotsUsed === 0 && (
        <div className="row-wrap">
          <label className="field"><span className="field-label">X post to quote</span><input value={postUrl} onChange={(e) => setPostUrl(e.target.value)} placeholder="https://x.com/you/status/…" /></label>
          <button className="btn btn-sm btn-primary" disabled={busy || !/\/status\/\d{1,25}/.test(postUrl)} onClick={() => { setShowPost(false); manage("setPost", { postUrl }); }}>Save X post</button>
        </div>
      )}
      <div className="row-wrap">
        <label className="field"><span className="field-label">Add funds, USDT</span><input inputMode="decimal" value={fundAmt} onChange={(e) => setFundAmt(e.target.value)} placeholder="1" /></label>
        <button className="btn btn-sm btn-primary" disabled={busy || !(Number(fundAmt) > 0)} onClick={() => manage("fund", { amount: fundAmt })}>Add funds</button>
      </div>
      {fundAmt && Number(fundAmt) > 0 && (
        <p className="small muted">
          {fundSlots > 0 ? `Adds about ${fundSlots} claim slot${fundSlots === 1 ? "" : "s"} (one per reward paid).` : "Adds funds but no new slots."}
          {freeSlots <= 0 ? " This quest is at its max of " + c.maxClaims + " slots — extra funds can't open more slots." : fundSlots >= freeSlots && freeSlots > 0 ? ` Slots are capped at the quest's max of ${c.maxClaims}.` : ""}
        </p>
      )}
      <div className="row-wrap">
        <label className="field"><span className="field-label">Withdraw, USDT</span><input inputMode="decimal" value={withdrawAmt} onChange={(e) => setWithdrawAmt(e.target.value)} placeholder={freeFormatted} /></label>
        <button className="btn btn-sm btn-secondary" disabled={busy || !withdrawable} onClick={() => manage("withdraw", withdrawAmt.trim() ? { amount: withdrawAmt.trim() } : {})}>Withdraw leftover</button>
      </div>
      {!withdrawable && <p className="small muted">Withdraw works after the quest ends, or while it is paused. {freeFormatted} is free to withdraw (reserved funds for pending claims can't be withdrawn).</p>}
      {editing && (
        <div className="stack">
          <label className="field"><span className="field-label">Description</span><textarea maxLength={500} value={description ?? ""} onChange={(e) => setDescription(e.target.value)} placeholder="What should claimers do, and why?" rows={3} /></label>
          <p className="small muted">The title is fixed on-chain at creation — changing it needs a contract update. The description and tasks below are off-chain and can be edited any time.</p>
          <div className="row-wrap"><h2 className="section-label">X tasks</h2><button type="button" className="btn btn-sm btn-secondary" disabled={(tasks?.length ?? 0) >= 10} onClick={() => setTasks([...(tasks ?? []), { type: "follow", target: "", requiredText: "" }])}>Add task</button></div>
          {(tasks ?? []).map((task, index) => <div className="task-row stack" key={index}>
            <label className="field"><span className="field-label">Task type</span><select value={task.type} onChange={(e) => setTasks((tasks ?? []).map((item, i) => i === index ? { ...item, type: e.target.value as TaskType, target: "", requiredText: "" } : item))}><option value="follow">Follow an X account</option><option value="like">Like a post</option><option value="retweet">Retweet a post</option><option value="quote">Quote a post</option><option value="post">Post required text</option></select></label>
            {task.type !== "post" && <label className="field"><span className="field-label">{task.type === "follow" ? "X handle" : "Target X post URL"}</span><input maxLength={300} value={task.target} onChange={(e) => setTasks((tasks ?? []).map((item, i) => i === index ? { ...item, target: e.target.value } : item))} placeholder={task.type === "follow" ? "@account" : "https://x.com/account/status/…"} /></label>}
            {(task.type === "post" || task.type === "quote") && <label className="field"><span className="field-label">Required hashtag or text</span><input maxLength={160} value={task.requiredText} onChange={(e) => setTasks((tasks ?? []).map((item, i) => i === index ? { ...item, requiredText: e.target.value } : item))} placeholder="#AgenticQuest" /></label>}
            <button type="button" className="btn btn-sm btn-secondary" onClick={() => setTasks((tasks ?? []).filter((_, i) => i !== index))}>Remove task</button>
          </div>)}
          <button className="btn btn-primary btn-fit" disabled={busy} onClick={saveEdit}>{busy ? "Saving…" : "Save description & tasks"}</button>
          {editNote && <p role="status" className="small muted">{editNote}</p>}
        </div>
      )}
      {msg && <p className={`field-msg ${msg.tone}`}>{msg.text}{msg.hash && <> · <a href={explorerTx(msg.hash)} target="_blank" rel="noreferrer">tx ↗</a></>}</p>}
    </section>
  );
}
