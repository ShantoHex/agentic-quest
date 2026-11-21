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
    address maker = makeAddr("maker"); // creator with an Agent ID, never claims
    address signerAddr;
    uint256 signerPk;
    uint256 n_;

    uint256 constant E18 = 1e18;
    uint256 constant CENT = 1e16;
    string constant POST = "1990000000000000000";
    QuestRewards.Mode constant RANDOM = QuestRewards.Mode.RANDOM;
    QuestRewards.Mode constant FCFS = QuestRewards.Mode.FCFS;

    uint256 rid; // RANDOM: 0.05 (30%), 0.10 (50%), 0.20 (20%); 100 slots; 10 USDT
    uint256 fid; // FCFS: 0.10 x 3 slots

    mapping(uint256 => mapping(address => bytes32)) userSecretOf;
    mapping(uint256 => mapping(address => bytes32)) serverSecretOf;

    struct V {
        bytes32 post;
        bytes32 acct;
        bytes32 sc; // server commit (signed)
        bytes32 uc; // user commit
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
        reg.mint(maker, "maker");
        usdt.mint(owner, 1_000 * E18);

        vm.startPrank(owner);
        qr.setSigner(signerAddr);
        usdt.approve(address(qr), type(uint256).max);
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 10 * CENT, 20 * CENT);
        rid = qr.createQuest(RANDOM, 0, a, c, 100, 0, POST, "Random drop", 10 * E18);
        fid = qr.createQuest(FCFS, 10 * CENT, _nu(), _nc(), 3, 0, POST, "First 3", 1 * E18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------- helpers

    function _nu() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _nc() internal pure returns (uint8[] memory) {
        return new uint8[](0);
    }

    function _tiers3(uint256 a0, uint256 a1, uint256 a2)
        internal
        pure
        returns (uint256[] memory a, uint8[] memory c)
    {
        a = new uint256[](3);
        c = new uint8[](3);
        (a[0], a[1], a[2]) = (a0, a1, a2);
        (c[0], c[1], c[2]) = (30, 50, 20);
    }

    function _publishFcfs(address who, uint256 amt, uint32 n, uint64 end, uint256 budget)
        internal
        returns (uint256 id)
    {
        usdt.mint(who, budget);
        vm.startPrank(who);
        usdt.approve(address(qr), budget); // exact amount, never unlimited
        id = qr.createQuest(FCFS, amt, _nu(), _nc(), n, end, POST, "community quest", budget);
        vm.stopPrank();
    }

    function _publishRandom(
        address who,
        uint256[] memory a,
        uint8[] memory c,
        uint32 n,
        uint64 end,
        uint256 budget
    ) internal returns (uint256 id) {
        usdt.mint(who, budget);
        vm.startPrank(who);
        usdt.approve(address(qr), budget);
        id = qr.createQuest(RANDOM, 0, a, c, n, end, POST, "random quest", budget);
        vm.stopPrank();
    }

    function _publishDefaultRandom(address who, uint32 n, uint64 end, uint256 budget)
        internal
        returns (uint256)
    {
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 10 * CENT, 20 * CENT);
        return _publishRandom(who, a, c, n, end, budget);
    }

    function _v(uint256 id, address user) internal returns (V memory v) {
        ++n_;
        v.post = keccak256(bytes(vm.toString(n_ * 7 + 1)));
        v.acct = keccak256(bytes(vm.toString(n_ * 13 + 5)));
        v.deadline = block.timestamp + 900;
        bytes32 ss = keccak256(abi.encode("server", id, user, n_));
        bytes32 us = keccak256(abi.encode("user", id, user, n_));
        serverSecretOf[id][user] = ss;
        userSecretOf[id][user] = us;
        v.sc = keccak256(abi.encodePacked(ss));
        v.uc = keccak256(abi.encodePacked(us));
        v.sig = _sign(id, user, v.post, v.acct, v.sc, v.deadline, signerPk);
    }

    function _sign(
        uint256 id,
        address user,
        bytes32 post,
        bytes32 acct,
        bytes32 sc,
        uint256 dl,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 h = qr.handleKey(reg.handleOf(user));
        bytes32 d = qr.voucherDigest(id, h, user, post, acct, sc, dl);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _claim(uint256 id, address user) internal returns (uint256) {
        return _claimV(id, user, _v(id, user));
    }

    function _claimV(uint256 id, address user, V memory v) internal returns (uint256) {
        vm.prank(user);
        return qr.claim(id, v.post, v.acct, v.sc, v.uc, v.deadline, v.sig);
    }

    function _expectClaimRevert(uint256 id, address user, V memory v, bytes4 sel) internal {
        vm.prank(user);
        vm.expectRevert(sel);
        qr.claim(id, v.post, v.acct, v.sc, v.uc, v.deadline, v.sig);
    }

    function _settle(uint256 id, address user) internal returns (uint256) {
        vm.prank(user);
        return qr.settle(id, userSecretOf[id][user], serverSecretOf[id][user]);
    }

    function _mkUser(string memory name) internal returns (address u) {
        u = makeAddr(name);
        reg.mint(u, name);
    }

    // ---------------------------------------------------------- setup / defaults

    function test_DomainAndVersion() public view {
        (, string memory name, string memory ver, uint256 cid, address vc,,) = qr.eip712Domain();
        assertEq(name, "ProofQuest QuestRewards");
        assertEq(ver, "2");
        assertEq(cid, block.chainid);
        assertEq(vc, address(qr));
    }

    function test_Defaults_MinBudgetPoint1_MinRewardPoint05() public {
        QuestRewards fresh = new QuestRewards(address(reg), address(usdt), owner);
        assertEq(fresh.minBudget(), 10 * CENT);
        assertEq(fresh.minReward(), 5 * CENT);
        assertTrue(fresh.creationOpen());
        assertTrue(fresh.creatorNeedsAgentId());
        uint8[3] memory d = fresh.defaultTierChances();
        assertEq(uint256(d[0]), 30);
        assertEq(uint256(d[1]), 50);
        assertEq(uint256(d[2]), 20);
        // 6-decimals token: same human values
        MockERC20 six = new MockERC20("USDC", "USDC", 6);
        QuestRewards q6 = new QuestRewards(address(reg), address(six), owner);
        assertEq(q6.minBudget(), 100_000);
        assertEq(q6.minReward(), 50_000);
    }

    function test_CreateCampaignStored() public view {
        QuestRewards.Campaign memory c = qr.getCampaign(fid);
        assertEq(uint8(c.mode), uint8(FCFS));
        assertEq(c.fcfsAmount, 10 * CENT);
        assertEq(c.maxClaims, 3);
        assertEq(c.balance, 1 * E18);
        assertEq(c.targetPostId, POST);
        assertEq(qr.rewardUnit(fid), 10 * CENT);
        (uint256[] memory fa, uint8[] memory fc) = qr.tiersOf(fid);
        assertEq(fa.length + fc.length, 0);

        (uint256[] memory a, uint8[] memory ch) = qr.tiersOf(rid);
        assertEq(a.length, 3);
        assertEq(a[2], 20 * CENT);
        assertEq(uint256(ch[0]) + ch[1] + ch[2], 100);
        assertEq(qr.rewardUnit(rid), 20 * CENT); // max tier
        assertEq(qr.lowestReward(rid), 5 * CENT);
        assertEq(qr.getCampaign(rid).fcfsAmount, 0);
        assertEq(qr.campaignCount(), 2);
        assertEq(qr.totalCampaignBalance(), 11 * E18);
    }

    // ---------------------------------------------------------- publishing / budget

    function test_Publish_AnyAgentIdHolderCreatesAndFundsInOneTx() public {
        uint256 before = usdt.balanceOf(address(qr));
        uint256 id = _publishFcfs(alice, 10 * CENT, 50, uint64(block.timestamp + 1 days), 5 * E18);
        assertEq(qr.creatorOf(id), alice);
        assertEq(qr.getCampaign(id).balance, 5 * E18);
        assertEq(usdt.balanceOf(address(qr)) - before, 5 * E18);
        assertEq(usdt.allowance(alice, address(qr)), 0); // exact approve fully consumed
        assertEq(qr.remainingSlots(id), 50);
        assertEq(_claim(id, bob), 10 * CENT);
    }

    function test_Publish_MinBudgetIsPoint1() public {
        usdt.mint(alice, 1 * E18);
        vm.startPrank(alice);
        usdt.approve(address(qr), 1 * E18);
        vm.expectRevert(QuestRewards.BudgetTooLow.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 2, 0, POST, "x", 10 * CENT - 1);
        vm.expectRevert(QuestRewards.BudgetTooLow.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 2, 0, POST, "x", 0);
        uint256 id = qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 2, 0, POST, "dime", 10 * CENT);
        vm.stopPrank();
        assertEq(qr.remainingSlots(id), 2); // 0.10 / 0.05
        assertEq(_claim(id, bob), 5 * CENT);
        assertEq(_claim(id, carol), 5 * CENT);
        assertEq(qr.getCampaign(id).balance, 0);
    }

    function test_Publish_Point1Budget_RandomMinTiers() public {
        uint256[] memory a = new uint256[](1);
        uint8[] memory c = new uint8[](1);
        (a[0], c[0]) = (5 * CENT, 100);
        uint256 id = _publishRandom(alice, a, c, 10, 0, 10 * CENT);
        assertEq(qr.remainingSlots(id), 2);
    }

    function test_Publish_BudgetMustCoverOneClaim() public {
        usdt.mint(alice, 10 * E18);
        vm.startPrank(alice);
        usdt.approve(address(qr), 10 * E18);
        vm.expectRevert(QuestRewards.BudgetTooLow.selector);
        qr.createQuest(FCFS, 2 * E18, _nu(), _nc(), 5, 0, POST, "x", 1 * E18);
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 10 * CENT, 3 * E18);
        vm.expectRevert(QuestRewards.BudgetTooLow.selector);
        qr.createQuest(RANDOM, 0, a, c, 5, 0, POST, "x", 3 * E18 - 1); // max tier not covered
        uint256 id = qr.createQuest(RANDOM, 0, a, c, 5, 0, POST, "x", 3 * E18);
        vm.stopPrank();
        assertEq(qr.remainingSlots(id), 1);
    }

    function test_Publish_NoMaxBudget() public {
        uint256 big = 10_000_000 * E18;
        uint256 id = _publishFcfs(alice, 10 * E18, 1_000_000, 0, big);
        assertEq(qr.getCampaign(id).balance, big);
        assertEq(qr.remainingSlots(id), 1_000_000);
    }

    function test_Publish_RequiresAgentIdByDefault() public {
        usdt.mint(nobody, 5 * E18);
        vm.startPrank(nobody);
        usdt.approve(address(qr), 5 * E18);
        vm.expectRevert(QuestRewards.NoAgentId.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 5, 0, POST, "x", 1 * E18);
        vm.stopPrank();
        vm.prank(owner);
        qr.setCreationConfig(true, false, 10 * CENT);
        vm.prank(nobody);
        uint256 id = qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 5, 0, POST, "x", 1 * E18);
        assertEq(qr.creatorOf(id), nobody);
    }

    function test_Publish_OwnerCanCloseCreation_OwnerExempt() public {
        vm.prank(owner);
        qr.setCreationConfig(false, true, 10 * CENT);
        usdt.mint(alice, 5 * E18);
        vm.startPrank(alice);
        usdt.approve(address(qr), 5 * E18);
        vm.expectRevert(QuestRewards.CreationClosed.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 5, 0, POST, "x", 1 * E18);
        vm.stopPrank();
        vm.prank(owner);
        uint256 id = qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 5, 0, POST, "x", 1 * E18);
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

    function test_Publish_OptionalPost_SetLaterThenClaim() public {
        usdt.mint(alice, 1 * E18);
        vm.startPrank(alice);
        usdt.approve(address(qr), 1 * E18);
        uint256 id = qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 5, 0, "", "no post yet", 1 * E18);
        assertEq(qr.getCampaign(id).targetPostId, "");
        qr.setTargetPost(id, "111");
        qr.setTargetPost(id, "222"); // can change again before the first claim
        vm.stopPrank();
        assertEq(qr.getCampaign(id).targetPostId, "222");
        assertEq(_claim(id, bob), 5 * CENT);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.AlreadyStarted.selector);
        qr.setTargetPost(id, "333");
    }

    function test_SetTargetPostOnlyCreatorAndValid() public {
        vm.prank(alice);
        vm.expectRevert(QuestRewards.NotCreator.selector);
        qr.setTargetPost(fid, "42");
        vm.startPrank(owner);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.setTargetPost(fid, "");
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.setTargetPost(fid, "12a");
        qr.setTargetPost(fid, "42");
        vm.stopPrank();
        _claim(fid, alice);
        vm.prank(owner);
        vm.expectRevert(QuestRewards.AlreadyStarted.selector);
        qr.setTargetPost(fid, "43");
    }

    function test_CreateBadParams() public {
        vm.startPrank(owner);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 0, 0, POST, "x", E18); // 0 slots
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 1_000_001, 0, POST, "x", E18);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 1, uint64(block.timestamp), POST, "x", E18);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 1, 0, "12a4", "x", E18);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 1, 0, "12345678901234567890123456", "x", E18);
        vm.expectRevert(QuestRewards.BadParams.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 1, 0, POST, "", E18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------- reward rules

    function test_Fcfs_MinRewardPoint05() public {
        vm.startPrank(owner);
        vm.expectRevert(QuestRewards.RewardTooLow.selector);
        qr.createQuest(FCFS, 5 * CENT - 1, _nu(), _nc(), 1, 0, POST, "x", E18);
        vm.expectRevert(QuestRewards.RewardTooLow.selector);
        qr.createQuest(FCFS, 0, _nu(), _nc(), 1, 0, POST, "x", E18);
        uint256 id = qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 1, 0, POST, "x", E18);
        vm.stopPrank();
        assertEq(qr.getCampaign(id).fcfsAmount, 5 * CENT);
    }

    function test_Fcfs_NoMaxReward() public {
        uint256 id = _publishFcfs(alice, 1_000 * E18, 2, 0, 2_000 * E18);
        uint256 before = usdt.balanceOf(bob);
        assertEq(_claim(id, bob), 1_000 * E18);
        assertEq(usdt.balanceOf(bob) - before, 1_000 * E18);
        uint256 huge = _publishFcfs(carol, 1e30, 1, 0, 1e30);
        assertEq(_claim(huge, dave), 1e30);
    }

    function test_Fcfs_TiersNotAllowed() public {
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 10 * CENT, 20 * CENT);
        vm.startPrank(owner);
        vm.expectRevert(QuestRewards.BadTiers.selector);
        qr.createQuest(FCFS, 5 * CENT, a, c, 1, 0, POST, "x", E18);
        vm.expectRevert(QuestRewards.BadTiers.selector);
        qr.createQuest(FCFS, 5 * CENT, _nu(), c, 1, 0, POST, "x", E18);
        vm.stopPrank();
    }

    function test_Random_TierValidation() public {
        vm.startPrank(owner);
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 10 * CENT, 20 * CENT);
        vm.expectRevert(QuestRewards.BadParams.selector); // RANDOM with fcfsAmount
        qr.createQuest(RANDOM, 5 * CENT, a, c, 10, 0, POST, "x", E18);
        vm.expectRevert(QuestRewards.BadTiers.selector); // no tiers
        qr.createQuest(RANDOM, 0, _nu(), _nc(), 10, 0, POST, "x", E18);
        uint8[] memory c2 = new uint8[](2);
        (c2[0], c2[1]) = (50, 50);
        vm.expectRevert(QuestRewards.BadTiers.selector); // length mismatch
        qr.createQuest(RANDOM, 0, a, c2, 10, 0, POST, "x", E18);
        c[2] = 19; // sum 99
        vm.expectRevert(QuestRewards.BadTiers.selector);
        qr.createQuest(RANDOM, 0, a, c, 10, 0, POST, "x", E18);
        c[2] = 21; // sum 101
        vm.expectRevert(QuestRewards.BadTiers.selector);
        qr.createQuest(RANDOM, 0, a, c, 10, 0, POST, "x", E18);
        (c[0], c[1], c[2]) = (0, 80, 20); // zero chance tier
        vm.expectRevert(QuestRewards.BadTiers.selector);
        qr.createQuest(RANDOM, 0, a, c, 10, 0, POST, "x", E18);
        (c[0], c[1], c[2]) = (30, 50, 20);
        a[1] = 5 * CENT - 1; // below min
        vm.expectRevert(QuestRewards.RewardTooLow.selector);
        qr.createQuest(RANDOM, 0, a, c, 10, 0, POST, "x", E18);
        uint256[] memory a6 = new uint256[](6);
        uint8[] memory c6 = new uint8[](6);
        for (uint256 i; i < 6; ++i) {
            a6[i] = 5 * CENT;
            c6[i] = i == 0 ? 50 : 10;
        }
        vm.expectRevert(QuestRewards.BadTiers.selector); // more than 5 tiers
        qr.createQuest(RANDOM, 0, a6, c6, 10, 0, POST, "x", E18);
        vm.stopPrank();
    }

    function test_Random_OneToFiveTiersAndCustomChances() public {
        uint256[] memory a1 = new uint256[](1);
        uint8[] memory c1 = new uint8[](1);
        (a1[0], c1[0]) = (7 * CENT, 100);
        uint256 one = _publishRandom(alice, a1, c1, 5, 0, 1 * E18);
        assertEq(qr.rewardUnit(one), 7 * CENT);
        _claim(one, bob);
        vm.roll(block.number + 3);
        assertEq(_settle(one, bob), 7 * CENT); // single tier = deterministic

        uint256[] memory a5 = new uint256[](5);
        uint8[] memory c5 = new uint8[](5);
        (a5[0], a5[1], a5[2], a5[3], a5[4]) = (5 * CENT, 1 * E18, 6 * CENT, 2 * E18, 9 * CENT);
        (c5[0], c5[1], c5[2], c5[3], c5[4]) = (1, 9, 40, 25, 25);
        uint256 five = _publishRandom(alice, a5, c5, 5, 0, 10 * E18);
        assertEq(qr.rewardUnit(five), 2 * E18); // max, not last
        assertEq(qr.lowestReward(five), 5 * CENT); // min, not first
        assertEq(qr.remainingSlots(five), 5);
    }

    function test_Random_UnlimitedMaxTier() public {
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 1 * E18, 500 * E18);
        uint256 id = _publishRandom(alice, a, c, 10, 0, 1_000 * E18);
        assertEq(qr.remainingSlots(id), 2); // 1000 / 500 max tier
        _claim(id, bob);
        assertEq(qr.getCampaign(id).reserved, 500 * E18);
        vm.roll(block.number + 3);
        uint256 amt = _settle(id, bob);
        assertTrue(amt == 5 * CENT || amt == 1 * E18 || amt == 500 * E18);
        assertEq(qr.getCampaign(id).reserved, 0);
        assertEq(qr.getCampaign(id).balance, 1_000 * E18 - amt);
    }

    // ---------------------------------------------------------- FCFS claims

    function test_Fcfs_PaysFixedAmountInOneTx() public {
        uint256 before = usdt.balanceOf(alice);
        assertEq(_claim(fid, alice), 10 * CENT);
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

    function test_Fcfs_CommitsIgnoredZeroOk() public {
        V memory v = _v(fid, alice);
        v.uc = bytes32(0);
        v.sc = bytes32(0);
        v.sig = _sign(fid, alice, v.post, v.acct, bytes32(0), v.deadline, signerPk);
        assertEq(_claimV(fid, alice, v), 10 * CENT);
    }

    function test_Fcfs_FirstNOnly() public {
        _claim(fid, alice);
        _claim(fid, bob);
        _claim(fid, carol);
        assertEq(qr.remainingSlots(fid), 0);
        _expectClaimRevert(fid, dave, _v(fid, dave), QuestRewards.NoSlotsLeft.selector);
        (bool ok, string memory why) = qr.canClaim(fid, dave);
        assertFalse(ok);
        assertEq(why, "no slots left");
    }

    function test_Fcfs_StopsWhenBudgetRunsOut() public {
        uint256 id = _publishFcfs(maker, 50 * CENT, 10, 0, 1 * E18);
        assertEq(qr.remainingSlots(id), 2);
        _claim(id, alice);
        _claim(id, bob);
        assertEq(qr.remainingSlots(id), 0);
        (bool ok, string memory why) = qr.canClaim(id, carol);
        assertFalse(ok);
        assertEq(why, "reward pool empty");
        _expectClaimRevert(id, carol, _v(id, carol), QuestRewards.PoolInsufficient.selector);
    }

    function test_Fcfs_OnePerAgentIdAndAddress() public {
        _claim(fid, alice);
        _expectClaimRevert(fid, alice, _v(fid, alice), QuestRewards.AddressAlreadyClaimed.selector);
    }

    function test_Fcfs_SameHandleDifferentCaseBlocked() public {
        MockHandleRegistry flex = new MockHandleRegistry();
        QuestRewards q2 = new QuestRewards(address(flex), address(usdt), owner);
        flex.set(alice, "alice");
        flex.set(bob, "ALICE");
        vm.startPrank(owner);
        q2.setSigner(signerAddr);
        usdt.approve(address(q2), type(uint256).max);
        uint256 id = q2.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 10, 0, POST, "x", E18);
        vm.stopPrank();
        bytes32 h = q2.handleKey("alice");
        uint256 dl = block.timestamp + 60;
        bytes32 d = q2.voucherDigest(id, h, alice, bytes32("p1"), bytes32("a1"), 0, dl);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, d);
        vm.prank(alice);
        q2.claim(id, bytes32("p1"), bytes32("a1"), 0, 0, dl, abi.encodePacked(r, s, v));
        d = q2.voucherDigest(id, h, bob, bytes32("p2"), bytes32("a2"), 0, dl);
        (v, r, s) = vm.sign(signerPk, d);
        vm.prank(bob);
        vm.expectRevert(QuestRewards.HandleAlreadyClaimed.selector);
        q2.claim(id, bytes32("p2"), bytes32("a2"), 0, 0, dl, abi.encodePacked(r, s, v));
    }

    // ---------------------------------------------------------- vouchers

    function test_PostUsedGloballyAcrossCampaigns() public {
        V memory v = _v(fid, alice);
        _claimV(fid, alice, v);
        V memory w = _v(rid, alice);
        w.post = v.post;
        w.sig = _sign(rid, alice, w.post, w.acct, w.sc, w.deadline, signerPk);
        _expectClaimRevert(rid, alice, w, QuestRewards.PostAlreadyUsed.selector);
    }

    function test_AccountUsedPerCampaign() public {
        V memory v = _v(fid, alice);
        _claimV(fid, alice, v);
        V memory w = _v(fid, bob);
        w.acct = v.acct;
        w.sig = _sign(fid, bob, w.post, w.acct, w.sc, w.deadline, signerPk);
        _expectClaimRevert(fid, bob, w, QuestRewards.AccountAlreadyUsed.selector);
        // same X account is fine on another campaign
        V memory x = _v(rid, bob);
        x.acct = v.acct;
        x.sig = _sign(rid, bob, x.post, x.acct, x.sc, x.deadline, signerPk);
        _claimV(rid, bob, x);
    }

    function test_SameUserCanClaimEachCampaignOnce() public {
        _claim(fid, alice);
        _claim(rid, alice);
        assertTrue(qr.addressClaimed(fid, alice));
        (bool exists,,,,,) = qr.pendingClaim(rid, alice);
        assertTrue(exists);
    }

    function test_VoucherForOtherCampaignRejected() public {
        V memory v = _v(rid, alice);
        _expectClaimRevert(fid, alice, v, QuestRewards.InvalidSignature.selector);
    }

    function test_VoucherForOtherUserRejected() public {
        V memory v = _v(fid, alice);
        _expectClaimRevert(fid, bob, v, QuestRewards.InvalidSignature.selector);
    }

    function test_VoucherWrongSignerRejected() public {
        V memory v = _v(fid, alice);
        (, uint256 badPk) = makeAddrAndKey("evil");
        v.sig = _sign(fid, alice, v.post, v.acct, v.sc, v.deadline, badPk);
        _expectClaimRevert(fid, alice, v, QuestRewards.InvalidSignature.selector);
    }

    function test_VoucherExpired() public {
        V memory v = _v(fid, alice);
        vm.warp(v.deadline + 1);
        _expectClaimRevert(fid, alice, v, QuestRewards.VoucherExpired.selector);
    }

    function test_BadSignatureLength() public {
        V memory v = _v(fid, alice);
        v.sig = hex"1234";
        _expectClaimRevert(fid, alice, v, QuestRewards.InvalidSignature.selector);
    }

    function test_HighSRejected() public {
        V memory v = _v(fid, alice);
        bytes32 d =
            qr.voucherDigest(fid, qr.handleKey("alice"), alice, v.post, v.acct, v.sc, v.deadline);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(signerPk, d);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        v.sig = abi.encodePacked(r, bytes32(n - uint256(s)), vv == 27 ? uint8(28) : uint8(27));
        _expectClaimRevert(fid, alice, v, QuestRewards.InvalidSignature.selector);
    }

    function test_SignerNotSet() public {
        vm.prank(owner);
        qr.setSigner(address(0));
        _expectClaimRevert(fid, alice, _v(fid, alice), QuestRewards.SignerNotSet.selector);
        (bool ok, string memory why) = qr.canClaim(fid, alice);
        assertFalse(ok);
        assertEq(why, "signer not set");
    }

    function test_NoAgentId() public {
        V memory v = _v(fid, alice);
        _expectClaimRevert(fid, nobody, v, QuestRewards.NoAgentId.selector);
        (bool ok, string memory why) = qr.canClaim(fid, nobody);
        assertFalse(ok);
        assertEq(why, "no Agent ID");
    }

    function test_ReplayAcrossContractRejected() public {
        QuestRewards other = new QuestRewards(address(reg), address(usdt), owner);
        vm.startPrank(owner);
        other.setSigner(signerAddr);
        usdt.approve(address(other), type(uint256).max);
        other.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 5, 0, POST, "x", E18);
        vm.stopPrank();
        V memory v = _v(1, alice); // signed for qr's domain
        vm.prank(alice);
        vm.expectRevert(QuestRewards.InvalidSignature.selector);
        other.claim(1, v.post, v.acct, v.sc, v.uc, v.deadline, v.sig);
    }

    function test_ReplayAcrossChainRejected() public {
        V memory v = _v(fid, alice);
        vm.chainId(56);
        _expectClaimRevert(fid, alice, v, QuestRewards.InvalidSignature.selector);
    }

    function test_UnknownCampaign() public {
        vm.expectRevert(QuestRewards.UnknownCampaign.selector);
        qr.getCampaign(99);
        vm.expectRevert(QuestRewards.UnknownCampaign.selector);
        qr.tiersOf(99);
        vm.expectRevert(QuestRewards.UnknownCampaign.selector);
        qr.fundCampaign(0, 1);
        vm.expectRevert(QuestRewards.UnknownCampaign.selector);
        qr.settle(99, 0, 0);
        (bool ok, string memory why) = qr.canClaim(99, alice);
        assertFalse(ok);
        assertEq(why, "unknown campaign");
        assertEq(qr.remainingSlots(99), 0);
    }

    // ---------------------------------------------------------- pause / end

    function test_GlobalPauseBlocksClaims() public {
        vm.prank(owner);
        qr.pause();
        _expectClaimRevert(fid, alice, _v(fid, alice), QuestRewards.IsPaused.selector);
        vm.prank(owner);
        qr.unpause();
        _claim(fid, alice);
    }

    function test_CampaignPauseBlocksOnlyThatCampaign() public {
        vm.prank(owner);
        qr.setCampaignPaused(fid, true);
        _expectClaimRevert(fid, alice, _v(fid, alice), QuestRewards.CampaignIsPaused.selector);
        _claim(rid, alice);
    }

    function test_CampaignEnded() public {
        uint256 id = _publishFcfs(maker, 5 * CENT, 5, uint64(block.timestamp + 1 hours), E18);
        vm.warp(block.timestamp + 1 hours + 1);
        _expectClaimRevert(id, alice, _v(id, alice), QuestRewards.CampaignEnded.selector);
        (bool ok, string memory why) = qr.canClaim(id, alice);
        assertFalse(ok);
        assertEq(why, "campaign ended");
    }

    function test_SettleAllowedWhilePaused() public {
        _claim(rid, alice);
        vm.startPrank(owner);
        qr.pause();
        qr.setQuestBlocked(rid, true);
        vm.stopPrank();
        vm.roll(block.number + 3);
        assertGt(_settle(rid, alice), 0);
    }

    // ---------------------------------------------------------- RANDOM commit-reveal

    function test_Random_CommitReservesMaxTier() public {
        assertEq(_claim(rid, alice), 0);
        QuestRewards.Campaign memory c = qr.getCampaign(rid);
        assertEq(c.reserved, 20 * CENT);
        assertEq(c.slotsUsed, 1);
        assertEq(c.settled, 0);
        (bool exists, uint64 tb,,, bool ready, bool expired) = qr.pendingClaim(rid, alice);
        assertTrue(exists);
        assertEq(tb, block.number + 2);
        assertFalse(ready);
        assertFalse(expired);
        (bytes32 uc, bytes32 sc) = qr.pendingCommits(rid, alice);
        assertEq(uc, keccak256(abi.encodePacked(userSecretOf[rid][alice])));
        assertEq(sc, keccak256(abi.encodePacked(serverSecretOf[rid][alice])));
        (bool ok, string memory why) = qr.canClaim(rid, alice);
        assertFalse(ok);
        assertEq(why, "claim pending, call settle");
    }

    function test_Random_SettlePaysTierAndReleases() public {
        _claim(rid, alice);
        vm.roll(block.number + 3);
        uint256 before = usdt.balanceOf(alice);
        uint256 amt = _settle(rid, alice);
        assertTrue(amt == 5 * CENT || amt == 10 * CENT || amt == 20 * CENT);
        assertEq(usdt.balanceOf(alice) - before, amt);
        QuestRewards.Campaign memory c = qr.getCampaign(rid);
        assertEq(c.reserved, 0);
        assertEq(c.settled, 1);
        assertEq(c.totalPaid, amt);
        assertEq(qr.rewardOfHandle(rid, qr.handleKey("alice")), amt);
    }

    function test_Random_OutcomeMatchesFormula() public {
        uint256 commitBlock = block.number;
        _claim(rid, alice);
        vm.roll(commitBlock + 5);
        bytes32 bh = blockhash(commitBlock + 2);
        uint256 seed = qr.randomSeed(
            rid,
            bh,
            alice,
            qr.handleKey("alice"),
            userSecretOf[rid][alice],
            serverSecretOf[rid][alice]
        );
        uint256 expected = qr.tierFor(rid, seed);
        assertEq(_settle(rid, alice), expected);
    }

    function test_Random_TooEarly() public {
        _claim(rid, alice);
        vm.roll(block.number + 2); // == targetBlock
        vm.prank(alice);
        vm.expectRevert(QuestRewards.TooEarly.selector);
        qr.settle(rid, userSecretOf[rid][alice], serverSecretOf[rid][alice]);
    }

    function test_Random_NoPending() public {
        vm.prank(alice);
        vm.expectRevert(QuestRewards.NoPendingClaim.selector);
        qr.settle(rid, 0, 0);
        vm.expectRevert(QuestRewards.NoPendingClaim.selector);
        qr.settleExpired(rid, alice);
    }

    function test_Random_BadRevealsRejected() public {
        _claim(rid, alice);
        vm.roll(block.number + 3);
        bytes32 us = userSecretOf[rid][alice];
        bytes32 ss = serverSecretOf[rid][alice];
        vm.startPrank(alice);
        vm.expectRevert(QuestRewards.BadReveal.selector);
        qr.settle(rid, bytes32(uint256(us) ^ 1), ss); // wrong user secret
        vm.expectRevert(QuestRewards.BadReveal.selector);
        qr.settle(rid, us, bytes32(uint256(ss) ^ 1)); // wrong server secret
        vm.expectRevert(QuestRewards.BadReveal.selector);
        qr.settle(rid, ss, us); // swapped
        vm.stopPrank();
        assertGt(_settle(rid, alice), 0);
    }

    function test_Random_MissingCommitRejected() public {
        V memory v = _v(rid, alice);
        v.uc = bytes32(0);
        _expectClaimRevert(rid, alice, v, QuestRewards.MissingCommit.selector);
        V memory w = _v(rid, alice);
        w.sc = bytes32(0);
        w.sig = _sign(rid, alice, w.post, w.acct, 0, w.deadline, signerPk);
        _expectClaimRevert(rid, alice, w, QuestRewards.MissingCommit.selector);
    }

    function test_Random_ClaimantCannotSwapServerCommit() public {
        // Claimant replaces the signed server commit with one whose secret they know.
        V memory v = _v(rid, alice);
        v.sc = keccak256(abi.encodePacked(bytes32("mine")));
        _expectClaimRevert(rid, alice, v, QuestRewards.InvalidSignature.selector);
    }

    function test_Random_OthersCannotSettleOrStealPayout() public {
        _claim(rid, alice);
        vm.roll(block.number + 3);
        bytes32 us = userSecretOf[rid][alice];
        bytes32 ss = serverSecretOf[rid][alice];
        vm.prank(bob); // even with leaked secrets, bob has no pending claim
        vm.expectRevert(QuestRewards.NoPendingClaim.selector);
        qr.settle(rid, us, ss);
        vm.expectRevert(QuestRewards.NotExpired.selector);
        qr.settleExpired(rid, alice);
    }

    function test_Random_ExpiredFallsBackToLowest_NoHistory() public {
        _claim(rid, alice);
        vm.roll(block.number + 2 + 257); // BLOCKHASH window passed, no EIP-2935 contract here
        (,,,, bool ready, bool expired) = qr.pendingClaim(rid, alice);
        assertTrue(ready && expired);
        vm.prank(alice);
        assertEq(qr.settle(rid, 0, 0), 5 * CENT); // reveals ignored once expired
        assertEq(qr.getCampaign(rid).reserved, 0);
    }

    function test_Random_HistoryContractExtendsWindow() public {
        MockHistory h = new MockHistory();
        vm.etch(qr.HISTORY_STORAGE(), address(h).code);
        uint256 commitBlock = block.number;
        _claim(rid, alice);
        uint256 target = commitBlock + 2;
        bytes32 fake = keccak256("historic hash");
        MockHistory(qr.HISTORY_STORAGE()).set(target, fake);
        vm.roll(target + 1000); // past 256, inside 8191
        (,,,, bool ready, bool expired) = qr.pendingClaim(rid, alice);
        assertTrue(ready);
        assertFalse(expired);
        uint256 seed = qr.randomSeed(
            rid,
            fake,
            alice,
            qr.handleKey("alice"),
            userSecretOf[rid][alice],
            serverSecretOf[rid][alice]
        );
        assertEq(_settle(rid, alice), qr.tierFor(rid, seed));
    }

    function test_Random_HistoryWindowEndsAtLowest() public {
        MockHistory h = new MockHistory();
        vm.etch(qr.HISTORY_STORAGE(), address(h).code);
        uint256 commitBlock = block.number;
        _claim(rid, alice);
        MockHistory(qr.HISTORY_STORAGE()).set(commitBlock + 2, keccak256("x"));
        vm.roll(commitBlock + 2 + 8192);
        (,,,,, bool expired) = qr.pendingClaim(rid, alice);
        assertTrue(expired);
        assertEq(qr.settleExpired(rid, alice), 5 * CENT); // anyone may finalize
        assertTrue(qr.addressClaimed(rid, alice));
    }

    function test_Random_SettleExpiredByAnyonePaysClaimant() public {
        _claim(rid, alice);
        vm.roll(block.number + 300);
        uint256 before = usdt.balanceOf(alice);
        vm.prank(bob);
        assertEq(qr.settleExpired(rid, alice), 5 * CENT);
        assertEq(usdt.balanceOf(alice) - before, 5 * CENT);
        assertEq(qr.getCampaign(rid).reserved, 0);
        vm.expectRevert(QuestRewards.NoPendingClaim.selector);
        qr.settleExpired(rid, alice);
    }

    function test_Random_WithholdingNeverBeatsLowest() public {
        // The fallback is always the minimum tier, so withholding a reveal can never win more.
        (uint256[] memory a, uint8[] memory c) = _tiers3(9 * CENT, 5 * CENT, 3 * E18);
        uint256 id = _publishRandom(alice, a, c, 10, 0, 30 * E18);
        _claim(id, bob);
        vm.roll(block.number + 400);
        vm.prank(bob);
        assertEq(qr.settle(id, 0, 0), 5 * CENT);
    }

    function test_Random_SeedDependsOnEveryInput() public view {
        bytes32 h = qr.handleKey("alice");
        uint256 s0 = qr.randomSeed(1, bytes32("b"), alice, h, bytes32("u"), bytes32("s"));
        assertTrue(s0 != qr.randomSeed(2, bytes32("b"), alice, h, bytes32("u"), bytes32("s")));
        assertTrue(s0 != qr.randomSeed(1, bytes32("c"), alice, h, bytes32("u"), bytes32("s")));
        assertTrue(s0 != qr.randomSeed(1, bytes32("b"), bob, h, bytes32("u"), bytes32("s")));
        assertTrue(s0 != qr.randomSeed(1, bytes32("b"), alice, h, bytes32("v"), bytes32("s")));
        assertTrue(s0 != qr.randomSeed(1, bytes32("b"), alice, h, bytes32("u"), bytes32("t")));
        assertTrue(
            s0 != qr.randomSeed(1, bytes32("b"), alice, bytes32("x"), bytes32("u"), bytes32("s"))
        );
    }

    function testFuzz_Random_ServerAloneCannotFixOutcome(bytes32 serverSecret, bytes32 bhA)
        public
        view
    {
        // With the server secret fixed, the outcome still varies with the claimant's secret,
        // which the server only sees as a hash at commit time.
        vm.assume(bhA != bytes32(0));
        bytes32 h = qr.handleKey("alice");
        uint256 hits;
        for (uint256 i; i < 40; ++i) {
            uint256 s = qr.randomSeed(rid, bhA, alice, h, bytes32(i + 1), serverSecret);
            if (qr.tierFor(rid, s) == 20 * CENT) ++hits;
        }
        assertLt(hits, 40); // not every user secret yields the top tier
    }

    function testFuzz_TierForDefaultChances(uint256 seed) public view {
        uint256 r = seed % 100;
        uint256 got = qr.tierFor(rid, seed);
        if (r < 30) assertEq(got, 5 * CENT);
        else if (r < 80) assertEq(got, 10 * CENT);
        else assertEq(got, 20 * CENT);
    }

    function testFuzz_TierForCustomChances(uint8 c0, uint8 c1, uint256 seed) public {
        c0 = uint8(bound(c0, 1, 98));
        c1 = uint8(bound(c1, 1, 99 - c0));
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 6 * CENT, 7 * CENT);
        (c[0], c[1], c[2]) = (c0, c1, 100 - c0 - c1);
        uint256 id = _publishRandom(alice, a, c, 10, 0, 1 * E18);
        uint256 r = seed % 100;
        uint256 got = qr.tierFor(id, seed);
        if (r < c0) assertEq(got, 5 * CENT);
        else if (r < uint256(c0) + c1) assertEq(got, 6 * CENT);
        else assertEq(got, 7 * CENT);
    }

    function test_Random_TierFrequenciesRoughlyMatchChances() public view {
        uint256[3] memory cnt;
        for (uint256 i; i < 2000; ++i) {
            uint256 amt = qr.tierFor(rid, uint256(keccak256(abi.encode(i))));
            if (amt == 5 * CENT) ++cnt[0];
            else if (amt == 10 * CENT) ++cnt[1];
            else ++cnt[2];
        }
        assertApproxEqAbs(cnt[0], 600, 90);
        assertApproxEqAbs(cnt[1], 1000, 110);
        assertApproxEqAbs(cnt[2], 400, 80);
    }

    function test_Random_PendingBlocksSecondCommit() public {
        _claim(rid, alice);
        _expectClaimRevert(rid, alice, _v(rid, alice), QuestRewards.ClaimPending.selector);
    }

    function test_Random_AfterSettleCannotClaimAgain() public {
        _claim(rid, alice);
        vm.roll(block.number + 3);
        _settle(rid, alice);
        _expectClaimRevert(rid, alice, _v(rid, alice), QuestRewards.AddressAlreadyClaimed.selector);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.NoPendingClaim.selector);
        qr.settle(rid, 0, 0); // no second roll
    }

    function test_Random_PoolMustCoverMaxTier() public {
        uint256 id = _publishDefaultRandom(maker, 10, 0, 50 * CENT); // covers 2 x 0.20
        _claim(id, alice);
        _claim(id, bob);
        assertEq(qr.remainingSlots(id), 0); // 0.10 free < 0.20
        _expectClaimRevert(id, carol, _v(id, carol), QuestRewards.PoolInsufficient.selector);
    }

    function test_Random_SlotsCap() public {
        uint256 id = _publishDefaultRandom(maker, 2, 0, 5 * E18);
        _claim(id, alice);
        _claim(id, bob);
        _expectClaimRevert(id, carol, _v(id, carol), QuestRewards.NoSlotsLeft.selector);
    }

    function test_Random_NeverOwesMoreThanFunded() public {
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 2 * E18, 7 * E18);
        uint256 id = _publishRandom(maker, a, c, 100, 0, 20 * E18); // 2 reservations of 7
        address[3] memory us = [alice, bob, carol];
        _claim(id, us[0]);
        _claim(id, us[1]);
        _expectClaimRevert(id, us[2], _v(id, us[2]), QuestRewards.PoolInsufficient.selector);
        QuestRewards.Campaign memory k = qr.getCampaign(id);
        assertLe(k.reserved, k.balance);
        vm.roll(block.number + 3);
        uint256 paid = _settle(id, us[0]) + _settle(id, us[1]);
        assertEq(qr.getCampaign(id).balance, 20 * E18 - paid);
        assertEq(usdt.balanceOf(address(qr)), qr.totalCampaignBalance());
    }

    function testFuzz_Random_NeverOwesMoreThanFunded(uint256 maxTier, uint256 budget, uint8 n)
        public
    {
        maxTier = bound(maxTier, 5 * CENT, 1e30);
        budget = bound(budget, maxTier < 10 * CENT ? 10 * CENT : maxTier, maxTier * 4 + 10 * CENT);
        n = uint8(bound(n, 1, 6));
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 5 * CENT, maxTier);
        uint256 id = _publishRandom(maker, a, c, 50, 0, budget);
        for (uint256 i; i < n; ++i) {
            address u = _mkUser(string(abi.encodePacked("f", vm.toString(i))));
            if (qr.remainingSlots(id) == 0) break;
            _claim(id, u);
            QuestRewards.Campaign memory k = qr.getCampaign(id);
            assertLe(k.reserved, k.balance);
        }
        vm.roll(block.number + 3);
        for (uint256 i; i < n; ++i) {
            address u = makeAddr(string(abi.encodePacked("f", vm.toString(i))));
            (bool exists,,,,,) = qr.pendingClaim(id, u);
            if (exists) _settle(id, u);
        }
        assertEq(qr.getCampaign(id).reserved, 0);
        assertEq(usdt.balanceOf(address(qr)), qr.totalCampaignBalance());
    }

    // ---------------------------------------------------------- creator / owner powers

    function test_Creator_OnlyCreatorControlsOwnQuest() public {
        uint256 a = _publishFcfs(alice, 10 * CENT, 50, 0, 5 * E18);
        uint256 b = _publishFcfs(bob, 10 * CENT, 50, 0, 5 * E18);
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
        vm.startPrank(alice);
        qr.setTargetPost(a, "42");
        qr.setCampaignPaused(a, true);
        qr.withdrawCampaignLeftover(a, 5 * E18, alice);
        vm.expectRevert(QuestRewards.NotCreator.selector);
        qr.setCampaignPaused(b, true);
        vm.stopPrank();
        assertEq(usdt.balanceOf(alice), 5 * E18);
        assertEq(qr.getCampaign(b).balance, 5 * E18);
    }

    function test_Creator_WithdrawOnlyAfterEndOrWhenPaused() public {
        uint256 id = _publishFcfs(alice, 10 * CENT, 50, uint64(block.timestamp + 1 days), 5 * E18);
        vm.prank(alice);
        vm.expectRevert(QuestRewards.StillActive.selector);
        qr.withdrawCampaignLeftover(id, 1, alice);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        qr.withdrawCampaignLeftover(id, 1 * E18, alice);
        assertEq(qr.getCampaign(id).balance, 4 * E18);
    }

    function test_Creator_CannotWithdrawReserved() public {
        (uint256[] memory a, uint8[] memory c) = _tiers3(5 * CENT, 1 * E18, 3 * E18);
        uint256 id = _publishRandom(alice, a, c, 50, 0, 5 * E18);
        _claim(id, bob); // reserves 3
        vm.startPrank(alice);
        qr.setCampaignPaused(id, true);
        vm.expectRevert(QuestRewards.AmountTooHigh.selector);
        qr.withdrawCampaignLeftover(id, 2 * E18 + 1, alice);
        qr.withdrawCampaignLeftover(id, 2 * E18, alice);
        vm.stopPrank();
        vm.roll(block.number + 3);
        assertGt(_settle(id, bob), 0); // bob still gets paid in full
    }

    function test_Creator_CannotClaimOwnQuest() public {
        uint256 id = _publishFcfs(alice, 10 * CENT, 50, 0, 5 * E18);
        (bool ok, string memory why) = qr.canClaim(id, alice);
        assertFalse(ok);
        assertEq(why, "creator cannot claim own quest");
        _expectClaimRevert(id, alice, _v(id, alice), QuestRewards.CreatorCannotClaim.selector);
    }

    function test_Owner_CannotWithdrawCreatorFunds() public {
        uint256 id = _publishFcfs(alice, 10 * CENT, 50, 0, 5 * E18);
        vm.startPrank(owner);
        qr.pause();
        vm.expectRevert(QuestRewards.NotCreator.selector);
        qr.withdrawCampaignLeftover(id, 1, owner);
        assertEq(qr.unallocated(), 0);
        vm.expectRevert(QuestRewards.AmountTooHigh.selector);
        qr.withdrawUnallocated(1, owner);
        vm.stopPrank();
        vm.prank(alice);
        qr.withdrawCampaignLeftover(id, 5 * E18, alice);
        assertEq(usdt.balanceOf(alice), 5 * E18);
    }

    function test_Owner_ConfigDoesNotChangeExistingQuest() public {
        vm.prank(owner);
        qr.setCreationConfig(true, true, 500 * E18);
        (uint256[] memory a,) = qr.tiersOf(rid);
        assertEq(a[2], 20 * CENT);
        assertEq(qr.getCampaign(fid).fcfsAmount, 10 * CENT);
        assertEq(_claim(fid, alice), 10 * CENT);
    }

    function test_Owner_BlockQuestStopsClaimsCreatorCanExit() public {
        uint256 id = _publishFcfs(alice, 10 * CENT, 50, 0, 5 * E18);
        vm.prank(bob);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.setQuestBlocked(id, true);
        vm.prank(owner);
        qr.setQuestBlocked(id, true);
        (bool ok, string memory why) = qr.canClaim(id, bob);
        assertFalse(ok);
        assertEq(why, "quest blocked");
        _expectClaimRevert(id, bob, _v(id, bob), QuestRewards.QuestIsBlocked.selector);
        vm.startPrank(alice);
        qr.setCampaignPaused(id, false);
        qr.withdrawCampaignLeftover(id, 5 * E18, alice);
        vm.stopPrank();
    }

    function test_OwnerOnlyAdmin() public {
        vm.startPrank(alice);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.setSigner(alice);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.pause();
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.unpause();
        vm.expectRevert(QuestRewards.NotCreator.selector);
        qr.setCampaignPaused(fid, true);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.setQuestBlocked(fid, true);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        qr.withdrawUnallocated(1, alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------- isolation / reentrancy

    function test_Isolation_ClaimsOnlyDebitOwnQuest() public {
        uint256 a = _publishFcfs(alice, 50 * CENT, 100, 0, 5 * E18); // 10 slots by budget
        uint256 b = _publishFcfs(bob, 10 * CENT, 100, 0, 5 * E18);
        uint256 total = qr.totalCampaignBalance();
        for (uint256 i; i < 10; ++i) {
            _claim(a, _mkUser(string(abi.encodePacked("u", vm.toString(i)))));
        }
        assertEq(qr.getCampaign(a).balance, 0);
        address extra = _mkUser("extra");
        _expectClaimRevert(a, extra, _v(a, extra), QuestRewards.PoolInsufficient.selector);
        assertEq(qr.getCampaign(b).balance, 5 * E18);
        assertEq(qr.totalCampaignBalance(), total - 5 * E18);
        assertEq(usdt.balanceOf(address(qr)), qr.totalCampaignBalance());
    }

    function test_Isolation_RandomReserveCannotUseOtherQuest() public {
        uint256 a = _publishDefaultRandom(alice, 100, 0, 5 * E18);
        vm.startPrank(alice);
        qr.setCampaignPaused(a, true);
        qr.withdrawCampaignLeftover(a, 5 * E18 - 10 * CENT, alice); // leaves 0.10 < 0.20 max
        qr.setCampaignPaused(a, false);
        vm.stopPrank();
        _expectClaimRevert(a, bob, _v(a, bob), QuestRewards.PoolInsufficient.selector);
    }

    function test_Reentrancy_CreateQuestPullCannotReenter() public {
        usdt.mint(alice, 10 * E18);
        vm.prank(alice);
        usdt.approve(address(qr), 5 * E18);
        usdt.setReenter(address(qr), abi.encodeCall(QuestRewards.fundCampaign, (rid, 1)));
        vm.prank(alice);
        vm.expectRevert();
        qr.createQuest(FCFS, 5 * CENT, _nu(), _nc(), 5, 0, POST, "x", 5 * E18);
        assertEq(qr.campaignCount(), 2);
    }

    function test_Reentrancy_TokenCallbackCannotReenter() public {
        vm.prank(owner);
        qr.setCampaignPaused(fid, true);
        usdt.setReenter(
            address(qr), abi.encodeCall(QuestRewards.withdrawCampaignLeftover, (fid, 1, owner))
        );
        vm.prank(owner);
        vm.expectRevert();
        qr.withdrawCampaignLeftover(fid, 1 * E18, owner);
        assertEq(qr.getCampaign(fid).balance, 1 * E18);
    }

    // ---------------------------------------------------------- funds

    function test_WithdrawLeftoverOnlyUnreserved() public {
        _claim(rid, alice); // reserves 0.20
        vm.startPrank(owner);
        qr.setCampaignPaused(rid, true);
        vm.expectRevert(QuestRewards.AmountTooHigh.selector);
        qr.withdrawCampaignLeftover(rid, 10 * E18, owner);
        qr.withdrawCampaignLeftover(rid, 10 * E18 - 20 * CENT, owner);
        vm.stopPrank();
        assertEq(qr.availableOf(rid), 0);
    }

    function test_WithdrawLeftoverZeroChecks() public {
        vm.startPrank(owner);
        qr.setCampaignPaused(fid, true);
        vm.expectRevert(QuestRewards.ZeroAddress.selector);
        qr.withdrawCampaignLeftover(fid, 1, address(0));
        vm.expectRevert(QuestRewards.ZeroAmount.selector);
        qr.withdrawCampaignLeftover(fid, 0, owner);
        vm.stopPrank();
    }

    function test_WithdrawUnallocated() public {
        usdt.mint(address(qr), 3 * E18); // stray transfer
        assertEq(qr.unallocated(), 3 * E18);
        vm.prank(owner);
        qr.withdrawUnallocated(3 * E18, owner);
        assertEq(qr.unallocated(), 0);
        assertEq(usdt.balanceOf(address(qr)), qr.totalCampaignBalance());
    }

    function test_AnyoneCanFund() public {
        usdt.mint(bob, 2 * E18);
        vm.startPrank(bob);
        usdt.approve(address(qr), 2 * E18);
        qr.fundCampaign(fid, 2 * E18);
        vm.expectRevert(QuestRewards.ZeroAmount.selector);
        qr.fundCampaign(fid, 0);
        vm.stopPrank();
        assertEq(qr.getCampaign(fid).balance, 3 * E18);
        assertEq(qr.creatorOf(fid), owner); // funding does not transfer control
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
        _settle(rid, carol);
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

/// @dev Stand-in for the EIP-2935 history contract: raw 32-byte block number in, hash out.
contract MockHistory {
    mapping(uint256 => bytes32) public hashes;

    function set(uint256 n, bytes32 h) external {
        hashes[n] = h;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        uint256 n = abi.decode(data, (uint256));
        bytes32 h = hashes[n];
        require(h != bytes32(0), "out of range");
        return abi.encode(h);
    }
}
