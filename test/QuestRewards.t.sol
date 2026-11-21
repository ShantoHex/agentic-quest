// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {QuestRewards} from "../src/QuestRewards.sol";
import {MockAgentID} from "../src/mocks/MockAgentID.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {Ownable2Step} from "../src/utils/Ownable2Step.sol";

contract QuestRewardsTest is Test {
    QuestRewards qr;
    MockAgentID reg;
    MockERC20 usdt;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address nobody = makeAddr("nobody");
    address signerAddr;
    uint256 signerPk;
    uint256 n_;

    uint256 constant E18 = 1e18;
    uint256 constant CENT = 1e16;
    string constant POST = "1990000000000000000";

    uint256 rid; // RANDOM campaign
    uint256 fid; // FCFS campaign: 0.10 x 3 slots

    struct V {
        bytes32 post;
        bytes32 acct;
        uint256 deadline;
        bytes sig;
    }

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_800_000_000);
        reg = new MockAgentID();
        usdt = new MockERC20("Test USDT", "USDT", 18);
        (signerAddr, signerPk) = makeAddrAndKey("voucher-signer");
        qr = new QuestRewards(address(reg), address(usdt), owner);
        reg.mint(alice, "alice");
        reg.mint(bob, "bob");
        reg.mint(carol, "carol");
        reg.mint(dave, "dave");
        usdt.mint(owner, 1_000 * E18);

        vm.startPrank(owner);
        qr.setSigner(signerAddr);
        qr.setCreationConfig(true, true, 0); // legacy tests fund separately; min budget tested below
        usdt.approve(address(qr), type(uint256).max);
        rid = qr.createQuest(QuestRewards.Mode.RANDOM, 0, 100, 0, POST, "Random drop", 0);
        fid = qr.createQuest(QuestRewards.Mode.FCFS, 10 * CENT, 3, 0, POST, "First 3 get 0.10", 0);
        qr.fundCampaign(rid, 10 * E18);
        qr.fundCampaign(fid, 1 * E18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------- helpers

    function _v(uint256 id, address user) internal returns (V memory v) {
        ++n_;
        v.post = keccak256(bytes(vm.toString(n_ * 7 + 1)));
        v.acct = keccak256(bytes(vm.toString(n_ * 13 + 5)));
        v.deadline = block.timestamp + 900;
        v.sig = _sign(id, user, v.post, v.acct, v.deadline, signerPk);
    }

    function _sign(uint256 id, address user, bytes32 post, bytes32 acct, uint256 dl, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = qr.handleKey(reg.handleOf(user));
        bytes32 d = qr.voucherDigest(id, h, user, post, acct, dl);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _claim(uint256 id, address user) internal returns (uint256) {
        V memory v = _v(id, user);
        vm.prank(user);
        return qr.claim(id, v.post, v.acct, v.deadline, v.sig);
    }

    function _claimV(uint256 id, address user, V memory v) internal returns (uint256) {
        vm.prank(user);
        return qr.claim(id, v.post, v.acct, v.deadline, v.sig);
    }

    // ---------------------------------------------------------- setup / create

    function test_TiersAndDomain() public view {
        (uint256[5] memory a, uint8[5] memory o) = qr.tiers();
        assertEq(a[0], 5 * CENT);
        assertEq(a[4], 20 * CENT);
        assertEq(uint256(o[0]) + o[1] + o[2] + o[3] + o[4], 100);
        (, string memory name, string memory ver, uint256 cid, address vc,,) = qr.eip712Domain();
        assertEq(name, "ProofQuest QuestRewards");
        assertEq(ver, "1");
        assertEq(cid, block.chainid);
        assertEq(vc, address(qr));
    }

    function test_CreateCampaignStored() public view {
        QuestRewards.Campaign memory c = qr.getCampaign(fid);
        assertEq(uint8(c.mode), uint8(QuestRewards.Mode.FCFS));
        assertEq(c.fcfsAmount, 10 * CENT);
        assertEq(c.maxClaims, 3);
        assertEq(c.balance, 1 * E18);
        assertEq(c.targetPostId, POST);
        assertEq(c.title, "First 3 get 0.10");
        assertEq(qr.campaignCount(), 2);
        assertEq(qr.totalCampaignBalance(), 11 * E18);
    }

    // ---------------------------------------------------------- permissionless publishing

    function _publish(address who, QuestRewards.Mode m, uint256 amt, uint32 n, uint64 end, uint256 budget)
        internal
        returns (uint256 id)
    {
        usdt.mint(who, budget);
        vm.startPrank(who);
        usdt.approve(address(qr), budget); // exact amount, never unlimited
        id = qr.createQuest(m, amt, n, end, POST, "community quest", budget);
        vm.stopPrank();
    }

    function _minBudget5() internal {
        vm.prank(owner);
        qr.setCreationConfig(true, true, 5 * E18);
    }

    function test_Publish_AnyAgentIdHolderCreatesAndFundsInOneTx() public {
        _minBudget5();
        uint256 before = usdt.balanceOf(address(qr));
        uint256 id = _publish(alice, QuestRewards.Mode.FCFS, 10 * CENT, 50, uint64(block.timestamp + 1 days), 5 * E18);
        assertEq(qr.creatorOf(id), alice);
        assertEq(qr.getCampaign(id).balance, 5 * E18);
        assertEq(usdt.balanceOf(address(qr)) - before, 5 * E18);
        assertEq(usdt.allowance(alice, address(qr)), 0); // exact approve fully consumed
        assertEq(qr.remainingSlots(id), 50);
        // someone else claims it
        assertEq(_claim(id, bob), 10 * CENT);
    }

    function test_Publish_DefaultMinBudgetIs1Token() public {
        QuestRewards fresh = new QuestRewards(address(reg), address(usdt), owner);
        assertEq(fresh.minBudget(), 1 * E18);
        assertTrue(fresh.creationOpen());
        assertTrue(fresh.creatorNeedsAgentId());
    }

    function _minBudget1() internal {
        vm.prank(owner);
        qr.setCreationConfig(true, true, 1 * E18);
    }

    function test_Publish_OneDollarBudget_Fcfs10Slots() public {
        _minBudget1();
        usdt.mint(alice, 1 * E18);
        vm.startPrank(alice);
        usdt.approve(address(qr), 1 * E18);
        vm.expectRevert(QuestRewards.BudgetTooLow.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, 10 * CENT, 10, 0, POST, "x", 1 * E18 - 1);
        uint256 id = qr.createQuest(QuestRewards.Mode.FCFS, 10 * CENT, 10, 0, POST, "one dollar", 1 * E18);
        vm.stopPrank();
        assertEq(qr.remainingSlots(id), 10);
        address[11] memory us;
        for (uint256 i; i < 10; ++i) {
            us[i] = makeAddr(string(abi.encodePacked("d", vm.toString(i))));
            reg.mint(us[i], string(abi.encodePacked("d", vm.toString(i))));
            assertEq(_claim(id, us[i]), 10 * CENT);
        }
        assertEq(qr.getCampaign(id).balance, 0);
        assertEq(qr.remainingSlots(id), 0);
    }

    function test_Publish_OneDollarBudget_RandomCoversFiveReservations() public {
        _minBudget1();
        uint256 id = _publish(alice, QuestRewards.Mode.RANDOM, 0, 100, 0, 1 * E18);
        assertEq(qr.remainingSlots(id), 5); // 1.00 / 0.20 max tier
        // on-chain, a reward above the budget is allowed but covers 0 slots until topped up
        // (the /api/publish endpoint rejects this case off-chain)
        uint256 f = _publish(bob, QuestRewards.Mode.FCFS, 2 * E18, 5, 0, 1 * E18);
        assertEq(qr.remainingSlots(f), 0);
    }

    function test_Publish_NoMaxBudget() public {
        _minBudget1();
        uint256 big = 10_000_000 * E18;
        uint256 id = _publish(alice, QuestRewards.Mode.FCFS, 10 * E18, 1_000_000, 0, big);
        assertEq(qr.getCampaign(id).balance, big);
        assertEq(qr.remainingSlots(id), 1_000_000);
    }

    function test_Publish_MinBudgetEnforced() public {
        _minBudget5();
        usdt.mint(alice, 10 * E18);
        vm.startPrank(alice);
        usdt.approve(address(qr), 10 * E18);
        vm.expectRevert(QuestRewards.BudgetTooLow.selector);
        qr.createQuest(QuestRewards.Mode.RANDOM, 0, 10, 0, POST, "x", 5 * E18 - 1);
        vm.expectRevert(QuestRewards.BudgetTooLow.selector);
        qr.createQuest(QuestRewards.Mode.RANDOM, 0, 10, 0, POST, "x", 0);
        qr.createQuest(QuestRewards.Mode.RANDOM, 0, 10, 0, POST, "x", 5 * E18);
        vm.stopPrank();
    }

    function test_Publish_CapsApplyToCreators() public {
        _minBudget5();
        usdt.mint(alice, 100 * E18);
        vm.startPrank(alice);
        usdt.approve(address(qr), 100 * E18);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, 10 * E18 + 1, 5, 0, POST, "x", 60 * E18);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.RANDOM, 1, 5, 0, POST, "x", 5 * E18);
        vm.stopPrank();
    }

    function test_Publish_RequiresAgentIdByDefault() public {
        _minBudget5();
        usdt.mint(nobody, 5 * E18);
        vm.startPrank(nobody);
        usdt.approve(address(qr), 5 * E18);
        vm.expectRevert(QuestRewards.NoAgentId.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, CENT, 5, 0, POST, "x", 5 * E18);
        vm.stopPrank();
        // owner can turn the requirement off
        vm.prank(owner);
        qr.setCreationConfig(true, false, 5 * E18);
        vm.prank(nobody);
        uint256 id = qr.createQuest(QuestRewards.Mode.FCFS, CENT, 5, 0, POST, "x", 5 * E18);
        assertEq(qr.creatorOf(id), nobody);
    }

    function test_Publish_OwnerCanCloseCreation_OwnerExempt() public {
        vm.prank(owner);
        qr.setCreationConfig(false, true, 5 * E18);
        usdt.mint(alice, 5 * E18);
        vm.startPrank(alice);
        usdt.approve(address(qr), 5 * E18);
        vm.expectRevert(QuestRewards.CreationClosed.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, CENT, 5, 0, POST, "x", 5 * E18);
        vm.stopPrank();
        vm.prank(owner); // owner has no Agent ID and creation is closed: still allowed
        uint256 id = qr.createQuest(QuestRewards.Mode.FCFS, CENT, 5, 0, POST, "x", 5 * E18);
        assertEq(qr.creatorOf(id), owner);
    }

    function test_Publish_ConfigOnlyOwnerAndBounded() public {
        vm.prank(alice);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.setCreationConfig(true, false, 0);
        vm.prank(owner);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.setCreationConfig(true, true, 1_000_000 * E18 + 1);
    }

    function test_Creator_OnlyCreatorControlsOwnQuest() public {
        _minBudget5();
        uint256 a = _publish(alice, QuestRewards.Mode.FCFS, 10 * CENT, 50, 0, 5 * E18);
        uint256 b = _publish(bob, QuestRewards.Mode.FCFS, 10 * CENT, 50, 0, 5 * E18);
        // bob cannot touch alice's quest, nor can the platform owner
        address[2] memory others = [bob, owner];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(QuestRewards.NotCreator.selector);
            qr.setCampaignPaused(a, true);
            vm.expectRevert(QuestRewards.NotCreator.selector);
            qr.setTargetPost(a, "42");
            vm.expectRevert(QuestRewards.NotCreator.selector);
            qr.withdrawCampaignLeftover(a, 1, others[i]);
            vm.stopPrank();
        }
        // alice controls her own
        vm.startPrank(alice);
        qr.setTargetPost(a, "42");
        qr.setCampaignPaused(a, true);
        qr.withdrawCampaignLeftover(a, 5 * E18, alice);
        vm.expectRevert(QuestRewards.NotCreator.selector);
        qr.setCampaignPaused(b, true);
        vm.stopPrank();
        assertEq(usdt.balanceOf(alice), 5 * E18);
        assertEq(qr.getCampaign(b).balance, 5 * E18); // untouched
    }

    function test_Creator_WithdrawOnlyAfterEndOrWhenPaused() public {
        _minBudget5();
        uint256 id = _publish(alice, QuestRewards.Mode.FCFS, 10 * CENT, 50, uint64(block.timestamp + 1 days), 5 * E18);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.StillActive.selector);
        qr.withdrawCampaignLeftover(id, 1, alice);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        qr.withdrawCampaignLeftover(id, 1 * E18, alice);
        assertEq(qr.getCampaign(id).balance, 4 * E18);
    }

    function test_Creator_CannotWithdrawReserved() public {
        _minBudget5();
        uint256 id = _publish(alice, QuestRewards.Mode.RANDOM, 0, 50, 0, 5 * E18);
        _claim(id, bob); // reserves 0.20
        vm.startPrank(alice);
        qr.setCampaignPaused(id, true);
        vm.expectRevert(QuestRewards.AmountTooHigh.selector);
        qr.withdrawCampaignLeftover(id, 5 * E18, alice);
        qr.withdrawCampaignLeftover(id, 5 * E18 - 20 * CENT, alice);
        vm.stopPrank();
        vm.roll(block.number + 3);
        vm.prank(bob);
        assertGt(qr.settle(id), 0); // bob still gets paid
    }

    function test_Creator_CannotClaimOwnQuest() public {
        _minBudget5();
        uint256 id = _publish(alice, QuestRewards.Mode.FCFS, 10 * CENT, 50, 0, 5 * E18);
        (bool ok, string memory why) = qr.canClaim(id, alice);
        assertFalse(ok);
        assertEq(why, "creator cannot claim own quest");
        V memory v = _v(id, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.CreatorCannotClaim.selector);
        qr.claim(id, v.post, v.acct, v.deadline, v.sig);
    }

    function test_Owner_CannotWithdrawCreatorFunds() public {
        _minBudget5();
        uint256 id = _publish(alice, QuestRewards.Mode.FCFS, 10 * CENT, 50, 0, 5 * E18);
        vm.startPrank(owner);
        qr.pause();
        vm.expectRevert(QuestRewards.NotCreator.selector);
        qr.withdrawCampaignLeftover(id, 1, owner);
        // quest funds are not "unallocated"
        assertEq(qr.unallocated(), 0);
        vm.expectRevert(QuestRewards.AmountTooHigh.selector);
        qr.withdrawUnallocated(1, owner);
        vm.stopPrank();
        // global pause never traps creator funds
        vm.prank(alice);
        qr.withdrawCampaignLeftover(id, 5 * E18, alice);
        assertEq(usdt.balanceOf(alice), 5 * E18);
    }

    function test_Owner_BlockQuestStopsClaimsCreatorCanExit() public {
        _minBudget5();
        uint256 id = _publish(alice, QuestRewards.Mode.FCFS, 10 * CENT, 50, 0, 5 * E18);
        vm.prank(bob);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.setQuestBlocked(id, true);
        vm.prank(owner);
        qr.setQuestBlocked(id, true);
        (bool ok, string memory why) = qr.canClaim(id, bob);
        assertFalse(ok);
        assertEq(why, "quest blocked");
        V memory v = _v(id, bob);
        vm.prank(bob);
        vm.expectRevert(QuestRewards.QuestIsBlocked.selector);
        qr.claim(id, v.post, v.acct, v.deadline, v.sig);
        // creator can't unblock by un-pausing, but can withdraw
        vm.startPrank(alice);
        qr.setCampaignPaused(id, false);
        qr.withdrawCampaignLeftover(id, 5 * E18, alice);
        vm.stopPrank();
    }

    function test_Isolation_ClaimsOnlyDebitOwnQuest() public {
        _minBudget5();
        uint256 a = _publish(alice, QuestRewards.Mode.FCFS, 50 * CENT, 100, 0, 5 * E18);  // 10 slots by budget
        uint256 b = _publish(bob, QuestRewards.Mode.FCFS, 10 * CENT, 100, 0, 5 * E18);
        uint256 total = qr.totalCampaignBalance();
        // drain quest a completely
        address[10] memory us;
        for (uint256 i; i < 10; ++i) {
            us[i] = makeAddr(string(abi.encodePacked("u", vm.toString(i))));
            reg.mint(us[i], string(abi.encodePacked("u", vm.toString(i))));
            _claim(a, us[i]);
        }
        assertEq(qr.getCampaign(a).balance, 0);
        assertEq(qr.remainingSlots(a), 0);
        // next claimer on a fails even though the contract holds b's money
        address extra = makeAddr("extra");
        reg.mint(extra, "extra");
        V memory v = _v(a, extra);
        vm.prank(extra);
        vm.expectRevert(QuestRewards.PoolInsufficient.selector);
        qr.claim(a, v.post, v.acct, v.deadline, v.sig);
        assertEq(qr.getCampaign(b).balance, 5 * E18);
        assertEq(qr.totalCampaignBalance(), total - 5 * E18);
        assertEq(usdt.balanceOf(address(qr)), qr.totalCampaignBalance());
    }

    function test_Isolation_RandomReserveCannotUseOtherQuest() public {
        _minBudget5();
        uint256 a = _publish(alice, QuestRewards.Mode.RANDOM, 0, 100, 0, 5 * E18);
        vm.startPrank(alice);
        qr.setCampaignPaused(a, true);
        qr.withdrawCampaignLeftover(a, 5 * E18 - 10 * CENT, alice); // leaves 0.10 < tier4
        qr.setCampaignPaused(a, false);
        vm.stopPrank();
        V memory v = _v(a, bob);
        vm.prank(bob);
        vm.expectRevert(QuestRewards.PoolInsufficient.selector);
        qr.claim(a, v.post, v.acct, v.deadline, v.sig);
    }

    function test_Reentrancy_CreateQuestPullCannotReenter() public {
        _minBudget5();
        usdt.mint(alice, 10 * E18);
        vm.prank(alice);
        usdt.approve(address(qr), 5 * E18);
        usdt.setReenter(address(qr), abi.encodeCall(QuestRewards.fundCampaign, (rid, 1)));
        vm.prank(alice);
        vm.expectRevert();
        qr.createQuest(QuestRewards.Mode.FCFS, CENT, 5, 0, POST, "x", 5 * E18);
        assertEq(qr.campaignCount(), 2);
    }

    function test_Reentrancy_TokenCallbackCannotReenter() public {
        // token that re-enters QuestRewards during transfer
        usdt.mint(owner, 10 * E18);
        vm.startPrank(owner);
        uint256 id = qr.createQuest(QuestRewards.Mode.FCFS, 10 * CENT, 10, 0, POST, "re", 0);
        qr.fundCampaign(id, 1 * E18);
        qr.setCampaignPaused(id, true);
        vm.stopPrank();
        usdt.setReenter(address(qr), abi.encodeCall(QuestRewards.withdrawCampaignLeftover, (id, 1, owner)));
        vm.prank(owner);
        vm.expectRevert(); // inner call hits the nonReentrant guard
        qr.withdrawCampaignLeftover(id, 1 * E18, owner);
        assertEq(qr.getCampaign(id).balance, 1 * E18);
    }

    function test_CreateBadParams() public {
        vm.startPrank(owner);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.RANDOM, 1, 10, 0, POST, "x", 0); // random with amount
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, 0, 10, 0, POST, "x", 0); // fcfs w/o amount
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, 1, 0, 0, POST, "x", 0); // 0 slots
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, 1, 1, uint64(block.timestamp), POST, "x", 0);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, 1, 1, 0, "12a4", "x", 0); // non-numeric post
        // empty target post is allowed at creation (announced later)
        uint256 id = qr.createQuest(QuestRewards.Mode.FCFS, 1, 1, 0, "", "x", 0);
        assertEq(qr.getCampaign(id).targetPostId, "");
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.setTargetPost(id, "");
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, 1, 1, 0, "12345678901234567890123456", "x", 0);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, 1, 1, 0, POST, "", 0);
        vm.stopPrank();
    }

    function test_FcfsAmountCappedAt10Tokens() public {
        assertEq(qr.maxFcfsAmount(), 10 * E18);
        vm.startPrank(owner);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(QuestRewards.Mode.FCFS, 10 * E18 + 1, 1, 0, POST, "too big", 0);
        uint256 id = qr.createQuest(QuestRewards.Mode.FCFS, 10 * E18, 1, 0, POST, "max ok", 0);
        vm.stopPrank();
        assertEq(qr.getCampaign(id).fcfsAmount, 10 * E18);
    }

    function test_ReplayAcrossContractRejected() public {
        // Same voucher fields, other deployment (different verifyingContract) -> invalid.
        QuestRewards other = new QuestRewards(address(reg), address(usdt), owner);
        vm.startPrank(owner);
        other.setSigner(signerAddr);
        other.setCreationConfig(true, true, 0);
        other.createQuest(QuestRewards.Mode.FCFS, CENT, 5, 0, POST, "x", 0);
        usdt.approve(address(other), type(uint256).max);
        other.fundCampaign(1, E18);
        vm.stopPrank();
        V memory v = _v(1, alice); // signed for qr's domain, campaign 1
        vm.prank(alice);
        vm.expectRevert(QuestRewards.InvalidSignature.selector);
        other.claim(1, v.post, v.acct, v.deadline, v.sig);
    }

    function test_ReplayAcrossChainRejected() public {
        V memory v = _v(fid, alice);
        vm.chainId(56);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.InvalidSignature.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, v.sig);
    }

    function test_UnknownCampaign() public {
        vm.expectRevert(QuestRewards.UnknownCampaign.selector);
        qr.getCampaign(99);
        vm.expectRevert(QuestRewards.UnknownCampaign.selector);
        qr.fundCampaign(0, 1);
        (bool ok, string memory why) = qr.canClaim(99, alice);
        assertFalse(ok);
        assertEq(why, "unknown campaign");
        assertEq(qr.remainingSlots(99), 0);
    }

    // ---------------------------------------------------------- FCFS

    function test_Fcfs_PaysFixedAmountInOneTx() public {
        uint256 before = usdt.balanceOf(alice);
        uint256 paid = _claim(fid, alice);
        assertEq(paid, 10 * CENT);
        assertEq(usdt.balanceOf(alice) - before, 10 * CENT);
        assertTrue(qr.addressClaimed(fid, alice));
        assertTrue(qr.handleClaimed(fid, qr.handleKey("alice")));
        assertEq(qr.rewardOfHandle(fid, qr.handleKey("alice")), 10 * CENT);
        QuestRewards.Campaign memory c = qr.getCampaign(fid);
        assertEq(c.slotsUsed, 1);
        assertEq(c.settled, 1);
        assertEq(c.totalPaid, 10 * CENT);
        assertEq(c.balance, 90 * CENT);
        assertEq(qr.remainingSlots(fid), 2);
    }

    function test_Fcfs_FirstNOnly() public {
        _claim(fid, alice);
        _claim(fid, bob);
        _claim(fid, carol);
        assertEq(qr.remainingSlots(fid), 0);
        V memory v = _v(fid, dave);
        vm.prank(dave);
        vm.expectRevert(QuestRewards.NoSlotsLeft.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, v.sig);
        (bool ok, string memory why) = qr.canClaim(fid, dave);
        assertFalse(ok);
        assertEq(why, "no slots left");
    }

    function test_Fcfs_StopsWhenBudgetRunsOut() public {
        vm.prank(owner);
        uint256 id = qr.createQuest(QuestRewards.Mode.FCFS, 50 * CENT, 10, 0, POST, "budget", 0);
        vm.prank(owner);
        qr.fundCampaign(id, 1 * E18); // covers 2 of 10 slots
        assertEq(qr.remainingSlots(id), 2);
        _claim(id, alice);
        _claim(id, bob);
        assertEq(qr.remainingSlots(id), 0);
        (bool ok, string memory why) = qr.canClaim(id, carol);
        assertFalse(ok);
        assertEq(why, "reward pool empty");
        V memory v = _v(id, carol);
        vm.prank(carol);
        vm.expectRevert(QuestRewards.PoolInsufficient.selector);
        qr.claim(id, v.post, v.acct, v.deadline, v.sig);
    }

    function test_Fcfs_OnePerAgentIdAndAddress() public {
        _claim(fid, alice);
        V memory v = _v(fid, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.AddressAlreadyClaimed.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, v.sig);
    }

    function test_Fcfs_SameHandleDifferentCaseBlocked() public {
        // FlexRegistry-like: a second address resolving to "ALICE" must be blocked.
        MockHandleRegistry flex = new MockHandleRegistry();
        QuestRewards q2 = new QuestRewards(address(flex), address(usdt), owner);
        flex.set(alice, "alice");
        flex.set(bob, "ALICE");
        vm.startPrank(owner);
        q2.setSigner(signerAddr);
        q2.setCreationConfig(true, true, 0);
        uint256 id = q2.createQuest(QuestRewards.Mode.FCFS, CENT, 10, 0, POST, "x", 0);
        usdt.approve(address(q2), type(uint256).max);
        q2.fundCampaign(id, E18);
        vm.stopPrank();
        bytes32 h = q2.handleKey("alice");
        bytes32 d = q2.voucherDigest(id, h, alice, bytes32("p1"), bytes32("a1"), block.timestamp + 60);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, d);
        vm.prank(alice);
        q2.claim(id, bytes32("p1"), bytes32("a1"), block.timestamp + 60, abi.encodePacked(r, s, v));
        d = q2.voucherDigest(id, h, bob, bytes32("p2"), bytes32("a2"), block.timestamp + 60);
        (v, r, s) = vm.sign(signerPk, d);
        vm.prank(bob);
        vm.expectRevert(QuestRewards.HandleAlreadyClaimed.selector);
        q2.claim(id, bytes32("p2"), bytes32("a2"), block.timestamp + 60, abi.encodePacked(r, s, v));
    }

    function test_PostUsedGloballyAcrossCampaigns() public {
        V memory v = _v(fid, alice);
        _claimV(fid, alice, v);
        bytes memory sig = _sign(rid, alice, v.post, keccak256("other-acct"), v.deadline, signerPk);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.PostAlreadyUsed.selector);
        qr.claim(rid, v.post, keccak256("other-acct"), v.deadline, sig);
    }

    function test_AccountUsedPerCampaign() public {
        V memory v = _v(fid, alice);
        _claimV(fid, alice, v);
        // same X account, other Agent ID, same campaign -> blocked
        bytes32 p2 = keccak256("post-2");
        bytes memory sig = _sign(fid, bob, p2, v.acct, v.deadline, signerPk);
        vm.prank(bob);
        vm.expectRevert(QuestRewards.AccountAlreadyUsed.selector);
        qr.claim(fid, p2, v.acct, v.deadline, sig);
        // same X account in a different campaign -> allowed
        bytes32 p3 = keccak256("post-3");
        sig = _sign(rid, alice, p3, v.acct, v.deadline, signerPk);
        vm.prank(alice);
        qr.claim(rid, p3, v.acct, v.deadline, sig);
        assertTrue(qr.isAccountUsed(rid, v.acct));
    }

    function test_SameUserCanClaimEachCampaignOnce() public {
        _claim(fid, alice);
        _claim(rid, alice);
        (bool exists,,,,,) = qr.pendingClaim(rid, alice);
        assertTrue(exists);
    }

    // ---------------------------------------------------------- voucher

    function test_VoucherForOtherCampaignRejected() public {
        V memory v = _v(rid, alice); // signed for RANDOM campaign
        vm.prank(alice);
        vm.expectRevert(QuestRewards.InvalidSignature.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, v.sig);
    }

    function test_VoucherForOtherUserRejected() public {
        V memory v = _v(fid, alice);
        vm.prank(bob);
        vm.expectRevert(QuestRewards.InvalidSignature.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, v.sig);
    }

    function test_VoucherWrongSignerRejected() public {
        (, uint256 pk) = makeAddrAndKey("evil");
        bytes32 p = keccak256("p");
        bytes32 a = keccak256("a");
        uint256 dl = block.timestamp + 60;
        bytes memory sig = _sign(fid, alice, p, a, dl, pk);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.InvalidSignature.selector);
        qr.claim(fid, p, a, dl, sig);
    }

    function test_VoucherExpired() public {
        V memory v = _v(fid, alice);
        vm.warp(v.deadline + 1);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.VoucherExpired.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, v.sig);
    }

    function test_BadSignatureLength() public {
        V memory v = _v(fid, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.InvalidSignature.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, hex"1234");
    }

    function test_HighSRejected() public {
        V memory v = _v(fid, alice);
        bytes32 h = qr.handleKey("alice");
        bytes32 d = qr.voucherDigest(fid, h, alice, v.post, v.acct, v.deadline);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(signerPk, d);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 s2 = bytes32(n - uint256(s));
        uint8 v2 = vv == 27 ? 28 : 27;
        vm.prank(alice);
        vm.expectRevert(QuestRewards.InvalidSignature.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, abi.encodePacked(r, s2, v2));
    }

    function test_SignerNotSet() public {
        vm.prank(owner);
        qr.setSigner(address(0));
        V memory v = _v(fid, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.SignerNotSet.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, v.sig);
    }

    function test_NoAgentId() public {
        bytes32 p = keccak256("p");
        vm.prank(nobody);
        vm.expectRevert(QuestRewards.NoAgentId.selector);
        qr.claim(fid, p, p, block.timestamp + 10, new bytes(65));
        (bool ok, string memory why) = qr.canClaim(fid, nobody);
        assertFalse(ok);
        assertEq(why, "no Agent ID");
    }

    // ---------------------------------------------------------- pause / end

    function test_GlobalPauseBlocksClaims() public {
        vm.prank(owner);
        qr.pause();
        V memory v = _v(fid, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.IsPaused.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, v.sig);
        vm.prank(owner);
        qr.unpause();
        _claimV(fid, alice, v);
    }

    function test_CampaignPauseBlocksOnlyThatCampaign() public {
        vm.prank(owner);
        qr.setCampaignPaused(fid, true);
        V memory v = _v(fid, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.CampaignIsPaused.selector);
        qr.claim(fid, v.post, v.acct, v.deadline, v.sig);
        _claim(rid, alice); // other campaign still open
        (bool ok, string memory why) = qr.canClaim(fid, bob);
        assertFalse(ok);
        assertEq(why, "campaign paused");
    }

    function test_CampaignEnded() public {
        vm.prank(owner);
        uint256 id = qr.createQuest(QuestRewards.Mode.FCFS, CENT, 5, uint64(block.timestamp + 100), POST, "short", 0);
        vm.prank(owner);
        qr.fundCampaign(id, E18);
        vm.warp(block.timestamp + 101);
        V memory v = _v(id, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.CampaignEnded.selector);
        qr.claim(id, v.post, v.acct, v.deadline, v.sig);
    }

    function test_SettleAllowedWhilePaused() public {
        _claim(rid, alice);
        vm.prank(owner);
        qr.pause();
        vm.roll(block.number + 3);
        vm.prank(alice);
        uint256 amt = qr.settle(rid);
        assertGt(amt, 0);
    }

    // ---------------------------------------------------------- RANDOM

    function test_Random_CommitReservesMax() public {
        uint256 paid = _claim(rid, alice);
        assertEq(paid, 0);
        QuestRewards.Campaign memory c = qr.getCampaign(rid);
        assertEq(c.reserved, 20 * CENT);
        assertEq(c.slotsUsed, 1);
        assertEq(c.settled, 0);
        (bool exists, uint64 tb,, string memory handle, bool ready,) = qr.pendingClaim(rid, alice);
        assertTrue(exists);
        assertEq(tb, block.number + 2);
        assertEq(handle, "alice");
        assertFalse(ready);
    }

    function test_Random_SettlePaysTierAndReleases() public {
        _claim(rid, alice);
        vm.roll(block.number + 3);
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        uint256 amt = qr.settle(rid);
        assertEq(usdt.balanceOf(alice) - before, amt);
        assertTrue(amt == 5 * CENT || amt == 8 * CENT || amt == 12 * CENT || amt == 15 * CENT || amt == 20 * CENT);
        QuestRewards.Campaign memory c = qr.getCampaign(rid);
        assertEq(c.reserved, 0);
        assertEq(c.balance, 10 * E18 - amt);
        assertEq(c.settled, 1);
        assertTrue(qr.handleClaimed(rid, qr.handleKey("alice")));
        assertEq(qr.totalCampaignBalance(), 11 * E18 - amt);
    }

    function test_Random_TooEarly() public {
        _claim(rid, alice);
        vm.roll(block.number + 2);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.TooEarly.selector);
        qr.settle(rid);
    }

    function test_Random_NoPending() public {
        vm.prank(alice);
        vm.expectRevert(QuestRewards.NoPendingClaim.selector);
        qr.settle(rid);
    }

    function test_Random_ExpiredFallsBackToLowest() public {
        _claim(rid, alice);
        vm.roll(block.number + 2 + 257);
        (,,,,, bool expired) = qr.pendingClaim(rid, alice);
        assertTrue(expired);
        vm.prank(alice);
        uint256 amt = qr.settle(rid);
        assertEq(amt, 5 * CENT);
    }

    function test_Random_PendingBlocksSecondCommit() public {
        _claim(rid, alice);
        V memory v = _v(rid, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.ClaimPending.selector);
        qr.claim(rid, v.post, v.acct, v.deadline, v.sig);
        (bool ok, string memory why) = qr.canClaim(rid, alice);
        assertFalse(ok);
        assertEq(why, "claim pending, call settle");
    }

    function test_Random_AfterSettleCannotClaimAgain() public {
        _claim(rid, alice);
        vm.roll(block.number + 3);
        vm.prank(alice);
        qr.settle(rid);
        V memory v = _v(rid, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.AddressAlreadyClaimed.selector);
        qr.claim(rid, v.post, v.acct, v.deadline, v.sig);
    }

    function test_Random_PoolMustCoverMaxTier() public {
        vm.prank(owner);
        uint256 id = qr.createQuest(QuestRewards.Mode.RANDOM, 0, 10, 0, POST, "tiny", 0);
        vm.prank(owner);
        qr.fundCampaign(id, 19 * CENT);
        assertEq(qr.remainingSlots(id), 0);
        V memory v = _v(id, alice);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.PoolInsufficient.selector);
        qr.claim(id, v.post, v.acct, v.deadline, v.sig);
    }

    function test_Random_SlotsCap() public {
        vm.prank(owner);
        uint256 id = qr.createQuest(QuestRewards.Mode.RANDOM, 0, 1, 0, POST, "one", 0);
        vm.prank(owner);
        qr.fundCampaign(id, E18);
        _claim(id, alice);
        V memory v = _v(id, bob);
        vm.prank(bob);
        vm.expectRevert(QuestRewards.NoSlotsLeft.selector);
        qr.claim(id, v.post, v.acct, v.deadline, v.sig);
    }

    function testFuzz_TierForDistribution(uint256 seed) public view {
        uint256 t = qr.tierFor(seed);
        uint256 r = seed % 100;
        if (r < 50) assertEq(t, 5 * CENT);
        else if (r < 70) assertEq(t, 8 * CENT);
        else if (r < 90) assertEq(t, 12 * CENT);
        else if (r < 95) assertEq(t, 15 * CENT);
        else assertEq(t, 20 * CENT);
    }

    function test_RandomSeedDependsOnCampaign() public view {
        bytes32 bh = keccak256("bh");
        assertTrue(qr.randomSeed(1, bh, alice, bytes32(0)) != qr.randomSeed(2, bh, alice, bytes32(0)));
    }

    // ---------------------------------------------------------- owner money

    function test_WithdrawLeftoverOnlyUnreserved() public {
        _claim(rid, alice); // reserves 0.20
        uint256 free = qr.availableOf(rid);
        assertEq(free, 10 * E18 - 20 * CENT);
        vm.prank(owner);
        qr.setCampaignPaused(rid, true); // creator (here: owner) must pause or wait for the end
        vm.prank(owner);
        vm.expectRevert(QuestRewards.AmountTooHigh.selector);
        qr.withdrawCampaignLeftover(rid, free + 1, owner);
        vm.prank(owner);
        qr.withdrawCampaignLeftover(rid, free, owner);
        assertEq(qr.availableOf(rid), 0);
        // reserved claim still settles
        vm.roll(block.number + 3);
        vm.prank(alice);
        uint256 amt = qr.settle(rid);
        assertGt(amt, 0);
    }

    function test_WithdrawLeftoverOnlyCreator() public {
        vm.prank(alice);
        vm.expectRevert(QuestRewards.NotCreator.selector);
        qr.withdrawCampaignLeftover(fid, 1, alice);
    }

    function test_WithdrawLeftoverZeroChecks() public {
        vm.startPrank(owner);
        vm.expectRevert(QuestRewards.ZeroAddress.selector);
        qr.withdrawCampaignLeftover(fid, 1, address(0));
        vm.expectRevert(QuestRewards.ZeroAmount.selector);
        qr.withdrawCampaignLeftover(fid, 0, owner);
        vm.stopPrank();
    }

    function test_WithdrawUnallocated() public {
        usdt.mint(address(qr), 3 * E18); // direct transfer, not credited
        assertEq(qr.unallocated(), 3 * E18);
        vm.prank(owner);
        vm.expectRevert(QuestRewards.AmountTooHigh.selector);
        qr.withdrawUnallocated(3 * E18 + 1, owner);
        vm.prank(owner);
        qr.withdrawUnallocated(3 * E18, owner);
        assertEq(qr.unallocated(), 0);
        assertEq(usdt.balanceOf(address(qr)), qr.totalCampaignBalance());
    }

    function test_AnyoneCanFund() public {
        usdt.mint(bob, 5 * E18);
        vm.startPrank(bob);
        usdt.approve(address(qr), 5 * E18);
        qr.fundCampaign(fid, 5 * E18);
        vm.stopPrank();
        assertEq(qr.getCampaign(fid).balance, 6 * E18);
        vm.expectRevert(QuestRewards.ZeroAmount.selector);
        qr.fundCampaign(fid, 0);
    }

    function test_SetTargetPostOnlyBeforeFirstClaim() public {
        vm.prank(owner);
        qr.setTargetPost(fid, "123");
        assertEq(qr.getCampaign(fid).targetPostId, "123");
        _claim(fid, alice);
        vm.prank(owner);
        vm.expectRevert(QuestRewards.AlreadyStarted.selector);
        qr.setTargetPost(fid, "456");
        vm.prank(alice);
        vm.expectRevert(QuestRewards.NotCreator.selector);
        qr.setTargetPost(rid, "456");
    }

    function test_OwnerOnlyAdmin() public {
        vm.startPrank(alice);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.setSigner(alice);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.pause();
        vm.expectRevert(QuestRewards.NotCreator.selector);
        qr.setCampaignPaused(fid, true);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.setQuestBlocked(fid, true);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.withdrawUnallocated(1, alice);
        vm.stopPrank();
    }

    function test_CanClaimHappy() public view {
        (bool ok, string memory why) = qr.canClaim(fid, alice);
        assertTrue(ok);
        assertEq(why, "");
    }

    function test_Accounting_Invariant_ManyClaims() public {
        _claim(fid, alice);
        _claim(fid, bob);
        _claim(rid, carol);
        _claim(rid, dave);
        vm.roll(block.number + 3);
        vm.prank(carol);
        qr.settle(rid);
        assertEq(usdt.balanceOf(address(qr)), qr.totalCampaignBalance());
        QuestRewards.Campaign memory r = qr.getCampaign(rid);
        QuestRewards.Campaign memory f = qr.getCampaign(fid);
        assertEq(r.balance + f.balance, qr.totalCampaignBalance());
        assertEq(r.reserved, 20 * CENT); // dave still pending
    }
}

/// @dev Registry whose handles can be mixed-case (to test case-folding).
contract MockHandleRegistry {
    mapping(address => string) public h;

    function set(address a, string calldata s) external {
        h[a] = s;
    }

    function balanceOf(address a) external view returns (uint256) {
        return bytes(h[a]).length > 0 ? 1 : 0;
    }

    function handleOf(address a) external view returns (string memory) {
        return h[a];
    }

    function ownerOfHandle(string calldata) external pure returns (address) {
        return address(0);
    }
}
