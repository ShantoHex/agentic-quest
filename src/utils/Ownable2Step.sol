// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Ownable2Step
/// @notice Two-step ownership transfer. Used only for the prize-token whitelist.
abstract contract Ownable2Step {
    address public owner;
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error Unauthorized();
    error OwnerZeroAddress();

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert OwnerZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Start a transfer. `newOwner` must call {acceptOwnership}.
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert OwnerZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept a pending ownership transfer.
    function acceptOwnership() public {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address old = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, msg.sender);
    }

    /// @notice Irreversibly drop ownership (locks the prize-token whitelist).
    function renounceOwnership() public onlyOwner {
        pendingOwner = address(0);
        address old = owner;
        owner = address(0);
        emit OwnershipTransferred(old, address(0));
    }
}
