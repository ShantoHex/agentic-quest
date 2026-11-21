import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { WagmiProvider } from "wagmi";
import App from "./App";
import "@fontsource/bricolage-grotesque/latin-400.css";
import "@fontsource/bricolage-grotesque/latin-500.css";
import "@fontsource/bricolage-grotesque/latin-700.css";
import "@fontsource/bricolage-grotesque/latin-800.css";
import "@fontsource/dm-mono/latin-500.css";
import "./styles.css";
import { ToastProvider } from "./components/Toasts";
import { wagmiConfig } from "./wagmi";
import { SessionProvider } from "./lib/session";
import { AgentTxProvider } from "./components/AgentTx";
import { SignInModal } from "./components/SignIn";

const queryClient = new QueryClient({ defaultOptions: { queries: { refetchOnWindowFocus: false, staleTime: 10_000 } } });

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <ToastProvider>
          <SessionProvider>
            <AgentTxProvider>
              <BrowserRouter>
                <App />
              </BrowserRouter>
              <SignInModal />
            </AgentTxProvider>
          </SessionProvider>
        </ToastProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </React.StrictMode>,
);
