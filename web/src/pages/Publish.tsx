import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router-dom";
import { useConfig } from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { Copy, useAgentTx } from "../components/AgentTx";
import { explorerTx } from "../config";
import { useSession } from "../lib/session";
import type { Tx } from "../lib/hooks";

type Rules = { tokenSymbol: string; minBudget: string; minRewardPerClaim: string; creatorNeedsAgentId: boolean; creationOpen: boolean };
type TierDraft = { amount: string; chance: string };

const MAX_TIERS = 5;
const DEFAULT_TIERS: TierDraft[] = [{ amount: "", chance: "30" }, { amount: "", chance: "50" }, { amount: "", chance: "20" }];
const num = (v: string) => (/^\d+(\.\d+)?$/.test(v.trim()) ? Number(v) : NaN);
type TaskType = "follow" | "like" | "retweet" | "quote" | "post";
type TaskDraft = { type: TaskType; target: string; requiredText: string };

const SITE = typeof window !== "undefined" ? window.location.origin : "https://agentic-quest.vercel.app";

export function Publish() {
  const { session, openSignIn } = useSession();
  const config = useConfig();
  const { request } = useAgentTx();
  const rules = useQuery({ queryKey: ["publish-rules"], queryFn: async () => (await fetch("/api/publish")).json() as Promise<{ ok: boolean; rules?: Rules; error?: string }> });
  const r = rules.data?.rules;
  const [f, setF] = useState({ title: "", mode: "FCFS", rewardPerClaim: "0.10", maxClaims: "10", budget: "1", postUrl: "", durationDays: "7" });
  const [tiers, setTiers] = useState<TierDraft[]>(DEFAULT_TIERS);
  const setTier = (i: number, k: keyof TierDraft, v: string) => setTiers(tiers.map((t, j) => (j === i ? { ...t, [k]: v } : t)));
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: "ok" | "err" | "muted"; text: string; hash?: string } | null>(null);
  const [warnings, setWarnings] = useState<string[]>([]);
  const [tasks, setTasks] = useState<TaskDraft[]>([]);

  const minReward = Number(r?.minRewardPerClaim ?? "0.05");
  const minBudget = Number(r?.minBudget ?? "0.1");
  const isRandom = f.mode === "RANDOM";
  const chanceSum = tiers.reduce((s, t) => s + (Number.isInteger(Number(t.chance)) ? Number(t.chance) : 0), 0);
  const unit = isRandom ? Math.max(0, ...tiers.map((t) => num(t.amount) || 0)) : num(f.rewardPerClaim) || 0;
  const budgetN = num(f.budget);
  const formError = (() => {
    if (!isRandom) {
      if (!(num(f.rewardPerClaim) >= minReward)) return `Reward per claim must be at least ${minReward}.`;
    } else {
      if (tiers.length < 1 || tiers.length > MAX_TIERS) return `Use 1 to ${MAX_TIERS} reward tiers.`;
      for (const [i, t] of tiers.entries()) {
        if (!(num(t.amount) >= minReward)) return `Tier ${i + 1}: enter an amount of at least ${minReward}.`;
        const c = Number(t.chance);
        if (!Number.isInteger(c) || c < 1 || c > 100) return `Tier ${i + 1}: chance must be a whole number from 1 to 100.`;
      }
      if (chanceSum !== 100) return `Chances must add up to 100% (now ${chanceSum}%).`;
    }
    const mc = Number(f.maxClaims);
    if (!Number.isInteger(mc) || mc < 1 || mc > 1_000_000) return "Max claims must be a whole number from 1 to 1,000,000.";
    if (!(budgetN >= minBudget)) return `Budget must be at least ${minBudget}.`;
    if (budgetN < unit) return `Budget must cover at least one claim (${unit}${isRandom ? ", the largest tier" : ""}).`;
    return null;
  })();
  const coveredClaims = unit > 0 && budgetN > 0 ? Math.floor(budgetN / unit + 1e-9) : 0;

  const payload = {
    wallet: session?.wallet ?? "<my Agentic Wallet address>",
    title: f.title || "<title>", mode: f.mode,
    ...(isRandom ? { tiers: tiers.map((t) => ({ amount: t.amount || "<amount>", chancePct: Number(t.chance) })) } : { rewardPerClaim: f.rewardPerClaim }),
    maxClaims: Number(f.maxClaims), budget: f.budget, postUrl: f.postUrl || undefined, durationDays: Number(f.durationDays),
  };
  const prompt = [
    `Publish a quest on Agentic Quest (${SITE}) with my Agentic Wallet. Read ${SITE}/llms.txt first.`,
    `POST ${SITE}/api/publish with JSON: ${JSON.stringify(payload)}`,
    `For each returned step, in order: run its agenticWallet.preview command, show me the parsed transaction and risks, and WAIT for my explicit "yes" before running execute.`,
    `The approve must be for exactly the budget (never unlimited). Never ask me for keys, seed phrases or pairing codes.`,
  ].join("\n");

  async function prepareAndSend() {
    if (!session) return;
    setBusy(true); setMsg(null); setWarnings([]);
    try {
      const res = await fetch("/api/publish", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.token}` }, body: JSON.stringify({ ...payload, wallet: session.wallet }) });
      const j = await res.json();
      if (!j.ok) throw new Error(j.error || "Could not prepare the quest.");
      setWarnings(j.warnings ?? []);
      for (const s of j.steps as (Tx & { step: number })[]) {
        const h = await request({ label: `Step ${s.step}: ${s.label}`, from: s.from, to: s.to, data: s.data, value: BigInt(s.value || "0") });
        if (!h) { setMsg({ tone: "muted", text: `Stopped at step ${s.step}.` }); setBusy(false); return; }
        setMsg({ tone: "muted", text: `Step ${s.step}: waiting for confirmation…`, hash: h });
        const rc = await waitForTransactionReceipt(config, { hash: h, timeout: 180_000 }).catch(() => null);
        if (rc?.status !== "success") throw new Error(`Step ${s.step} failed or was not found.`);
      }
      // The X post claimers must quote: from the field above, or (fallback) the target
      // of the first "quote" task. /api/publish already stores it on-chain in createQuest
      // when it is sent; this step only fires when the quest still has no post set, and
      // saves it under the now-known quest ID in the same place Manage → Set X post
      // writes it (contract setTargetPost), so claims open right away.
      const quoteTaskPost = tasks.find((t) => t.type === "quote" && /\/status\/\d{1,25}/.test(t.target))?.target ?? "";
      const launchPost = f.postUrl.trim() || quoteTaskPost.trim();
      let postNote = "";
      if (tasks.length || launchPost) {
        const listed = await fetch(`/api/campaigns?creator=${session.wallet}`);
        const campaigns = await listed.json();
        const created = (campaigns.campaigns ?? []).find((campaign: { creator: string; title: string; targetPostId?: string | null }) => campaign.creator.toLowerCase() === session.wallet.toLowerCase() && campaign.title === f.title);
        if (!created) {
          if (tasks.length) throw new Error("Quest was published, but its task definitions could not be attached. Open the quest and retry setup with its campaign ID.");
          postNote = " The X post could not be attached automatically — set it from the quest page (Manage → Set X post).";
        } else {
          if (tasks.length) {
            const saved = await fetch("/api/tasks/config", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.token}` }, body: JSON.stringify({ campaignId: created.id, wallet: session.wallet, tasks }) });
            const savedResult = await saved.json();
            if (!saved.ok) throw new Error(savedResult.error || "Quest published, but task setup could not be saved.");
          }
          if (launchPost && !created.targetPostId) {
            const mr = await fetch("/api/manage", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.token}` }, body: JSON.stringify({ wallet: session.wallet, id: created.id, action: "setPost", postUrl: launchPost }) });
            const mj = await mr.json();
            if (!mj.ok) {
              postNote = " The X post could not be attached automatically — set it from the quest page (Manage → Set X post).";
            } else {
              let attached = true;
              for (const s of mj.steps as (Tx & { step: number })[]) {
                const h = await request({ label: `Set X post: ${s.label}`, from: s.from, to: s.to, data: s.data, value: BigInt(s.value || "0") });
                if (!h) { attached = false; break; }
                setMsg({ tone: "muted", text: "Setting the X post: waiting for confirmation…", hash: h });
                const rc = await waitForTransactionReceipt(config, { hash: h, timeout: 180_000 }).catch(() => null);
                if (rc?.status !== "success") { attached = false; break; }
              }
              postNote = attached ? " X post attached — claims are open." : " The X post was not attached — set it from the quest page (Manage → Set X post).";
            }
          } else if (launchPost && created.targetPostId) {
            postNote = " X post attached — claims are open.";
          }
        }
      }
      setMsg({ tone: "ok", text: "Quest published" + (tasks.length ? " with required X tasks." : ". It appears on the quest list in a few seconds.") + postNote });
    } catch (e) { setMsg({ tone: "err", text: e instanceof Error ? e.message : "Failed." }); }
    setBusy(false);
  }

  return (
    <div className="page">
      <p className="crumb"><Link to="/">← All quests</Link></p>
      <section className="hero">
      <div className="hero-deco" aria-hidden="true" />
      <p className="eyebrow"><i />Anyone with an Agent ID</p>
      <h1 className="hero-title">Publish <em>a quest</em></h1>
      <p className="lede">
        Fund a small USDT reward for Agent ID holders who quote your X post. Your agent prepares two transactions with your Agentic Wallet:
        approve exactly your budget, then create and fund the quest. You confirm both. You can pause your quest and withdraw the unused
        budget after it ends (or while paused). No platform fee.
      </p>
      </section>
      {r && (
        <ul className="rules panel" aria-label="Publishing rules">
          <li><span>Budget</span><span>min {r.minBudget} {r.tokenSymbol}, no max</span></li>
          <li><span>Reward per claim</span><span>min {r.minRewardPerClaim}, no max</span></li>
          <li><span>Random tiers</span><span>1–5, chances total 100%</span></li>
          <li><span>Creator needs an Agent ID</span><span>{r.creatorNeedsAgentId ? "yes" : "no"}</span></li>
          <li><span>Publishing</span><span>{r.creationOpen ? "open" : "closed"}</span></li>
          <li><span>Platform fee</span><span>0</span></li>
        </ul>
      )}
      <div className="stack-lg panel form-panel">
        <label className="field"><span className="field-label">Title</span><input maxLength={120} value={f.title} onChange={set("title")} placeholder="Quote our launch post" /></label>
        <label className="field"><span className="field-label">X post to quote</span><input value={f.postUrl} onChange={set("postUrl")} placeholder="https://x.com/you/status/… (can be set later)" /></label>
        <div className="field-row two">
          <label className="field"><span className="field-label">Mode</span>
            <select value={f.mode} onChange={set("mode")}><option value="FCFS">First come</option><option value="RANDOM">Random</option></select></label>
          {!isRandom && <label className="field"><span className="field-label">Reward per claim</span><input inputMode="decimal" value={f.rewardPerClaim} onChange={set("rewardPerClaim")} /><span className="field-hint">Min {r?.minRewardPerClaim ?? "0.05"}, no max</span></label>}
        </div>
        {isRandom && (
          <section className="tiers stack" aria-labelledby="tiers-heading">
            <div className="row-wrap"><h2 id="tiers-heading" className="section-label">Reward tiers</h2>
              <button type="button" className="btn btn-sm btn-secondary" disabled={tiers.length >= MAX_TIERS} onClick={() => setTiers([...tiers, { amount: "", chance: "" }])}>Add tier</button></div>
            <p className="small muted">Each claimer gets one of these amounts at random. Default chances are 30%, 50% and 20%; you can change them.</p>
            <div className="tier-head" aria-hidden="true"><span>Amount, USDT</span><span>Chance</span><span /></div>
            {tiers.map((t, i) => (
              <div className="tier-row" key={i}>
                <label className="field"><span className="sr-only">Tier {i + 1} amount</span><input inputMode="decimal" value={t.amount} placeholder={["0.05", "0.10", "0.50", "1", "2"][i] ?? "0.05"} onChange={(e) => setTier(i, "amount", e.target.value)} /></label>
                <label className="field tier-chance"><span className="sr-only">Tier {i + 1} chance</span><input inputMode="numeric" value={t.chance} onChange={(e) => setTier(i, "chance", e.target.value.replace(/[^0-9]/g, ""))} /><i aria-hidden="true">%</i></label>
                <button type="button" className="btn btn-sm btn-ghost tier-x" aria-label={`Remove tier ${i + 1}`} disabled={tiers.length <= 1} onClick={() => setTiers(tiers.filter((_, j) => j !== i))}>✕</button>
              </div>
            ))}
            <p className="field-hint">Min {r?.minRewardPerClaim ?? "0.05"}, no max · Chances total <strong className={chanceSum === 100 ? "ok" : "err"}>{chanceSum}%</strong>{chanceSum !== 100 && " (must be 100%)"}</p>
            <button type="button" className="btn btn-sm btn-ghost btn-fit" onClick={() => setTiers(tiers.length === 3 ? tiers.map((t, i) => ({ ...t, chance: DEFAULT_TIERS[i].chance })) : DEFAULT_TIERS)}>Reset chances to 30 / 50 / 20</button>
          </section>
        )}
        <div className="field-row two">
          <label className="field"><span className="field-label">Max claims</span><input inputMode="numeric" value={f.maxClaims} onChange={set("maxClaims")} /></label>
          <label className="field"><span className="field-label">Budget, USDT</span><input inputMode="decimal" value={f.budget} onChange={set("budget")} /><span className="field-hint">Min {r?.minBudget ?? "0.1"}, no max</span></label>
        </div>
        <label className="field"><span className="field-label">Duration (days)</span><input inputMode="numeric" value={f.durationDays} onChange={set("durationDays")} /></label>
        {unit > 0 && budgetN > 0 && !formError && <p className="small muted">{isRandom ? `The largest tier (${unit}) is held for each pending claim. ` : ""}Your budget covers {coveredClaims.toLocaleString()} of {Number(f.maxClaims).toLocaleString()} claims.</p>}
        <p className="small muted">Enter the X post claimers must quote above — it is saved with the quest, and claims open once it's set. You can also add or change it later from your quest page (Manage → Set X post).</p>

        <section className="stack" aria-labelledby="optional-tasks-heading">
          <div className="row-wrap"><h2 id="optional-tasks-heading" className="section-label">Optional X tasks</h2><button type="button" className="btn btn-sm btn-secondary" disabled={tasks.length >= 10} onClick={() => setTasks([...tasks, { type: "follow", target: "", requiredText: "" }])}>Add task</button></div>
          <p className="small muted">Tasks are saved after your quest is confirmed on-chain. Like, follow, and retweet tasks use an honest self-verification flow.</p>
          {tasks.map((task, index) => <div className="task-row stack" key={index}>
            <label className="field"><span className="field-label">Task type</span><select value={task.type} onChange={(e) => setTasks(tasks.map((item, i) => i === index ? { ...item, type: e.target.value as TaskType, target: "", requiredText: "" } : item))}><option value="follow">Follow an X account</option><option value="like">Like a post</option><option value="retweet">Retweet a post</option><option value="quote">Quote a post</option><option value="post">Post required text</option></select></label>
            {task.type !== "post" && <label className="field"><span className="field-label">{task.type === "follow" ? "X handle" : "Target X post URL"}</span><input maxLength={300} value={task.target} onChange={(e) => setTasks(tasks.map((item, i) => i === index ? { ...item, target: e.target.value } : item))} placeholder={task.type === "follow" ? "@account" : "https://x.com/account/status/…"} /></label>}
            {(task.type === "post" || task.type === "quote") && <label className="field"><span className="field-label">Required hashtag or text</span><input maxLength={160} value={task.requiredText} onChange={(e) => setTasks(tasks.map((item, i) => i === index ? { ...item, requiredText: e.target.value } : item))} placeholder="#AgenticQuest" /></label>}
            <button type="button" className="btn btn-sm btn-secondary" onClick={() => setTasks(tasks.filter((_, i) => i !== index))}>Remove task</button>
          </div>)}
        </section>

        <div className="stack">
          <span className="section-label">Send this to your AI agent</span>
          <pre className="prompt">{prompt}</pre>
          <Copy text={prompt} label="Copy for my agent" />
        </div>
        {!session ? <button className="btn btn-secondary btn-fit" onClick={() => openSignIn(true)}>Or sign in to prepare it here</button>
          : <button className="btn btn-primary btn-fit" disabled={busy || !f.title || !!formError} onClick={prepareAndSend}>{busy ? "Working…" : "Prepare transactions"}</button>}
        {formError && <p className="field-msg err" role="status">{formError}</p>}
        {warnings.length > 0 && <ul className="small muted">{warnings.map((w) => <li key={w}>{w}</li>)}</ul>}
        {msg && <p className={`field-msg ${msg.tone}`}>{msg.text}{msg.hash && <> · <a href={explorerTx(msg.hash)} target="_blank" rel="noreferrer">tx ↗</a></>}</p>}
        <p className="small muted">Quests are run by their creators. Don't promise returns or present a quest as official Binance/BNB Chain activity; such quests can be blocked.</p>
      </div>
    </div>
  );
}
