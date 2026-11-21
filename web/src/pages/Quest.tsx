import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useConfig } from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { TestHandleMint } from "../components/AgentIdPanel";
import { useAgentTx } from "../components/AgentTx";
import { Bar } from "../components/ui";
import { AgentSection } from "../components/AgentSection";
import { QuestTasks, useQuestTaskState } from "../components/QuestTasks";
import { explorerAddress, explorerTx, MOCK_REGISTRY, VERIFY_API } from "../config";
import { fmtDate, short } from "../lib/format";
import { useCampaigns, useMyAgentId, type Tx } from "../lib/hooks";
import { useSession } from "../lib/session";
import { rewardText, statusBadge, useFmt } from "./Home";

export function QuestPage() {
  const { id } = useParams();
  const q = useCampaigns();
  const fmt = useFmt(q.data?.token);
  const c = q.data?.campaigns.find((x) => x.id === id);
  const { session, openSignIn } = useSession();
  const taskState = useQuestTaskState(id ?? "", session);
  const me = useMyAgentId();
  const config = useConfig();
  const { request } = useAgentTx();
  const [postUrl, setPostUrl] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: "ok" | "err" | "muted"; text: string; hash?: string } | null>(null);

  if (q.isLoading) return <div className="page narrow"><p className="muted">Loading…</p></div>;
  if (!c) return <div className="page narrow"><p>Quest not found. <Link to="/">All quests</Link></p></div>;
  const you = c.you;

  async function sendTx(tx: Tx) {
    const h = await request({ label: tx.label, from: tx.from, to: tx.to, data: tx.data, value: BigInt(tx.value || "0") });
    if (!h) { q.refetch(); return; }
    setMsg({ tone: "muted", text: "Waiting for confirmation…", hash: h });
    const r = await waitForTransactionReceipt(config, { hash: h, timeout: 180_000 }).catch(() => null);
    setMsg(r?.status === "success" ? { tone: "ok", text: "Confirmed.", hash: h } : { tone: "err", text: "Transaction failed or not found.", hash: h });
    q.refetch();
  }

  async function verifyAndClaim() {
    if (!session || !c) return;
    setBusy(true); setMsg(null);
    try {
      const r = await fetch(VERIFY_API, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.token}` },
        body: JSON.stringify({ campaignId: c.id, postUrl, wallet: session.wallet }),
      });
      const j = await r.json();
      if (!j.ok) throw new Error(j.error || "Verification failed.");
      setMsg({ tone: "ok", text: `Post verified (@${j.username}).` });
      await sendTx(j.tx);
    } catch (e) { setMsg({ tone: "err", text: e instanceof Error ? e.message : "Verification failed." }); }
    setBusy(false);
  }

  async function manage(action: string, extra: Record<string, string> = {}) {
    if (!session || !c) return;
    setBusy(true); setMsg(null);
    try {
      const r = await fetch("/api/manage", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session.token}` }, body: JSON.stringify({ wallet: session.wallet, id: c.id, action, ...extra }) });
      const j = await r.json();
      if (!j.ok) throw new Error(j.error || "Failed.");
      for (const s of j.steps as Tx[]) await sendTx(s);
    } catch (e) { setMsg({ tone: "err", text: e instanceof Error ? e.message : "Failed." }); }
    setBusy(false);
  }

  const isCreator = !!session && session.wallet.toLowerCase() === c.creator.toLowerCase();
  const signedIn = !!session;
  const hasId = signedIn && me.ok;
  const tasksSatisfied = !taskState.isLoading && !taskState.isError && (!taskState.data?.tasks.length || taskState.data.tasks.every((task) => taskState.data?.completed.includes(task.id)));
  return (
    <div className="page">
      <p className="crumb"><Link to="/">← All quests</Link></p>
      <section className="hero q-hero">
        <div className="hero-deco" aria-hidden="true" />
        <p className="eyebrow"><i />Quest #{c.id} · {c.mode === "FCFS" ? "first come, first served" : "random reward"}</p>
        <h1 className="hero-title q-hero-title">{c.title}</h1>
        <div className="q-hero-meta">{statusBadge(c)}<span>Created by <a className="mono" href={explorerAddress(c.creator)} target="_blank" rel="noreferrer">{short(c.creator)}</a>. Quests are run by their creators.</span></div>
        <dl className="hero-stats q-figure">
          <div className="wide"><dt>Reward per claim</dt><dd>{rewardText(c, fmt)}</dd></div>
          <div><dt>Slots left</dt><dd>{c.remainingSlots}/{c.maxClaims}</dd></div>
          <div className="date"><dt>Ends</dt><dd>{c.endTime ? fmtDate(c.endTime) : "No end date"}</dd></div>
        </dl>
        <Bar left={Number(c.remainingSlots)} total={Number(c.maxClaims)} />
      </section>
      <p className="q-note">
        {c.mode === "FCFS"
          ? "Fixed reward, paid in the claim transaction, to the first claimers until slots or budget run out."
          : `Claim, wait ~2 blocks, then settle. Odds: ${c.reward.type === "random" ? c.reward.tiers.map((t) => `${fmt(t.amount)} ${t.oddsPct}%`).join(", ") : ""}. Settle within 256 blocks or it pays the lowest tier.`}
      </p>

      <AgentSection questId={c.id} />
      <QuestTasks campaignId={c.id} session={session} />
      <ol className="qsteps panel">
        <li className={signedIn ? "done" : ""}>
          <strong>Sign in with your agent</strong>
          {!signedIn ? <button className="btn btn-primary btn-fit" onClick={() => openSignIn(true)}>Sign in</button>
            : hasId ? <span className="small ok">Signed in as {me.handle}.ai</span>
            : me.isLoading ? <span className="small muted">Checking Agent ID…</span>
            : <>
                <span className="small err">This wallet has no Agent ID.</span>
                {MOCK_REGISTRY && <TestHandleMint onDone={() => me.refetch()} />}
              </>}
        </li>
        <li>
          <strong>Quote the quest post on X</strong>
          {c.targetPostUrl
            ? <a className="btn btn-secondary btn-fit" href={`https://x.com/intent/tweet?url=${encodeURIComponent(c.targetPostUrl)}`} target="_blank" rel="noreferrer">Quote on X ↗</a>
            : <span className="small muted">The post for this quest isn't announced yet.</span>}
        </li>
        <li className={you?.claimed ? "done" : ""}>
          <strong>{c.mode === "FCFS" ? "Claim" : "Claim, then settle"}</strong>
          {!hasId ? <span className="small muted">Sign in with an Agent ID wallet first.</span>
            : you?.claimed ? <span className="small ok">Claimed{you.reward ? ` ${fmt(you.reward)}` : ""}.</span>
            : you?.pending ? (
              <>
                <span className="small muted">{you.pending.ready ? (you.pending.expired ? "Past 256 blocks: settling pays the lowest tier." : "Ready to settle.") : `Waiting ${you.pending.blocksLeft} block(s)…`}</span>
                <button className="btn btn-primary btn-fit" disabled={!you.nextTx} onClick={() => you.nextTx && sendTx(you.nextTx)}>Settle</button>
              </>
            ) : you?.canClaim && c.targetPostId && tasksSatisfied ? (
              <>
                <input placeholder="Link to your quote post: https://x.com/you/status/…" value={postUrl} onChange={(e) => setPostUrl(e.target.value)} />
                <button className="btn btn-primary btn-fit" disabled={busy || !/status\/\d+/.test(postUrl)} onClick={verifyAndClaim}>{busy ? "Verifying…" : "Verify & claim"}</button>
              </>
            ) : you?.canClaim && c.targetPostId && !tasksSatisfied ? <span className="small muted">{taskState.isError ? "Could not load required tasks." : "Complete all required tasks above before claiming."}</span>
              : <span className="small muted">Not claimable{you?.reason ? `: ${you.reason}` : ""}.</span>}
        </li>
      </ol>
      {isCreator && (
        <details className="manage">
          <summary>Manage your quest</summary>
          <div className="stack">
            <span className="muted">Budget {fmt(c.budget.balance)} (reserved {fmt(c.budget.reserved)}). You can withdraw the unreserved part after the end or while paused.</span>
            <div className="row-wrap">
              <button className="btn btn-sm btn-secondary" disabled={busy} onClick={() => manage(c.paused ? "resume" : "pause")}>{c.paused ? "Resume" : "Pause"}</button>
              <button className="btn btn-sm btn-secondary" disabled={busy} onClick={() => manage("withdraw")}>Withdraw leftover</button>
              {c.slotsUsed === 0 && <button className="btn btn-sm btn-secondary" disabled={busy} onClick={() => { const u = window.prompt("Link to the X post claimers must quote"); if (u) manage("setPost", { postUrl: u }); }}>Set X post</button>}
            </div>
          </div>
        </details>
      )}
      {msg && <p className={`field-msg ${msg.tone}`}>{msg.text}{msg.hash && <> · <a href={explorerTx(msg.hash)} target="_blank" rel="noreferrer">tx ↗</a></>}</p>}
      <p className="small muted">Your agent previews every transaction with your Agentic Wallet and you confirm it. This site never holds keys or sends transactions.</p>
    </div>
  );
}
