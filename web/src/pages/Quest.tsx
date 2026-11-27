import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { keccak256, toHex, type Hex } from "viem";
import { Link, useParams } from "react-router-dom";
import { useConfig } from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";
import { TestHandleMint } from "../components/AgentIdPanel";
import { useAgentTx } from "../components/AgentTx";
import { Bar } from "../components/ui";
import { AgentSection } from "../components/AgentSection";
import { QuestTasks, useQuestTaskState } from "../components/QuestTasks";
import { CHAIN_ID, explorerAddress, explorerTx, MOCK_REGISTRY, QUEST_REWARDS, VERIFY_API } from "../config";
import { fmtDate, short } from "../lib/format";
import { useCampaigns, useMyAgentId, type Tx } from "../lib/hooks";
import { useSession } from "../lib/session";
import { isEnded, isFullyClaimed, rewardText, statusBadge, useFmt } from "./Home";

/** RANDOM claims: the claimant's own secret, kept on this device until settle (its hash is committed on-chain). */
const secretKey = (id: string, wallet: string) => `pq-rand-${CHAIN_ID}-${(QUEST_REWARDS ?? "").toLowerCase()}-${id}-${wallet.toLowerCase()}`;
function loadSecret(id: string, wallet: string): Hex | null {
  try { const v = localStorage.getItem(secretKey(id, wallet)); return v && /^0x[0-9a-f]{64}$/.test(v) ? (v as Hex) : null; } catch { return null; }
}
function newSecret(id: string, wallet: string): Hex {
  const existing = loadSecret(id, wallet);
  if (existing) return existing;
  const s = toHex(crypto.getRandomValues(new Uint8Array(32)));
  try { localStorage.setItem(secretKey(id, wallet), s); } catch { /* storage blocked: claim still works, settle falls back */ }
  return s;
}

