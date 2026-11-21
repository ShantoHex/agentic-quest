import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

const FRIENDLY: Record<string, string> = {
  NotAgentIdHolder: "This wallet has no Agent ID. Claim one first, then try again.",
  AgentIdMismatch: "The Agent ID registry does not map this handle back to this wallet.",
  InvalidDeadline: "The deadline must be in the future.",
  InvalidMaxWinners: "Max winners must be between 1 and 100.",
  InvalidPrize: "Prize per winner must be greater than zero.",
  InvalidQuestSpec: "Set an answer (hash quest), a verifier contract, or both.",
  InvalidTitle: "Title must be 1–128 bytes.",
  InvalidMetadataURI: "Metadata URI must be at most 256 bytes.",
  TokenNotAllowed: "That token is not on the prize-token allowlist.",
  IncorrectValue: "Wrong amount sent (BNB total must equal prize × winners; ERC-20 quests send 0).",
  QuestNotFound: "Quest not found.",
  QuestExpired: "This quest's deadline has passed.",
  QuestNotExpired: "Refunds open only after the deadline.",
  QuestFull: "All prize slots are already claimed.",
  AlreadyWon: "This Agent ID already won this quest.",
  CommitsClosed: "Someone already revealed the answer, so new commits are closed.",
  NoCommit: "No commit found for this wallet. Commit first.",
  SameBlockReveal: "Wait at least one block after your commit before revealing.",
  LateCommit: "Your commit landed in or after the first reveal block, so it can't win.",
  BadCommit: "Answer/salt/wallet don't match your on-chain commit.",
  WrongSolution: "That answer is not correct.",
  VerifierRejected: "The quest's verifier rejected this proof.",
  NothingToRefund: "Nothing left to refund.",
  HashQuestRequired: "This is a verifier-only quest. Use 'Attempt' instead.",
  VerifierQuestRequired: "This is a hash quest. Use commit → reveal.",
  AddressAlreadyClaimed: "This wallet already claimed its reward.",
  HandleAlreadyClaimed: "This Agent ID already claimed its reward.",
  ClaimPending: "You already have a pending claim. Settle it first.",
  IsPaused: "New claims are paused right now. Pending claims can still be settled.",
  NoAgentId: "This wallet has no Agent ID.",
  NoPendingClaim: "No pending claim found. Start with step 1.",
  PoolInsufficient: "The reward pool is empty right now.",
  TooEarly: "The target block hasn't been mined yet. Wait a few seconds.",
  SignerNotSet: "Claims aren't open yet: the verifier signer isn't set on-chain.",
  VoucherExpired: "Your voucher expired. Verify your post again to get a fresh one.",
  InvalidSignature: "The voucher signature was rejected (wrong signer, other wallet, or edited). Verify again; if it keeps failing, the on-chain signer isn't updated yet.",
  PostAlreadyUsed: "This X post was already used for a claim.",
  AccountAlreadyUsed: "This X account was already used for a claim.",
  HandleTaken: "That handle is already taken.",
  AlreadyRegistered: "This wallet already has a test handle.",
  InvalidHandle: "Handle must be 1–64 chars, lowercase a–z and 0–9 only.",
};

export function explainError(err: unknown): string {
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError)) return "You rejected the request in your wallet.";
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName ?? "";
      if (name && FRIENDLY[name]) return `${FRIENDLY[name]} (${name})`;
      if (revert.reason) return revert.reason;
      if (name) return name;
    }
    return err.shortMessage || err.message;
  }
  return err instanceof Error ? err.message : String(err);
}
