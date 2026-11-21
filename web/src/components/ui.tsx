import type { ReactNode } from "react";
import { explorerAddress, explorerTx } from "../config";
import { short } from "../lib/format";
import type { TxState } from "../lib/useTx";

export function Card({ children, className = "", title, action }: { children: ReactNode; className?: string; title?: ReactNode; action?: ReactNode }) {
  return (
    <section className={`card ${className}`}>
      {(title || action) && (
        <header className="card-head">
          {title && <h3 className="card-title">{title}</h3>}
          {action}
        </header>
      )}
      {children}
    </section>
  );
}

export function AddressLink({ address, label }: { address: string; label?: string }) {
  return (
    <a className="mono addr" href={explorerAddress(address)} target="_blank" rel="noreferrer">
      {label ?? short(address)}
    </a>
  );
}

export function Handle({ handle }: { handle: string }) {
  if (!handle) return <span className="muted">—</span>;
  return (
    <span className="handle">
      {handle}
      <span className="handle-tld">.ai</span>
    </span>
  );
}

/** Inline, compact status line under an action button. Toasts carry the full story. */
export function TxStatus({ state }: { state: TxState }) {
  if (state.status === "idle" || state.status === "simulating") return null;
  if (state.status === "error")
    return (
      <p className="field-msg err">
        {state.message}
        {state.hash && <> · <a href={explorerTx(state.hash)} target="_blank" rel="noreferrer">tx ↗</a></>}
      </p>
    );
  if (state.status === "signing") return <p className="field-msg muted">Waiting for your agent to preview, confirm and send…</p>;
  if (state.status === "pending")
    return <p className="field-msg muted">Pending · <a href={explorerTx(state.hash)} target="_blank" rel="noreferrer">tx ↗</a></p>;
  return <p className="field-msg ok">Confirmed · <a href={explorerTx(state.hash)} target="_blank" rel="noreferrer">tx ↗</a></p>;
}

export function RiskNotice({ compact = false }: { compact?: boolean }) {
  return (
    <div className={`notice ${compact ? "notice-compact" : ""}`}>
      <span className="notice-label">Risk</span>
      <p>
        Prizes are posted and funded by users, not by Agentic Quest. No promised return, no yield, no project token. Gas is
        never refunded. Smart contracts can have bugs — only lock what you can afford to lose.
      </p>
    </div>
  );
}

/** One tick per slot (grouped into at most 40 ticks). Filled ticks = slots still claimable. */
export function Ticks({ left, total }: { left: number; total: number }) {
  const n = Math.max(1, Math.min(40, total));
  const on = total > 0 ? Math.round((left / total) * n) : 0;
  return (
    <span className="ticks" role="img" aria-label={`${left} of ${total} slots left`}>
      {Array.from({ length: n }, (_, i) => <i key={i} className={i < on ? "on" : ""} />)}
    </span>
  );
}

/** Chunky progress bar: fill = share of slots still claimable. */
export function Bar({ left, total }: { left: number; total: number }) {
  const pct = total > 0 ? Math.max(0, Math.min(100, (left / total) * 100)) : 0;
  return <div className="q-bar" role="img" aria-label={`${left} of ${total} slots left`}><i style={{ width: `${pct}%` }} /></div>;
}

export type BadgeTone = "ok" | "warn" | "muted" | "accent" | "err";
export function Badge({ tone, children }: { tone: BadgeTone; children: ReactNode }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

export function Stat({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return (
    <div className="stat">
      <div className="stat-label">{label}</div>
      <div className="stat-value num">{value}</div>
      {sub && <div className="stat-sub">{sub}</div>}
    </div>
  );
}

export function Progress({ value, max }: { value: number; max: number }) {
  const pct = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  return (
    <div className="progress" role="progressbar" aria-valuenow={value} aria-valuemax={max}>
      <div style={{ width: `${pct}%` }} />
    </div>
  );
}

export function Field({ label, hint, error, children, aside }: { label: ReactNode; hint?: ReactNode; error?: string; children: ReactNode; aside?: ReactNode }) {
  return (
    <div className={`field ${error ? "field-invalid" : ""}`}>
      <div className="field-label">
        <span>{label}</span>
        {aside && <span className="field-aside">{aside}</span>}
      </div>
      {children}
      {error ? <p className="field-msg err">{error}</p> : hint ? <p className="field-msg muted">{hint}</p> : null}
    </div>
  );
}

export function Logo({ size = 26 }: { size?: number }) {
  // Original mark: a bracketed check (a verified entry in a ledger). No container box.
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <path d="M9 6H5v20h4M23 6h4v20h-4" stroke="var(--ink)" strokeWidth="2.6" strokeLinecap="square" />
      <path d="M10.5 16.5l3.5 3.5 7.5-8" stroke="var(--green)" strokeWidth="3" strokeLinecap="square" />
    </svg>
  );
}
