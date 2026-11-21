// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentID} from "../interfaces/IAgentID.sol";

/// @title MockAgentID
/// @notice Deployable stand-in for the SPACE ID Agent ID registry.
/// @dev The real registry may not exist on BSC testnet (chain 97). Use this
///      mock there, and the official registry on mainnet.
///      Tokens are soulbound: there is no transfer function.
contract MockAgentID is IAgentID {
    mapping(address => string) private _handleOf;
    mapping(string => address) private _ownerOfHandle;
    mapping(address => uint256) private _balanceOf;

    event Registered(address indexed owner, string handle);

    error HandleTaken();
    error AlreadyRegistered();
    error InvalidHandle();
    error InvalidOwner();

    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }

    function handleOf(address account) external view returns (string memory) {
        return _handleOf[account];
    }

    function ownerOfHandle(string calldata handle) external view returns (address) {
        return _ownerOfHandle[handle];
    }

    /// @notice Register a soulbound handle for `to`. Handle must be lowercase a-z0-9, no `.ai`.
    function mint(address to, string calldata handle) external {
        if (to == address(0)) revert InvalidOwner();
        bytes memory raw = bytes(handle);
        uint256 len = raw.length;
        if (len == 0 || len > 64) revert InvalidHandle();
        for (uint256 i; i < len; ++i) {
            bytes1 c = raw[i];
            bool ok = (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a);
            if (!ok) revert InvalidHandle();
        }
        if (bytes(_handleOf[to]).length != 0) revert AlreadyRegistered();
        if (_ownerOfHandle[handle] != address(0)) revert HandleTaken();

        _handleOf[to] = handle;
        _ownerOfHandle[handle] = to;
        _balanceOf[to] = 1;
        emit Registered(to, handle);
    }
}
