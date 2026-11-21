import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { getAddress, isAddress, type Address } from "viem";
import { chain } from "../config";

/**
 * Agent sign-in session.
 * The user's own wallet (typically their Agentic Wallet, driven by their AI agent) signs an
 * EIP-712 login challenge; the server checks the signature and returns a READ-ONLY token.
 * Stored in this browser only. It cannot sign or send anything: every transaction is still
 * previewed and confirmed by the wallet owner in their own wallet.
 */
export type Session = { wallet: Address; agentId: string | null; token: string; exp: number };
type Ctx = { session: Session | null; setSession: (s: Session | null) => void; signInOpen: boolean; openSignIn: (o?: boolean) => void };

const KEY = `pq-session-${chain.id}`;
const SessionCtx = createContext<Ctx | null>(null);

function load(): Session | null {
  try {
    const s = JSON.parse(localStorage.getItem(KEY) || "null");
    if (!s || !isAddress(s.wallet) || s.exp * 1000 < Date.now()) return null;
    return { ...s, wallet: getAddress(s.wallet) };
  } catch { return null; }
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, set] = useState<Session | null>(() => (typeof window === "undefined" ? null : load()));
  const [signInOpen, setOpen] = useState(false);
  const setSession = useCallback((s: Session | null) => {
    set(s);
    if (s) localStorage.setItem(KEY, JSON.stringify(s)); else localStorage.removeItem(KEY);
  }, []);
  useEffect(() => {
    if (!session) return;
    const t = setTimeout(() => setSession(null), Math.max(0, session.exp * 1000 - Date.now()));
    return () => clearTimeout(t);
  }, [session, setSession]);
  const value = useMemo(() => ({ session, setSession, signInOpen, openSignIn: (o = true) => setOpen(o) }), [session, setSession, signInOpen]);
  return <SessionCtx.Provider value={value}>{children}</SessionCtx.Provider>;
}

export function useSession() {
  const c = useContext(SessionCtx);
  if (!c) throw new Error("SessionProvider missing");
  return c;
}

/** Drop-in for wagmi's useAccount: the signed-in agent wallet. No browser wallet connection exists. */
export function useAccount() {
  const { session } = useSession();
  return { address: session?.wallet, isConnected: !!session, chainId: chain.id };
}
