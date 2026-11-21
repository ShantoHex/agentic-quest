import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // NETWORK=mainnet|testnet (one Vercel env var drives both the site build and the API).
  define: { __NETWORK__: JSON.stringify(process.env.NETWORK || "testnet") },
  build: { target: "es2020", chunkSizeWarningLimit: 1500 },
});
