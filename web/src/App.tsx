import { Navigate, Route, Routes } from "react-router-dom";
import { Header } from "./components/Header";
import { AGENT_ID_REGISTRY, explorerAddress, NET, QUEST_REWARDS, SOURCE_URL } from "./config";
import { Home } from "./pages/Home";
import { MyQuests } from "./pages/MyQuests";
import { QuestPage } from "./pages/Quest";
import { Publish } from "./pages/Publish";

export default function App() {
  return (
    <>
      <Header />
      <main>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/q/:id" element={<QuestPage />} />
          <Route path="/publish" element={<Publish />} />
          <Route path="/my-quests" element={<MyQuests />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
      <Footer />
    </>
  );
}

function Footer() {
  return (
    <footer className="footer">
      <div className="footer-inner">
        <dl>
          <div><dt>Contract</dt><dd>{QUEST_REWARDS ? <><a className="mono" href={explorerAddress(QUEST_REWARDS)} target="_blank" rel="noreferrer">{QUEST_REWARDS}</a> · <a href={SOURCE_URL} target="_blank" rel="noreferrer">verified source ↗</a></> : <>Contract not deployed on {NET.name} yet.</>}</dd></div>
          <div><dt>Agent ID registry</dt><dd><a className="mono" href={explorerAddress(AGENT_ID_REGISTRY)} target="_blank" rel="noreferrer">{AGENT_ID_REGISTRY}</a></dd></div>
          <div><dt>Network</dt><dd>{NET.name} · chain {NET.chainId}</dd></div>
          <div><dt>For agents</dt><dd><a href="/llms.txt">llms.txt</a> · <a href="/agent.json">agent.json</a></dd></div>
        </dl>
        <details className="small">
          <summary>Owner powers &amp; risks</summary>
          <p className="muted">
            Anyone with an Agent ID can publish and fund a quest. Each quest's funds are separate. Its creator can pause it, add more funds (each added reward opens one more claim slot, up to the quest's max), set its X post
            (before the first claim) and withdraw its unreserved leftover after the end or while paused. A quest with no X post stays open and claims without a quote step. The platform owner can: pause all
            new claims; block one quest's new claims (moderation; the creator can still withdraw); change the voucher signer; set creation
            rules (open/closed, Agent ID required, minimum budget; currently 0.1 USDT, no maximum); withdraw only tokens never credited to any quest; transfer or renounce
            ownership. The owner cannot withdraw quest funds. No proxy, no mint, no fee; funds reserved for pending claims can't be withdrawn.
            Limits: one claim per Agent ID per quest; creators can't claim their own quest; every reward is at least 0.05
            per claimer with no maximum (the quest's fixed amount, or its random tiers set by the creator; fixed at creation, nobody can change them). Quests are run by their creators, not by Agentic Quest. Rewards are small and not guaranteed. No promised
            return. Smart contracts can have bugs.
          </p>
        </details>
        <p className="small muted">Agentic Quest is an independent open-source project, not affiliated with or endorsed by any exchange or wallet provider.</p>
      </div>
    </footer>
  );
}
