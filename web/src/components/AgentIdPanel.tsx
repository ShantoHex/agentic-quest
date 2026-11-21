import { useState } from "react";
import { AGENT_ID_REGISTRY } from "../config";
import { mockAgentIdAbi } from "../lib/abis";
import { useAccount } from "../lib/session";
import { useTx } from "../lib/useTx";
import { TxStatus } from "./ui";

/** Testnet only: mint a test Agent ID on the mock registry. Hidden on mainnet. */
export function TestHandleMint({ onDone }: { onDone: () => void }) {
  const { address } = useAccount();
  const [h, setH] = useState("");
  const tx = useTx("Mint test Agent ID");
  const valid = /^[a-z0-9]{1,64}$/.test(h);
  return (
    <div className="field">
      <span className="small muted">Testnet: mint a test Agent ID for this wallet.</span>
      <div className="row-gap">
        <input aria-label="Test handle" placeholder="name" value={h} onChange={(e) => setH(e.target.value.toLowerCase().replace(/\.ai$/, ""))} />
        <button className="btn btn-secondary" disabled={!valid || tx.busy} onClick={async () => { if (await tx.send({ address: AGENT_ID_REGISTRY, abi: mockAgentIdAbi, functionName: "mint", args: [address!, h] })) onDone(); }}>Mint .ai</button>
      </div>
      <TxStatus state={tx.state} />
    </div>
  );
}
