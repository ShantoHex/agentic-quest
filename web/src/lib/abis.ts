export const agentIdAbi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "handleOf", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "string" }] },
] as const;

// Testnet MockAgentID only (permissionless test handles).
export const mockAgentIdAbi = [
  ...agentIdAbi,
  { type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ name: "to", type: "address" }, { name: "handle", type: "string" }], outputs: [] },
  { type: "error", name: "HandleTaken", inputs: [] },
  { type: "error", name: "AlreadyRegistered", inputs: [] },
  { type: "error", name: "InvalidHandle", inputs: [] },
] as const;

export const erc20Abi = [
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
] as const;
