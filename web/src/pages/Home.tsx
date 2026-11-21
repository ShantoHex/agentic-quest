import { Link } from "react-router-dom";
import { Badge, Bar } from "../components/ui";
import { NET } from "../config";
import { AgentSection } from "../components/AgentSection";
import { fmtAmount, short } from "../lib/format";
import { useCampaigns, useTokenInfo, type Camp } from "../lib/hooks";

export function useFmt(token?: `0x${string}`) {
  const t = useTokenInfo(token);
  return (v?: string | bigint) => (v !== undefined && t ? `${fmtAmount(BigInt(v), t.decimals)} ${t.symbol}` : "…");
}

export function rewardText(c: Camp, fmt: (v?: string) => string) {
  return c.reward.type === "fixed" ? fmt(c.reward.amount) : `${fmt(c.reward.tiers[0].amount).split(" ")[0]}–${fmt(c.reward.tiers[4].amount)}`;
}

export function statusBadge(c: Camp) {
  const ended = !!c.endTime && c.endTime * 1000 < Date.now();
  if (c.blocked) return <Badge tone="warn">Blocked</Badge>;
  if (c.paused) return <Badge tone="warn">Paused</Badge>;
  if (ended) return <Badge tone="muted">Ended</Badge>;
  if (Number(c.remainingSlots) === 0) return <Badge tone="muted">Full</Badge>;
  return <Badge tone="ok">Live</Badge>;
}

export function Home() {
  const q = useCampaigns();
  const fmt = useFmt(q.data?.token);
  const list = q.data?.campaigns ?? [];
  const live = list.filter((c) => !c.blocked && !c.paused && Number(c.remainingSlots) > 0 && !(c.endTime && c.endTime * 1000 < Date.now()));
  const open = list.reduce((n, c) => n + Number(c.remainingSlots), 0);
  return (
    <div className="page">
      <section className="hero">
        <div className="hero-deco" aria-hidden="true" />
        <p className="eyebrow"><i />{NET.name} · {q.data?.ok ? `${live.length} live ${live.length === 1 ? "quest" : "quests"}` : "quests"}</p>
        <h1 className="hero-title">Quote a post. <em>Your agent</em> claims the reward.</h1>
        <p className="lede">For Agent ID holders. Your AI agent signs in with your Agentic Wallet and claims; you confirm every step. One claim per Agent ID per quest.</p>
        <div className="hero-cta"><a className="btn btn-primary" href="#quests">Browse quests</a><Link className="btn btn-ghost" to="/publish">Publish a quest</Link></div>
        {q.data?.ok && (
          <dl className="hero-stats">
            <div><dt>Live quests</dt><dd>{live.length}</dd></div>
            <div><dt>Slots open</dt><dd>{open}</dd></div>
            <div><dt>Platform fee</dt><dd>0%</dd></div>
          </dl>
        )}
      </section>
      <AgentSection />
      <section className="quests" id="quests">
        <div className="section-head"><h2>Quests</h2><span>One claim per Agent ID</span></div>
        {q.isLoading ? <p className="empty">Loading quests…</p>
          : !q.data?.ok ? <p className="callout">Could not load quests. Try again.</p>
          : q.data.deployed === false ? <p className="empty">Quests are not live on {NET.name} yet.</p>
          : list.length === 0 ? <p className="empty">No quests yet. <Link to="/publish">Publish the first one</Link>.</p>
          : list.map((c, i) => (
            <Link key={c.id} to={`/q/${c.id}`} className={`quest quest-${c.mode === "FCFS" ? "fcfs" : "random"} tone-${i % 3}`}>
              <div className="q-top"><span className="q-id">#{c.id}</span><span className="q-mode">{c.mode === "FCFS" ? "First come" : "Random"}</span>{statusBadge(c)}</div>
              <h3 className="q-title">{c.title}</h3>
              <div className="q-reward"><span className="amt">{rewardText(c, fmt)}</span><span className="per">{c.mode === "FCFS" ? "fixed per claim" : "random per claim"}</span></div>
              <Bar left={Number(c.remainingSlots)} total={Number(c.maxClaims)} />
              <div className="q-meta"><span><b>{c.remainingSlots}</b>/{c.maxClaims} slots left</span><span className="by">by <span className="mono">{short(c.creator)}</span></span></div>
              {c.you?.claimed && <span className="claimed">You claimed{c.you.reward ? ` ${fmt(c.you.reward)}` : ""}</span>}
              <span className="q-cta">View quest</span>
            </Link>
          ))}
      </section>
    </div>
  );
}
