import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";
import { explorerTx } from "../config";

export type ToastTone = "info" | "pending" | "success" | "error";
export type Toast = { id: string; tone: ToastTone; title: string; body?: string; hash?: string };

type Ctx = { push: (t: Omit<Toast, "id"> & { id?: string }) => string; dismiss: (id: string) => void };
const ToastCtx = createContext<Ctx>({ push: () => "", dismiss: () => {} });

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const dismiss = useCallback((id: string) => setToasts((ts) => ts.filter((t) => t.id !== id)), []);
  const push = useCallback(
    (t: Omit<Toast, "id"> & { id?: string }) => {
      const id = t.id ?? Math.random().toString(36).slice(2);
      setToasts((ts) => [...ts.filter((x) => x.id !== id), { ...t, id }].slice(-4));
      if (t.tone === "success" || t.tone === "error" || t.tone === "info") {
        setTimeout(() => dismiss(id), t.tone === "error" ? 9000 : 6000);
      }
      return id;
    },
    [dismiss],
  );
  const value = useMemo(() => ({ push, dismiss }), [push, dismiss]);
  return (
    <ToastCtx.Provider value={value}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast toast-${t.tone}`}>
            <span className="toast-dot" />
            <div className="toast-body">
              <div className="toast-title">{t.title}</div>
              {t.body && <div className="toast-text">{t.body}</div>}
              {t.hash && (
                <a href={explorerTx(t.hash)} target="_blank" rel="noreferrer" className="toast-link">
                  View on explorer ↗
                </a>
              )}
            </div>
            <button className="toast-x" aria-label="Dismiss" onClick={() => dismiss(t.id)}>×</button>
          </div>
        ))}
      </div>
    </ToastCtx.Provider>
  );
}

export const useToasts = () => useContext(ToastCtx);
