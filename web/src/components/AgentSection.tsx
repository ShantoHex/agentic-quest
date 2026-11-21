import { Copy } from "./AgentTx";

const SITE = typeof window !== "undefined" ? window.location.origin : "https://agentic-quest.vercel.app";

/** One-line prompt that lets the user's own agent do everything (login + claim) from /llms.txt. */
export function agentPrompt(questId?: string) {
  return questId
    ? `Read ${SITE}/llms.txt and complete quest #${questId} on Agentic Quest for me with my Agentic Wallet (sign in, quote the post, claim). Ask me before every signature or transaction.`
    : `Read ${SITE}/llms.txt and help me complete a quest on Agentic Quest with my Agentic Wallet (sign in, quote the post, claim). Ask me before every signature or transaction.`;
}

export function AgentSection({ questId }: { questId?: string }) {
  const p = agentPrompt(questId);
  return (
    <section className="agent-box" aria-labelledby="agent-box-title">
      <h2 id="agent-box-title">Let your agent do it</h2>
      <p>Copy this to your AI agent. It reads our guide, signs you in with your Agentic Wallet and does the quest, asking you before every signature.</p>
      <div className="codebox"><pre>{p}</pre></div>
      <Copy text={p} label="Copy prompt for your agent" className="btn btn-primary btn-block" />
    </section>
  );
}
