import { useCallback, useEffect, useRef, useState } from "react";
import { getAddress, isAddress } from "viem";
import { useSession } from "../lib/session";
import { Copy } from "./AgentTx";
import { useToasts } from "./Toasts";

const API = "/api/auth";
type Challenge = { message: Record<string, string>; howToSign: { agenticWallet: { preview: string } } };

/** Pull signature (+ recovery id) out of whatever the user pastes: raw hex or the baw JSON output. */
function parseSig(raw: string): { signature: string; signatureRecovery?: string } | null {
  const t = raw.trim();
  if (!t) return null;
  if (t.startsWith("{")) {
    try {
      const j = JSON.parse(t);
      const d = j.data ?? j;
      if (d.signature) return { signature: String(d.signature), signatureRecovery: d.signatureRecovery != null ? String(d.signatureRecovery) : undefined };
    } catch { return null; }
  }
  const m = t.match(/(0x)?[0-9a-fA-F]{128,}/);
  return m ? { signature: m[0] } : null;
}

function agentLoginPrompt(wallet: string, c: Challenge) {
  return [
    "Sign me in to Agentic Quest with my Agentic Wallet.",
    `Wallet: ${wallet}`,
    "This is an EIP-712 read-only login message (no transaction, no approval). Run:",
    c.howToSign.agenticWallet.preview,
    "Show me the parsed message, wait for my OK, then run baw sign-message execute --requestId <requestId> --json",
    "(if it says PENDING_CONFIRMATION, I confirm in the Binance App and you run baw sign-message result --order-id <orderId> --json).",
    "Give me the full JSON output with the signature.",
  ].join("\n");
}

const SITE = typeof window !== "undefined" ? window.location.origin : "https://agentic-quest.vercel.app";
type Link = { code: string; pollSecret: string; expiresAt: number; pollEveryMs: number };

/** The exact text the user copies for their agent (one-click login). */
export function linkPrompt(code: string) {
  return [
    `Sign me in to Agentic Quest (${SITE}) with my Agentic Wallet. Login code: ${code} (valid 10 minutes).`,
    `1. Get my wallet address: baw wallet status --json`,
    `2. GET ${SITE}/api/auth/link?code=${code}&wallet=<my address>`,
    `3. Show me the login message from step 2 (read-only, no transaction, no approval). Sign it with the howToSign.agenticWallet preview command, and run execute only after my OK.`,
    `4. POST ${SITE}/api/auth/link with JSON {"op":"submit","code":"${code}","wallet":"<my address>","message":<message from step 2>,"signature":"<signature>","signatureRecovery":"<signatureRecovery, if any>"}`,
    `My browser signs in by itself after that. Never ask me for keys, seed phrases or pairing codes.`,
  ].join("\n");
}

/** One-click login: start a link code, show the prompt, poll until the agent's signature lands. */
function useLinkLogin(active: boolean, onDone: (j: { wallet: string; agentId: string | null; token: string; expiresIn: number }) => void) {
  const [link, setLink] = useState<Link | null>(null);
  const [state, setState] = useState<"idle" | "waiting" | "expired" | "error">("idle");
  const [err, setErr] = useState("");
  const [left, setLeft] = useState(0);
  const done = useRef(onDone); done.current = onDone;
  const start = useCallback(async () => {
    setErr(""); setState("idle");
    try {
      const r = await fetch("/api/auth/link", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ op: "start" }) });
      const j = await r.json();
      if (!j.ok) throw new Error(j.error);
      setLink(j); setState("waiting");
    } catch (e) { setErr(e instanceof Error ? e.message : "Could not start login."); setState("error"); }
  }, []);
  useEffect(() => { if (active && !link) start(); if (!active) { setLink(null); setState("idle"); } }, [active, link, start]);
  useEffect(() => {
    if (!active || !link || state !== "waiting") return;
    let stop = false;
    const tick = async () => {
      if (stop) return;
      const secs = link.expiresAt - Math.floor(Date.now() / 1000);
      setLeft(Math.max(0, secs));
      if (secs <= 0) { setState("expired"); return; }
      try {
        const r = await fetch("/api/auth/link", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ op: "poll", code: link.code, pollSecret: link.pollSecret }) });
        const j = await r.json();
        if (j.ok && j.status === "done") { stop = true; done.current(j); return; }
        if (!j.ok && (j.code === "EXPIRED" || j.code === "USED")) { setState("expired"); return; }
      } catch { /* network blip: keep polling */ }
      if (!stop) timer = setTimeout(tick, link.pollEveryMs || 2500);
    };
    let timer = setTimeout(tick, 600);
    return () => { stop = true; clearTimeout(timer); };
  }, [active, link, state]);
  return { link, state, err, left, restart: () => { setLink(null); } };
}

