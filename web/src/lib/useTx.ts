import { useCallback, useState } from "react";
import { useConfig } from "wagmi";
import { simulateContract, waitForTransactionReceipt } from "wagmi/actions";
import { encodeFunctionData, type Hex, type TransactionReceipt } from "viem";
import { explainError } from "./errors";
import { useAccount } from "./session";
import { useToasts } from "../components/Toasts";
import { useAgentTx } from "../components/AgentTx";

export type TxState =
  | { status: "idle" }
  | { status: "simulating" }
  | { status: "signing" }
  | { status: "pending"; hash: Hex }
  | { status: "success"; hash: Hex; receipt: TransactionReceipt }
  | { status: "error"; message: string; hash?: Hex };

/**
 * Simulate → hand the unsigned call to the user's own agent (Agentic Wallet `baw contract-call
 * preview` → user confirms → execute) → track the hash they paste back.
 * The site never holds keys and never sends a transaction.
 */
export function useTx(label = "Transaction") {
  const config = useConfig();
  const { address } = useAccount();
  const { request } = useAgentTx();
  const [state, setState] = useState<TxState>({ status: "idle" });
  const { push } = useToasts();

  const send = useCallback(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    async (params: any, onSent?: (hash: Hex) => void): Promise<TransactionReceipt | null> => {
      if (!address) {
        setState({ status: "error", message: "Sign in with your agent wallet first." });
        return null;
      }
      let hash: Hex | undefined;
      const toastId = `${label}-${Date.now()}`;
      try {
        setState({ status: "simulating" });
        // Dry-run from the user's address so obvious reverts show here, before the agent previews it.
        await simulateContract(config, { ...params, account: address });
        const data = encodeFunctionData({ abi: params.abi, functionName: params.functionName, args: params.args });
        setState({ status: "signing" });
        const h = await request({ label, from: address, to: params.address, data, value: params.value ?? 0n });
        if (!h) { setState({ status: "idle" }); return null; }
        hash = h;
        onSent?.(hash);
        setState({ status: "pending", hash });
        push({ id: toastId, tone: "pending", title: `${label}: tracking`, body: "Waiting for confirmation…", hash });
        const receipt = await waitForTransactionReceipt(config, { hash, timeout: 180_000 });
        if (receipt.status !== "success") {
          setState({ status: "error", message: "Transaction reverted on-chain.", hash });
          push({ id: toastId, tone: "error", title: `${label} failed`, body: "Transaction reverted on-chain.", hash });
          return null;
        }
        setState({ status: "success", hash, receipt });
        push({ id: toastId, tone: "success", title: `${label} confirmed`, body: `Block ${receipt.blockNumber.toString()}`, hash });
        return receipt;
      } catch (e) {
        const message = explainError(e);
        setState({ status: "error", message, hash });
        push({ id: toastId, tone: "error", title: `${label} failed`, body: message, hash });
        return null;
      }
    },
    [config, address, label, push, request],
  );

  const reset = useCallback(() => setState({ status: "idle" }), []);
  const busy = state.status === "simulating" || state.status === "signing" || state.status === "pending";
  return { state, send, reset, busy };
}
