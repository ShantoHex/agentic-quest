import { useQueryClient } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from "react";
import { formatEther, isHash, type Address, type Hex } from "viem";
import { chain, IS_TESTNET, NATIVE_SYMBOL, RPC_URL } from "../config";

/** A transaction the user's own agent/wallet must preview, confirm and send. This site never sends it. */
export type AgentTxRequest = { label: string; from: Address; to: Address; data: Hex; value: bigint };
type Pending = AgentTxRequest & { resolve: (h: Hex | null) => void };
type Ctx = { request: (r: AgentTxRequest) => Promise<Hex | null> };
const AgentTxCtx = createContext<Ctx | null>(null);

export const BAW_CHAIN = "56";

export function bawPreview(r: { from: string; to: string; data: string; value: bigint | string }) {
  return `baw contract-call preview --binanceChainId ${BAW_CHAIN} --from ${r.from} --to ${r.to} --value ${r.value.toString()} --inputData ${r.data} --json`;
}

export function agentPrompt(r: AgentTxRequest) {
  return [
    `Agentic Quest action: ${r.label}.`,
    `Using my Agentic Wallet (${r.from}), make this contract call on ${chain.name} (chain ${chain.id}):`,
    `to: ${r.to}`,
    `value (wei): ${r.value.toString()}`,
    `data: ${r.data}`,
    `Run: ${bawPreview(r)}`,
    `Show me the parsed transaction and any risks, and WAIT for my explicit "yes" before running baw contract-call execute with the requestId. Then tell me the transaction hash.`,
    `(Requires Developer Mode in the Agentic Wallet settings. Never ask me for keys, seed phrases or pairing codes.)`,
  ].join("\n");
}

export function Copy({ text, label = "Copy", className = "btn btn-sm btn-secondary", onCopied }: { text: string; label?: string; className?: string; onCopied?: () => void }) {
  const [ok, setOk] = useState(false);
  return (
    <button type="button" className={className} onClick={() => { navigator.clipboard?.writeText(text); setOk(true); onCopied?.(); setTimeout(() => setOk(false), 1500); }}>
      {ok ? "Copied" : label}
    </button>
  );
}

export function AgentTxProvider({ children }: { children: ReactNode }) {
  const [cur, setCur] = useState<Pending | null>(null);
  const [hash, setHash] = useState("");
  const qc = useQueryClient();
  const curRef = useRef<Pending | null>(null);
  const request = useCallback((r: AgentTxRequest) => new Promise<Hex | null>((resolve) => {
    curRef.current?.resolve(null);
    const p = { ...r, resolve };
    curRef.current = p;
    setHash("");
    setCur(p);
  }), []);
  const close = (h: Hex | null) => {
    cur?.resolve(h);
    curRef.current = null;
    setCur(null);
    if (!h) qc.invalidateQueries();
  };
  const value = useMemo(() => ({ request }), [request]);
  const h = hash.trim();
  return (
    <AgentTxCtx.Provider value={value}>
      {children}
      {cur && (
        <div className="modal-wrap" role="dialog" aria-modal="true" aria-label={cur.label}>
          <div className="modal">
            <div className="modal-head">
              <h3>{cur.label}</h3>
              <button className="btn btn-sm btn-ghost" onClick={() => close(null)} aria-label="Close">✕</button>
            </div>
            <p className="small muted">Agentic Quest never signs or sends for you. Give this to <strong>your own agent</strong>; it previews the call with your Agentic Wallet, you confirm, and it sends it.</p>
            <div className="codebox"><pre>{agentPrompt(cur)}</pre></div>
            <div className="row-gap"><Copy text={agentPrompt(cur)} label="Copy prompt for my agent" /><Copy text={bawPreview(cur)} label="Copy baw command" /></div>
            <details className="small">
              <summary>Raw transaction</summary>
              <dl className="kv">
                <div><dt>From</dt><dd className="mono">{cur.from}</dd></div>
                <div><dt>To</dt><dd className="mono">{cur.to}</dd></div>
                <div><dt>Value</dt><dd className="mono">{formatEther(cur.value)} {NATIVE_SYMBOL}</dd></div>
                <div><dt>Data</dt><dd className="mono wrap">{cur.data}</dd></div>
              </dl>
            </details>
            {IS_TESTNET && (
              <p className="callout callout-muted small">
                Testnet demo: Agentic Wallet only sends on BSC mainnet. On testnet, send the same calldata from a testnet wallet you control, e.g.
                <span className="mono wrap"> cast send {cur.to} {cur.data}{cur.value ? ` --value ${cur.value}` : ""} --rpc-url {RPC_URL} --account &lt;your-keystore&gt;</span>
              </p>
            )}
            <label className="field">
              <span className="small">Transaction hash from your agent</span>
              <input className="mono" placeholder="0x…" value={hash} onChange={(e) => setHash(e.target.value)} />
            </label>
            <div className="row-gap">
              <button className="btn btn-primary" disabled={!isHash(h)} onClick={() => close(h as Hex)}>Track transaction</button>
              <button className="btn btn-secondary" onClick={() => close(null)}>Done, refresh status</button>
            </div>
          </div>
        </div>
      )}
    </AgentTxCtx.Provider>
  );
}

export function useAgentTx() {
  const c = useContext(AgentTxCtx);
  if (!c) throw new Error("AgentTxProvider missing");
  return c;
}
