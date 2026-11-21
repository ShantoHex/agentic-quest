// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IQuestVerifier
/// @notice Optional external check for a Proof Quest ("proof of interaction").
/// @dev MUST be a view (or pure) function. ProofQuest never sends value to the
///      verifier and never expects the verifier to move funds.
interface IQuestVerifier {
    /// @param questId The ProofQuest quest id.
    /// @param solver  The Agent ID holder attempting the quest.
    /// @param proof   Verifier-specific payload (may be empty).
    /// @return ok     True if `solver` satisfies the quest condition.
    function verify(uint256 questId, address solver, bytes calldata proof)
        external
        view
        returns (bool ok);
}
