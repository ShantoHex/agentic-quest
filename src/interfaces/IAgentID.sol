// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentID
/// @notice Minimal interface for the SPACE ID Agent ID registry on BNB Smart Chain.
/// @dev Mainnet: 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
///      Handles are lowercase a-z0-9, without the `.ai` suffix.
///      Tokens are soulbound (non-transferable); one Agent ID per address.
interface IAgentID {
    /// @notice ERC-721 balance. A value greater than 0 means the address holds an Agent ID.
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Reverse resolution: wallet → handle. Returns "" if none.
    function handleOf(address owner) external view returns (string memory);

    /// @notice Forward resolution: handle → wallet. Returns address(0) if unregistered.
    /// @dev `handle` must already be lowercase; the registry does not normalize.
    function ownerOfHandle(string calldata handle) external view returns (address);
}