export function QuestPage() {
  const { id } = useParams();
  const q = useCampaigns();
  const fmt = useFmt(q.data?.token);
  const c = q.data?.campaigns.find((x) => x.id === id);
  const meta = useQuery({ queryKey: ["quest-meta", id], queryFn: async () => (await fetch(`/api/quest-meta?campaignId=${id}`)).json() as Promise<{ ok: boolean; description?: string }> });
  const { session, openSignIn } = useSession();
  const taskState = useQuestTaskState(id ?? "", session);
  const me = useMyAgentId();
  const config = useConfig();
  const { request } = useAgentTx();
  const [postUrl, setPostUrl] = useState("");
  const [fundAmt, setFundAmt] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: "ok" | "err" | "muted"; text: string; hash?: string } | null>(null);

  if (q.isLoading) return <div className="page narrow"><p className="muted">Loading…</p></div>;
  if (!c) return <div className="page narrow"><p>Quest not found. <Link to="/">All quests</Link></p></div>;
  const you = c.you;
  const fullyClaimed = isFullyClaimed(c);
  const ended = isEnded(c);

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
        body: JSON.stringify({ campaignId: c.id, ...(c.targetPostId ? { postUrl } : {}), wallet: session.wallet, ...(c.mode === "RANDOM" ? { userCommit: keccak256(newSecret(c.id, session.wallet)) } : {}) }),
      });
      const j = await r.json();
      if (!j.ok) throw new Error(j.error || "Verification failed.");
      setMsg({ tone: "ok", text: j.noPost ? "Ready to claim." : `Post verified (@${j.username}).` });
      await sendTx(j.tx);
    } catch (e) { setMsg({ tone: "err", text: e instanceof Error ? e.message : "Verification failed." }); }
    setBusy(false);
  }

  async function settle() {
    if (!session || !c) return;
    setBusy(true); setMsg(null);
    try {
      const secret = loadSecret(c.id, session.wallet);
      const r = await fetch(`/api/campaigns?wallet=${session.wallet}&id=${c.id}${secret ? `&userSecret=${secret}` : ""}`, { headers: { Authorization: `Bearer ${session.token}` } });
      const j = await r.json();
      const mine = (j.campaigns ?? []).find((x: { id: string }) => x.id === c.id);
      const tx = mine?.you?.nextTx as Tx | undefined;
      if (!tx) throw new Error(secret ? (mine?.you?.pending?.needUserSecret || mine?.you?.pending?.note || "Not ready to settle yet.") : "Your claim secret isn't on this device. Once the reveal window passes (about an hour), settling pays the lowest tier.");
      await sendTx(tx);
    } catch (e) { setMsg({ tone: "err", text: e instanceof Error ? e.message : "Settle failed." }); }
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
      {meta.data?.description ? <p className="q-note">{meta.data.description}</p> : null}
      <p className="q-note">
        {c.mode === "FCFS"
          ? "Fixed reward, paid in the claim transaction, to the first claimers until slots or budget run out."
          : "Claim, wait ~2 blocks, then settle. The draw mixes your secret, the server's secret and a future block hash, so nobody can pick the result. Settle within the reveal window (about an hour on BSC) or it pays the lowest tier."}
      </p>
      {c.reward.type === "random" && (
        <ul className="tier-list" aria-label="Reward tiers">
          {c.reward.tiers.map((t, i) => <li key={i}><span>{fmt(t.amount)}</span><span>{t.oddsPct}%</span></li>)}
        </ul>
      )}

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
        <li className={c.targetPostUrl ? "" : "done"}>
          <strong>{c.targetPostUrl ? "Quote the quest post on X" : "Quote step"}</strong>
          {c.targetPostUrl
            ? <a className="btn btn-secondary btn-fit" href={`https://x.com/intent/tweet?url=${encodeURIComponent(c.targetPostUrl)}&text=${encodeURIComponent("Just claimed $0.2 on Agentic Quest ✅\n\nNow claim yours → https://agentic-quest.vercel.app\n\n#AgenticQuest #BinanceWalletHackathon #AgenticWallet")}`} target="_blank" rel="noreferrer">Quote on X ↗</a>
            : <span className="small muted">This quest has no X post — no quote needed, claim directly below.</span>}
        </li>
        <li className={you?.claimed ? "done" : ""}>
          <strong>{c.mode === "FCFS" ? "Claim" : "Claim, then settle"}</strong>
          {!hasId ? <span className="small muted">Sign in with an Agent ID wallet first.</span>
            : you?.claimed ? <span className="small ok">Claimed{you.reward ? ` ${fmt(you.reward)}` : ""}.</span>
            : you?.pending ? (
              <>
                <span className="small muted">{you.pending.ready ? (you.pending.expired ? "Reveal window passed: settling pays the lowest tier." : "Ready to settle.") : `Waiting ${you.pending.blocksLeft} block(s)…`}</span>
                <button className="btn btn-primary btn-fit" disabled={busy || !you.pending.ready} onClick={settle}>{busy ? "Preparing…" : "Settle"}</button>
              </>
            ) : fullyClaimed ? (
              <>
                <span className="small muted">Every slot has been claimed, or the budget can't pay another reward.</span>
                <button className="btn btn-primary btn-fit" disabled>Fully claimed</button>
              </>
            ) : ended ? (
              <>
                <span className="small muted">This quest has ended.</span>
                <button className="btn btn-primary btn-fit" disabled>Ended</button>
              </>
            ) : you?.canClaim && tasksSatisfied ? (
              c.targetPostId ? (
                <>
                  <input placeholder="Link to your quote post: https://x.com/you/status/…" value={postUrl} onChange={(e) => setPostUrl(e.target.value)} />
                  <button className="btn btn-primary btn-fit" disabled={busy || !/status\/\d+/.test(postUrl)} onClick={verifyAndClaim}>{busy ? "Verifying…" : "Verify & claim"}</button>
                </>
              ) : (
                <button className="btn btn-primary btn-fit" disabled={busy} onClick={verifyAndClaim}>{busy ? "Preparing…" : "Claim"}</button>
              )
            ) : you?.canClaim && !tasksSatisfied ? <span className="small muted">{taskState.isError ? "Could not load required tasks." : "Complete all required tasks above before claiming."}</span>
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
            <div className="row-wrap">
              <label className="field"><span className="field-label">Add funds, USDT</span><input inputMode="decimal" value={fundAmt} onChange={(e) => setFundAmt(e.target.value)} placeholder="1" /></label>
              <button className="btn btn-sm btn-secondary" disabled={busy || !(Number(fundAmt) > 0)} onClick={() => manage("fund", { amount: fundAmt })}>Add funds</button>
            </div>
            <span className="small muted">Added funds open more claim slots (one slot per reward paid), up to the quest's max of {c.maxClaims} slots.</span>
          </div>
        </details>
      )}
      {msg && <p className={`field-msg ${msg.tone}`}>{msg.text}{msg.hash && <> · <a href={explorerTx(msg.hash)} target="_blank" rel="noreferrer">tx ↗</a></>}</p>}
      <p className="small muted">Your agent previews every transaction with your Agentic Wallet and you confirm it. This site never holds keys or sends transactions.</p>
    </div>
  );
}
