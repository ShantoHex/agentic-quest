// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {QuestRewards} from "../../src/QuestRewards.sol";

/// @dev Run with: forge test --match-path test/fork/* --fork-url https://bsc-dataseed.bnbchain.org
///      Checks QuestRewards against the REAL Agent ID registry and BSC-USD on BSC mainnet. Skipped without a fork.
contract MainnetRegistryForkTest is Test {
    address constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant HOLDER = 0xBBdDa61bfCEd693C4469d9BDBB654Ef4c25f6bd1;

    function test_RealRegistryAndUsdt() public {
        if (block.chainid != 56) return;
        address owner = makeAddr("owner");
        QuestRewards qr = new QuestRewards(REGISTRY, USDT, owner);
        assertEq(qr.tokenDecimals(), 18);
        assertEq(qr.tier0(), 5e16);
        assertEq(qr.minBudget(), 1e18);
        deal(USDT, owner, 5e18);
        vm.startPrank(owner);
        qr.setSigner(makeAddr("signer"));
        (bool s,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(qr), 5e18));
        assertTrue(s);
        qr.createQuest(QuestRewards.Mode.FCFS, 1e17, 10, 0, "", "fork", 5e18); // owner: no Agent ID needed
        vm.stopPrank();
        (bool ok, string memory why) = qr.canClaim(1, HOLDER);
        assertTrue(ok, why); // real Agent ID check passed
        (ok, why) = qr.canClaim(1, makeAddr("random"));
        assertEq(why, "no Agent ID");

        // permissionless publishing with the REAL registry: holder can, non-holder can't
        deal(USDT, HOLDER, 5e18);
        vm.startPrank(HOLDER);
        (s,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(qr), 5e18));
        assertTrue(s);
        uint256 id = qr.createQuest(QuestRewards.Mode.RANDOM, 0, 25, 0, "", "holder quest", 5e18);
        vm.stopPrank();
        assertEq(qr.creatorOf(id), HOLDER);
        assertEq(qr.remainingSlots(id), 25);
        address stranger = makeAddr("stranger");
        deal(USDT, stranger, 5e18);
        vm.startPrank(stranger);
        (s,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(qr), 5e18));
        vm.expectRevert(QuestRewards.NoAgentId.selector);
        qr.createQuest(QuestRewards.Mode.RANDOM, 0, 25, 0, "", "x", 5e18);
        vm.stopPrank();
        assertEq(qr.remainingSlots(1), 10);
    }
}
