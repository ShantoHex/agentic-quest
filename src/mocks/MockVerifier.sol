// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuestVerifier} from "../interfaces/IQuestVerifier.sol";

/// @title MockVerifier
/// @notice Simple allowlist verifier for tests and testnet demos.
contract MockVerifier is IQuestVerifier {
    mapping(address => bool) public allowed;

    function setAllowed(address solver, bool ok) external {
        allowed[solver] = ok;
    }

    function verify(uint256, address solver, bytes calldata) external view returns (bool) {
        return allowed[solver];
    }
}

/// @title ProofMatcherVerifier
/// @notice Accepts a solver if keccak256(proof) matches a pre-set hash.
contract ProofMatcherVerifier is IQuestVerifier {
    bytes32 public expected;

    constructor(bytes32 expected_) {
        expected = expected_;
    }

    function verify(uint256, address, bytes calldata proof) external view returns (bool) {
        return keccak256(proof) == expected;
    }
}
