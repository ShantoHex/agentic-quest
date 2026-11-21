import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router-dom";
import { useConfig } from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { Copy, useAgentTx } from "../components/AgentTx";
import { explorerTx } from "../config";
import { useSession } from "../lib/session";
import type { Tx } from "../lib/hooks";

type Rules = { tokenSymbol: string; minBudget: string; maxFcfsRewardPerClaim: string; creatorNeedsAgentId: boolean; creationOpen: boolean };

const SITE = typeof window !== "undefined" ? window.location.origin : "https://agentic-quest.vercel.app";

export function Publish() {
  const { session, openSignIn } = useSession();
  const config = useConfig();
  const { request } = useAgentTx();
  const rules = useQuery({ queryKey: ["publish-rules"], queryFn: async () => (await fetch("/api/publish")).json() as Promise<{ ok: boolean; rules?: Rules; error?: string }> });
  const r = rules.data?.rules;
  const [f, setF] = useState({ title: "", mode: "FCFS", rewardPerClaim: "0.10", maxClaims: "10", budget: "1", postUrl: "", durationDays: "7" });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: "ok" | "err" | "muted"; text: string; hash?: string } | null>(null);
  const [warnings, setWarnings] = useState<string[]>([]);

  const payload = {
    wallet: session?.wallet ?? "<my Agentic Wallet address>",
    title: f.title || "<title>", mode: f.mode, ...(f.mode === "FCFS" ? { rewardPerClaim: f.rewardPerClaim } : {}),
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
      setMsg({ tone: "ok", text: "Quest published. It appears on the quest list in a few seconds." });
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
          <li><span>Fixed reward per claim</span><span>up to {r.maxFcfsRewardPerClaim}</span></li>
          <li><span>Random reward per claim</span><span>0.05–0.20</span></li>
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
          {f.mode === "FCFS" && <label className="field"><span className="field-label">Reward per claim</span><input inputMode="decimal" value={f.rewardPerClaim} onChange={set("rewardPerClaim")} /></label>}
        </div>
        <div className="field-row two">
          <label className="field"><span className="field-label">Max claims</span><input inputMode="numeric" value={f.maxClaims} onChange={set("maxClaims")} /></label>
          <label className="field"><span className="field-label">Budget, USDT</span><input inputMode="decimal" value={f.budget} onChange={set("budget")} /><span className="field-hint">Min {r?.minBudget ?? "1"}, no max</span></label>
        </div>
        <label className="field"><span className="field-label">Duration (days)</span><input inputMode="numeric" value={f.durationDays} onChange={set("durationDays")} /></label>

        <div className="stack">
          <span className="section-label">Send this to your AI agent</span>
          <pre className="prompt">{prompt}</pre>
          <Copy text={prompt} label="Copy for my agent" />
        </div>
        {!session ? <button className="btn btn-secondary btn-fit" onClick={() => openSignIn(true)}>Or sign in to prepare it here</button>
          : <button className="btn btn-primary btn-fit" disabled={busy || !f.title} onClick={prepareAndSend}>{busy ? "Working…" : "Prepare transactions"}</button>}
        {warnings.length > 0 && <ul className="small muted">{warnings.map((w) => <li key={w}>{w}</li>)}</ul>}
        {msg && <p className={`field-msg ${msg.tone}`}>{msg.text}{msg.hash && <> · <a href={explorerTx(msg.hash)} target="_blank" rel="noreferrer">tx ↗</a></>}</p>}
        <p className="small muted">Quests are run by their creators. Don't promise returns or present a quest as official Binance/BNB Chain activity; such quests can be blocked.</p>
      </div>
    </div>
  );
}