export function SignInModal() {
  const { signInOpen, openSignIn, setSession } = useSession();
  const [wallet, setWallet] = useState("");
  const [chal, setChal] = useState<Challenge | null>(null);
  const [sig, setSig] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const { push } = useToasts();
  const auto = useLinkLogin(signInOpen, (j) => {
    setSession({ wallet: getAddress(j.wallet), agentId: j.agentId, token: j.token, exp: Math.floor(Date.now() / 1000) + Number(j.expiresIn) });
    push({ tone: "success", title: "Signed in", body: j.agentId ? `as ${j.agentId}` : "Read-only session for 24 hours." });
    openSignIn(false);
  });
  if (!signInOpen) return null;
  const close = () => { openSignIn(false); setChal(null); setSig(""); setErr(""); };

  async function getChallenge() {
    setErr(""); setBusy(true);
    try {
      const r = await fetch(`${API}/challenge?wallet=${getAddress(wallet.trim())}`);
      const j = await r.json();
      if (!j.ok) throw new Error(j.error);
      setChal(j);
    } catch (e) { setErr(e instanceof Error ? e.message : "Could not get a challenge."); }
    setBusy(false);
  }
  async function verify() {
    const s = parseSig(sig);
    if (!s || !chal) { setErr("Paste the signature (hex) or the JSON your agent returned."); return; }
    setErr(""); setBusy(true);
    try {
      const r = await fetch(`${API}/verify`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ wallet: getAddress(wallet.trim()), message: chal.message, ...s }) });
      const j = await r.json();
      if (!j.ok) throw new Error(j.error);
      setSession({ wallet: getAddress(j.wallet), agentId: j.agentId, token: j.token, exp: Math.floor(Date.now() / 1000) + Number(j.expiresIn) });
      close();
    } catch (e) { setErr(e instanceof Error ? e.message : "Verification failed."); }
    setBusy(false);
  }

  return (
    <div className="modal-wrap" role="dialog" aria-modal="true" aria-label="Sign in with your agent wallet">
      <div className="modal">
        <div className="modal-head">
          <h3>Sign in with your Agentic Wallet</h3>
          <button className="btn btn-sm btn-ghost" onClick={close} aria-label="Close">✕</button>
        </div>
        <p className="small muted">
          Your own AI agent signs a one-time, read-only login message with your Agentic Wallet. No QR code, no pairing code, no keys
          and no browser extension. Every transaction is still previewed by your agent and confirmed by you.
        </p>
        <div className="auto-login">
          <ol className="steps small">
            <li>Copy this prompt and send it to your AI agent.</li>
            <li>Check the login message your agent shows you, and let it sign.</li>
            <li>This page signs you in by itself. Keep it open.</li>
          </ol>
          {auto.link ? (
            <>
              <Copy text={linkPrompt(auto.link.code)} label="Copy prompt for your agent" className="btn btn-primary btn-block" />
              <details className="small prompt-peek"><summary>Show the prompt</summary><div className="codebox"><pre>{linkPrompt(auto.link.code)}</pre></div></details>
            </>
          ) : <button className="btn btn-primary btn-block" disabled>Preparing…</button>}
          <p className="wait-line" role="status" aria-live="polite">
            {auto.state === "waiting" && <><span className="pulse" aria-hidden="true" />Waiting for your agent · code expires in {Math.floor(auto.left / 60)}:{String(auto.left % 60).padStart(2, "0")}</>}
            {auto.state === "expired" && <>Code expired. <button className="btn btn-sm btn-secondary" onClick={auto.restart}>Get a new code</button></>}
            {auto.state === "error" && <span className="err">{auto.err} <button className="btn btn-sm btn-secondary" onClick={auto.restart}>Try again</button></span>}
          </p>
        </div>
        <details className="other-ways small">
          <summary>Other ways: paste a signature yourself</summary>
        <ol className="steps small">
            <li>
              <label className="field">
                <span>Your Agentic Wallet address on BSC (ask your agent: <span className="mono">baw wallet status --json</span>)</span>
                <input className="mono" placeholder="0x…" value={wallet} onChange={(e) => { setWallet(e.target.value); setChal(null); }} />
              </label>
              <div className="row-gap" style={{ marginTop: 8 }}>
                <button className="btn btn-secondary" disabled={!isAddress(wallet.trim()) || busy} onClick={getChallenge}>Get login message</button>
              </div>
            </li>
            {chal && (
              <li>
                Send this to your agent and confirm the preview:
                <div className="codebox"><pre>{agentLoginPrompt(getAddress(wallet.trim()), chal)}</pre></div>
                <div className="row-gap" style={{ marginTop: 8 }}>
                  <Copy text={agentLoginPrompt(getAddress(wallet.trim()), chal)} label="Copy prompt for my agent" />
                  <Copy text={chal.howToSign.agenticWallet.preview} label="Copy baw command" />
                </div>
                <p className="muted">The message expires in 10 minutes.</p>
              </li>
            )}
            {chal && (
              <li>
                <label className="field">
                  <span>Paste the signature or the JSON your agent returned</span>
                  <textarea rows={3} className="mono" value={sig} onChange={(e) => setSig(e.target.value)} placeholder='{"success":true,"data":{"signature":"…","signatureRecovery":"01"}}' />
                </label>
                <div className="row-gap" style={{ marginTop: 8 }}>
                  <button className="btn btn-primary" disabled={!sig.trim() || busy} onClick={verify}>Verify &amp; sign in</button>
                </div>
              </li>
            )}
          </ol>
        </details>
        {err && <p className="field-msg err">{err}</p>}
        <p className="small muted">
          Want your agent to do the whole quest on its own? Point it to <a href="/llms.txt" target="_blank" rel="noreferrer">/llms.txt</a> (machine-readable: <a href="/agent.json" target="_blank" rel="noreferrer">/agent.json</a>).
          Agentic Wallet is a third-party wallet product; Agentic Quest is independent and not affiliated with it.
        </p>
      </div>
    </div>
  );
}
