import { useEffect, useRef, useState } from "react";
import { Link, NavLink } from "react-router-dom";
import { explorerAddress, NET } from "../config";
import { short } from "../lib/format";
import { useSession } from "../lib/session";
import { Handle, Logo } from "./ui";

export function Header() {
  return (
    <header className="topbar">
      <div className="topbar-inner">
        <Link to="/" className="brand" aria-label="Agentic Quest home">
          <Logo size={24} />
          <span className="wordmark">Agentic<span>Quest</span></span>
        </Link>
        <div className="topbar-right">
          <NavLink to="/publish" className="navlink">Publish</NavLink>
          <NavLink to="/my-quests" className="navlink">My quests</NavLink>
          <span className="netpill" title={`Chain ID ${NET.chainId}`}><span className="netpill-dot" />{NET.name}</span>
          <WalletButton />
        </div>
      </div>
    </header>
  );
}

function WalletButton() {
  const { session, setSession, openSignIn } = useSession();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const close = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, []);
  if (!session) return <button className="btn btn-primary" onClick={() => openSignIn(true)}>Sign in</button>;
  const handle = session.agentId?.replace(/\.ai$/, "") ?? "";
  return (
    <div className="wallet" ref={ref}>
      <button className="btn btn-secondary wallet-btn" onClick={() => setOpen((o) => !o)}>
        {handle ? <Handle handle={handle} /> : <span className="mono">{short(session.wallet)}</span>}
      </button>
      {open && (
        <div className="menu">
          <div className="menu-row"><span className="muted small">Wallet</span><span className="mono small">{short(session.wallet)}</span></div>
          <a className="menu-item" href={explorerAddress(session.wallet)} target="_blank" rel="noreferrer">View on explorer ↗</a>
          <button className="menu-item menu-danger" onClick={() => { setSession(null); setOpen(false); }}>Sign out</button>
        </div>
      )}
    </div>
  );
}
