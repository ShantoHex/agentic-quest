// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ProofQuest} from "../src/ProofQuest.sol";
import {Ownable2Step} from "../src/utils/Ownable2Step.sol";
import {MockAgentID} from "../src/mocks/MockAgentID.sol";
import {MockERC20, SilentERC20} from "../src/mocks/MockERC20.sol";
import {MockVerifier} from "../src/mocks/MockVerifier.sol";

contract ProofQuestTest is Test {
    MockAgentID internal registry;
    MockERC20 internal usdt;
    SilentERC20 internal silent;
    MockVerifier internal verifier;
    ProofQuest internal pq;

    address internal owner;
    address internal poster;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave; // no Agent ID

    bytes internal constant ANSWER = "the-secret-answer";
    bytes32 internal solutionHash;
    bytes32 internal constant SALT_A = keccak256("salt-alice");
    bytes32 internal constant SALT_B = keccak256("salt-bob");

    uint128 internal constant PRIZE = 0.5 ether;
    uint32 internal constant WINNERS = 2;

    event QuestCreated(
        uint256 indexed questId,
        address indexed poster,
        string posterHandle,
        address token,
        uint128 prizePerWinner,
        uint32 maxWinners,
        uint64 deadline,
        bytes32 solutionHash,
        address verifier,
        string title,
        string metadataURI
    );
    event Committed(
        uint256 indexed questId, address indexed solver, string solverHandle, bytes32 commitHash
    );
    event Won(
        uint256 indexed questId,
        address indexed solver,
        string solverHandle,
        address token,
        uint128 amount,
        uint32 winnerIndex
    );
    event Refunded(uint256 indexed questId, address indexed poster, address token, uint256 amount);

    function setUp() public {
        owner = makeAddr("owner");
        poster = makeAddr("poster");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");

        registry = new MockAgentID();
        registry.mint(poster, "shanto2021");
        registry.mint(alice, "alice");
        registry.mint(bob, "bob");
        registry.mint(carol, "carol");

        usdt = new MockERC20("Tether USD", "USDT", 18);
        silent = new SilentERC20();
        verifier = new MockVerifier();

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdt);
        tokens[1] = address(silent);
        pq = new ProofQuest(address(registry), owner, tokens);

        solutionHash = keccak256(ANSWER);

        vm.deal(poster, 100 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
        vm.deal(dave, 10 ether);
        usdt.mint(poster, 1_000_000e18);
        silent.mint(poster, 1_000_000e18);
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + 1 days);
    }

    function _commitHash(bytes memory answer, address solver, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(answer, solver, salt));
    }

    function _createBnb(uint32 maxWinners, uint128 prizePerWinner) internal returns (uint256 id) {
        uint256 total = uint256(prizePerWinner) * uint256(maxWinners);
        vm.prank(poster);
        id = pq.createQuest{value: total}(
            address(0),
            prizePerWinner,
            maxWinners,
            _deadline(),
            solutionHash,
            address(0),
            "Find the phrase",
            "ipfs://quest-1"
        );
    }

    function _commitAndRoll(uint256 id, address solver, bytes32 salt) internal {
        bytes32 ch = _commitHash(ANSWER, solver, salt);
        vm.prank(solver);
        pq.commit(id, ch);
        vm.roll(block.number + 1);
    }

    // -------------------------------------------------------------------------
    // Happy path (BNB)
    // -------------------------------------------------------------------------

    function test_happyPath_bnbCommitReveal() public {
        uint256 id = _createBnb(WINNERS, PRIZE);
        assertEq(id, 1);
        assertEq(address(pq).balance, uint256(PRIZE) * WINNERS);

        uint256 aliceBefore = alice.balance;

        _commitAndRoll(id, alice, SALT_A);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Won(id, alice, "alice", address(0), PRIZE, 1);
        pq.reveal(id, ANSWER, SALT_A, "");

        assertEq(alice.balance, aliceBefore + PRIZE);
        assertEq(pq.winsOf("alice"), 1);
        assertEq(pq.earningsOf("alice", address(0)), PRIZE);
        assertTrue(pq.hasWonQuest(id, "alice"));

        // second winner
        bytes32 chB = _commitHash(ANSWER, bob, SALT_B);
        // bob committed before first reveal? In this test alice already revealed.
        // bob must have committed BEFORE first reveal. So this should revert CommitsClosed.
        vm.prank(bob);
        vm.expectRevert(ProofQuest.CommitsClosed.selector);
        pq.commit(id, chB);
    }

    function test_happyPath_twoWinnersCommittedBeforeReveal() public {
        uint256 id = _createBnb(WINNERS, PRIZE);

        bytes32 chA = _commitHash(ANSWER, alice, SALT_A);
        bytes32 chB = _commitHash(ANSWER, bob, SALT_B);
        vm.prank(alice);
        pq.commit(id, chA);
        vm.prank(bob);
        pq.commit(id, chB);
        vm.roll(block.number + 1);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");
        vm.prank(bob);
        pq.reveal(id, ANSWER, SALT_B, "");

        assertEq(alice.balance, aliceBefore + PRIZE);
        assertEq(bob.balance, bobBefore + PRIZE);
        assertEq(pq.winsOf("alice"), 1);
        assertEq(pq.winsOf("bob"), 1);

        string[] memory winners = pq.questWinners(id);
        assertEq(winners.length, 2);
        assertEq(winners[0], "alice");
        assertEq(winners[1], "bob");

        ProofQuest.Quest memory q = pq.getQuest(id);
        assertEq(q.winnerCount, 2);
        assertEq(q.remainingPrize, 0);
        assertEq(address(pq).balance, 0);

        // quest full
        vm.prank(carol);
        vm.expectRevert(ProofQuest.QuestFull.selector);
        pq.commit(id, _commitHash(ANSWER, carol, keccak256("c")));
    }

    function test_helpersMatchHashes() public view {
        assertEq(pq.computeSolutionHash(ANSWER), keccak256(ANSWER));
        assertEq(pq.computeCommitHash(ANSWER, alice, SALT_A), _commitHash(ANSWER, alice, SALT_A));
    }

    // -------------------------------------------------------------------------
    // Front-running
    // -------------------------------------------------------------------------

    function test_frontRun_revealWithoutCommitReverts() public {
        uint256 id = _createBnb(1, PRIZE);
        vm.prank(alice);
        vm.expectRevert(ProofQuest.NoCommit.selector);
        pq.reveal(id, ANSWER, SALT_A, "");
    }

    function test_frontRun_sameBlockCommitAndRevealReverts() public {
        uint256 id = _createBnb(1, PRIZE);
        vm.prank(alice);
        pq.commit(id, _commitHash(ANSWER, alice, SALT_A));
        // no roll
        vm.prank(alice);
        vm.expectRevert(ProofQuest.SameBlockReveal.selector);
        pq.reveal(id, ANSWER, SALT_A, "");
    }

    function test_frontRun_copiedAnswerSameBlockCannotSteal() public {
        uint256 id = _createBnb(1, PRIZE);

        vm.prank(alice);
        pq.commit(id, _commitHash(ANSWER, alice, SALT_A));
        vm.roll(block.number + 1);

        // Attacker sees alice's reveal in the mempool, tries to commit+reveal now.
        vm.prank(bob);
        pq.commit(id, _commitHash(ANSWER, bob, SALT_B));

        // Same-block reveal fails.
        vm.prank(bob);
        vm.expectRevert(ProofQuest.SameBlockReveal.selector);
        pq.reveal(id, ANSWER, SALT_B, "");

        // Honest reveal succeeds and fills the only slot.
        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");

        // Next block the attacker still cannot claim: LateCommit / QuestFull.
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(ProofQuest.QuestFull.selector);
        pq.reveal(id, ANSWER, SALT_B, "");
    }

    function test_frontRun_commitAfterFirstRevealRejected() public {
        uint256 id = _createBnb(WINNERS, PRIZE);
        _commitAndRoll(id, alice, SALT_A);
        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");

        vm.prank(bob);
        vm.expectRevert(ProofQuest.CommitsClosed.selector);
        pq.commit(id, _commitHash(ANSWER, bob, SALT_B));
    }

    function test_frontRun_overwriteAfterSeeingRevealCannotWinRemainingSlot() public {
        // maxWinners = 2; alice committed early; bob committed a dummy, then
        // tries to overwrite after seeing the reveal in the same block.
        uint256 id = _createBnb(2, PRIZE);

        vm.prank(alice);
        pq.commit(id, _commitHash(ANSWER, alice, SALT_A));
        vm.prank(bob);
        pq.commit(id, keccak256("dummy"));
        vm.roll(block.number + 1);

        // alice reveals (makes the answer public this block)
        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");

        // bob overwrites commit with the real answer in the reveal block
        vm.prank(bob);
        vm.expectRevert(ProofQuest.CommitsClosed.selector);
        pq.commit(id, _commitHash(ANSWER, bob, SALT_B));

        // even a pre-existing dummy commit cannot be revealed as the real answer
        vm.prank(bob);
        vm.expectRevert(ProofQuest.BadCommit.selector);
        pq.reveal(id, ANSWER, SALT_B, "");
    }

    function test_wrongAnswerReverts() public {
        uint256 id = _createBnb(1, PRIZE);
        bytes memory wrong = bytes("nope");

        // Commit the wrong preimage, try to reveal the real answer → commit mismatch.
        vm.prank(alice);
        pq.commit(id, _commitHash(wrong, alice, SALT_A));
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(ProofQuest.BadCommit.selector);
        pq.reveal(id, ANSWER, SALT_A, "");

        // Overwrite: commit and reveal the wrong preimage → solution mismatch.
        vm.prank(alice);
        pq.commit(id, _commitHash(wrong, alice, SALT_A));
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(ProofQuest.WrongSolution.selector);
        pq.reveal(id, wrong, SALT_A, "");
    }

    function test_wrongSaltReverts() public {
        uint256 id = _createBnb(1, PRIZE);
        _commitAndRoll(id, alice, SALT_A);
        vm.prank(alice);
        vm.expectRevert(ProofQuest.BadCommit.selector);
        pq.reveal(id, ANSWER, SALT_B, "");
    }

    // -------------------------------------------------------------------------
    // Duplicate win
    // -------------------------------------------------------------------------

    function test_duplicateWinBySameAgentIdReverts() public {
        uint256 id = _createBnb(WINNERS, PRIZE);
        _commitAndRoll(id, alice, SALT_A);
        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");

        // alice cannot commit again (already won, and commits may be closed)
        vm.prank(alice);
        vm.expectRevert(ProofQuest.CommitsClosed.selector);
        pq.commit(id, _commitHash(ANSWER, alice, SALT_A));
    }

    function test_duplicateWin_sameIdTwoQuestsAllowed() public {
        uint256 id1 = _createBnb(1, PRIZE);
        uint256 id2 = _createBnb(1, PRIZE);

        vm.startPrank(alice);
        pq.commit(id1, _commitHash(ANSWER, alice, SALT_A));
        pq.commit(id2, _commitHash(ANSWER, alice, SALT_A));
        vm.stopPrank();
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        pq.reveal(id1, ANSWER, SALT_A, "");
        pq.reveal(id2, ANSWER, SALT_A, "");
        vm.stopPrank();

        assertEq(pq.winsOf("alice"), 2);
        assertEq(pq.earningsOf("alice", address(0)), uint256(PRIZE) * 2);
    }

    // -------------------------------------------------------------------------
    // Non-holder blocked
    // -------------------------------------------------------------------------

    function test_nonHolder_createBlocked() public {
        vm.prank(dave);
        vm.expectRevert(ProofQuest.NotAgentIdHolder.selector);
        pq.createQuest{value: PRIZE}(
            address(0), PRIZE, 1, _deadline(), solutionHash, address(0), "x", ""
        );
    }

    function test_nonHolder_commitBlocked() public {
        uint256 id = _createBnb(1, PRIZE);
        vm.prank(dave);
        vm.expectRevert(ProofQuest.NotAgentIdHolder.selector);
        pq.commit(id, keccak256("x"));
    }

    function test_nonHolder_revealBlocked() public {
        uint256 id = _createBnb(1, PRIZE);
        vm.prank(dave);
        vm.expectRevert(ProofQuest.NotAgentIdHolder.selector);
        pq.reveal(id, ANSWER, SALT_A, "");
    }

    function test_nonHolder_attemptBlocked() public {
        verifier.setAllowed(dave, true);
        vm.prank(poster);
        uint256 id = pq.createQuest{value: PRIZE}(
            address(0), PRIZE, 1, _deadline(), bytes32(0), address(verifier), "v", ""
        );
        vm.prank(dave);
        vm.expectRevert(ProofQuest.NotAgentIdHolder.selector);
        pq.attempt(id, "");
    }

    // -------------------------------------------------------------------------
    // Refund after deadline
    // -------------------------------------------------------------------------

    function test_refundAfterDeadline_unclaimedReturnedToPoster() public {
        uint256 id = _createBnb(WINNERS, PRIZE);
        // one winner
        _commitAndRoll(id, alice, SALT_A);
        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");

        uint256 posterBefore = poster.balance;
        vm.expectRevert(ProofQuest.QuestNotExpired.selector);
        pq.refund(id);

        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, true, false, true);
        emit Refunded(id, poster, address(0), PRIZE);
        pq.refund(id);

        assertEq(poster.balance, posterBefore + PRIZE);
        assertEq(address(pq).balance, 0);
        ProofQuest.Quest memory q = pq.getQuest(id);
        assertEq(q.remainingPrize, 0);

        vm.expectRevert(ProofQuest.NothingToRefund.selector);
        pq.refund(id);
    }

    function test_refund_allUnclaimed() public {
        uint256 id = _createBnb(WINNERS, PRIZE);
        uint256 posterBefore = poster.balance;
        vm.warp(block.timestamp + 1 days);
        pq.refund(id);
        assertEq(poster.balance, posterBefore + uint256(PRIZE) * WINNERS);
    }

    function test_cannotCreateOrCommitAfterDeadline() public {
        uint256 id = _createBnb(1, PRIZE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(ProofQuest.QuestExpired.selector);
        pq.commit(id, _commitHash(ANSWER, alice, SALT_A));
    }

    // -------------------------------------------------------------------------
    // ERC-20 path
    // -------------------------------------------------------------------------

    function test_erc20_happyPathAndRefund() public {
        uint256 total = uint256(PRIZE) * WINNERS;
        vm.startPrank(poster);
        usdt.approve(address(pq), total);
        uint256 id = pq.createQuest(
            address(usdt), PRIZE, WINNERS, _deadline(), solutionHash, address(0), "USDT quest", ""
        );
        vm.stopPrank();
        assertEq(usdt.balanceOf(address(pq)), total);
        assertEq(poster.balance, 100 ether); // no BNB moved

        vm.prank(alice);
        pq.commit(id, _commitHash(ANSWER, alice, SALT_A));
        vm.roll(block.number + 1);
        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");
        assertEq(usdt.balanceOf(alice), PRIZE);
        assertEq(pq.earningsOf("alice", address(usdt)), PRIZE);

        vm.warp(block.timestamp + 1 days);
        uint256 posterUsdt = usdt.balanceOf(poster);
        pq.refund(id);
        assertEq(usdt.balanceOf(poster), posterUsdt + PRIZE);
        assertEq(usdt.balanceOf(address(pq)), 0);
    }

    function test_erc20_silentUsdtStyleToken() public {
        vm.startPrank(poster);
        silent.approve(address(pq), PRIZE);
        uint256 id = pq.createQuest(
            address(silent), PRIZE, 1, _deadline(), solutionHash, address(0), "silent", ""
        );
        vm.stopPrank();

        _commitAndRoll(id, alice, SALT_A);
        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");
        assertEq(silent.balanceOf(alice), PRIZE);
    }

    function test_erc20_requiresApprovalAndZeroMsgValue() public {
        vm.prank(poster);
        vm.expectRevert(); // SafeERC20Failed or InsufficientAllowance
        pq.createQuest(address(usdt), PRIZE, 1, _deadline(), solutionHash, address(0), "x", "");

        vm.startPrank(poster);
        usdt.approve(address(pq), PRIZE);
        vm.expectRevert(ProofQuest.IncorrectValue.selector);
        pq.createQuest{value: 1}(
            address(usdt), PRIZE, 1, _deadline(), solutionHash, address(0), "x", ""
        );
        vm.stopPrank();
    }

    function test_bnb_incorrectValueReverts() public {
        vm.prank(poster);
        vm.expectRevert(ProofQuest.IncorrectValue.selector);
        pq.createQuest{value: PRIZE - 1}(
            address(0), PRIZE, 1, _deadline(), solutionHash, address(0), "x", ""
        );
    }

    function test_unwhitelistedTokenReverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(poster, PRIZE);
        vm.startPrank(poster);
        other.approve(address(pq), PRIZE);
        vm.expectRevert(ProofQuest.TokenNotAllowed.selector);
        pq.createQuest(address(other), PRIZE, 1, _deadline(), solutionHash, address(0), "x", "");
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Verifier path
    // -------------------------------------------------------------------------

    function test_verifierOnly_attempt() public {
        verifier.setAllowed(alice, true);
        vm.prank(poster);
        uint256 id = pq.createQuest{value: PRIZE}(
            address(0), PRIZE, 1, _deadline(), bytes32(0), address(verifier), "interact", ""
        );

        vm.prank(bob);
        vm.expectRevert(ProofQuest.VerifierRejected.selector);
        pq.attempt(id, "");

        uint256 before = alice.balance;
        vm.prank(alice);
        pq.attempt(id, "");
        assertEq(alice.balance, before + PRIZE);
        assertEq(pq.winsOf("alice"), 1);
    }

    function test_hashPlusVerifier() public {
        verifier.setAllowed(alice, true);
        vm.prank(poster);
        uint256 id = pq.createQuest{value: PRIZE}(
            address(0), PRIZE, 1, _deadline(), solutionHash, address(verifier), "both", ""
        );

        _commitAndRoll(id, alice, SALT_A);
        // attempt is the wrong entry point
        vm.prank(alice);
        vm.expectRevert(ProofQuest.VerifierQuestRequired.selector);
        pq.attempt(id, "");

        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");
        assertEq(pq.winsOf("alice"), 1);
    }

    function test_hashPlusVerifier_rejectedIfNotAllowed() public {
        vm.prank(poster);
        uint256 id = pq.createQuest{value: PRIZE}(
            address(0), PRIZE, 1, _deadline(), solutionHash, address(verifier), "both", ""
        );
        _commitAndRoll(id, alice, SALT_A);
        vm.prank(alice);
        vm.expectRevert(ProofQuest.VerifierRejected.selector);
        pq.reveal(id, ANSWER, SALT_A, "");
    }

    function test_create_requiresHashOrVerifier() public {
        vm.prank(poster);
        vm.expectRevert(ProofQuest.InvalidQuestSpec.selector);
        pq.createQuest{value: PRIZE}(
            address(0), PRIZE, 1, _deadline(), bytes32(0), address(0), "x", ""
        );
    }

    // -------------------------------------------------------------------------
    // Reentrancy
    // -------------------------------------------------------------------------

    function test_reentrancy_onRevealNative() public {
        ReentrantSolver attacker = new ReentrantSolver(pq);
        registry.mint(address(attacker), "attacker");
        vm.deal(address(attacker), 1 ether);

        uint256 id = _createBnb(WINNERS, PRIZE);

        // attacker and alice both commit before reveal
        bytes32 salt = keccak256("att");
        attacker.commit(id, ANSWER, salt);
        vm.prank(alice);
        pq.commit(id, _commitHash(ANSWER, alice, SALT_A));
        vm.roll(block.number + 1);

        attacker.setAttack(id, ANSWER, salt, ReentrantSolver.Mode.RevealAgain);
        uint256 attackerBefore = address(attacker).balance;
        uint256 contractBefore = address(pq).balance;
        vm.expectRevert(bytes("native transfer failed"));
        attacker.reveal();
        // Entire tx rolled back: no prize paid, no win recorded.
        assertEq(address(attacker).balance, attackerBefore);
        assertEq(address(pq).balance, contractBefore);
        assertEq(pq.winsOf("attacker"), 0);
    }

    function test_reentrancy_onRefundNative() public {
        ReentrantPoster rposter = new ReentrantPoster(pq);
        registry.mint(address(rposter), "rposter");
        vm.deal(address(rposter), 10 ether);

        uint256 id = rposter.create{value: PRIZE}(PRIZE, 1, _deadline(), solutionHash);
        vm.warp(block.timestamp + 1 days);
        rposter.setAttack(id);
        uint256 before = address(rposter).balance;
        uint256 contractBefore = address(pq).balance;
        vm.expectRevert(bytes("native transfer failed"));
        rposter.goRefund();
        assertEq(address(rposter).balance, before);
        assertEq(address(pq).balance, contractBefore);
        ProofQuest.Quest memory q = pq.getQuest(id);
        assertEq(q.remainingPrize, PRIZE);
    }

    function test_reentrancy_onErc20Transfer() public {
        uint256 id;
        {
            vm.startPrank(poster);
            usdt.approve(address(pq), PRIZE);
            id = pq.createQuest(
                address(usdt), PRIZE, 1, _deadline(), solutionHash, address(0), "re", ""
            );
            vm.stopPrank();
        }
        _commitAndRoll(id, alice, SALT_A);

        // token will try to reenter reveal during the payout transfer
        usdt.setReenter(
            address(pq), abi.encodeWithSelector(pq.reveal.selector, id, ANSWER, SALT_A, bytes(""))
        );

        vm.prank(alice);
        vm.expectRevert(); // ReentrantCall bubbled through "reenter failed" or direct
        pq.reveal(id, ANSWER, SALT_A, "");
    }

    // -------------------------------------------------------------------------
    // Access / admin surface
    // -------------------------------------------------------------------------

    function test_owner_whitelistOnly_cannotSweepFunds() public {
        uint256 id = _createBnb(1, PRIZE);
        assertEq(address(pq).balance, PRIZE);

        // no withdraw / pause / mint selectors
        vm.prank(owner);
        vm.expectRevert(ProofQuest.NativeTokenLocked.selector);
        pq.removePrizeToken(address(0));

        MockERC20 extra = new MockERC20("X", "X", 18);
        vm.prank(alice);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        pq.addPrizeToken(address(extra));

        vm.prank(owner);
        pq.addPrizeToken(address(extra));
        assertTrue(pq.isPrizeToken(address(extra)));
        vm.prank(owner);
        pq.removePrizeToken(address(extra));
        assertFalse(pq.isPrizeToken(address(extra)));

        // funds still locked in the quest
        assertEq(address(pq).balance, PRIZE);
        assertEq(id, 1);
    }

    function test_ownership_twoStepAndRenounce() public {
        address next = makeAddr("next");
        vm.prank(owner);
        pq.transferOwnership(next);
        assertEq(pq.pendingOwner(), next);
        assertEq(pq.owner(), owner);

        vm.prank(alice);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        pq.acceptOwnership();

        vm.prank(next);
        pq.acceptOwnership();
        assertEq(pq.owner(), next);

        vm.prank(next);
        pq.renounceOwnership();
        assertEq(pq.owner(), address(0));
    }

    function test_hasAgentId() public view {
        (bool ok, string memory handle) = pq.hasAgentId(alice);
        assertTrue(ok);
        assertEq(handle, "alice");
        (bool ok2,) = pq.hasAgentId(dave);
        assertFalse(ok2);
    }

    function test_getQuestUnknownReverts() public {
        vm.expectRevert(ProofQuest.QuestNotFound.selector);
        pq.getQuest(1);
        vm.expectRevert(ProofQuest.QuestNotFound.selector);
        pq.questWinners(99);
    }

    function test_invalidCreateParams() public {
        vm.startPrank(poster);
        vm.expectRevert(ProofQuest.InvalidDeadline.selector);
        pq.createQuest{value: PRIZE}(
            address(0), PRIZE, 1, uint64(block.timestamp), solutionHash, address(0), "x", ""
        );
        vm.expectRevert(ProofQuest.InvalidMaxWinners.selector);
        pq.createQuest{value: 0}(
            address(0), PRIZE, 0, _deadline(), solutionHash, address(0), "x", ""
        );
        vm.expectRevert(ProofQuest.InvalidMaxWinners.selector);
        pq.createQuest{value: uint256(PRIZE) * 101}(
            address(0), PRIZE, 101, _deadline(), solutionHash, address(0), "x", ""
        );
        vm.expectRevert(ProofQuest.InvalidPrize.selector);
        pq.createQuest{value: 0}(address(0), 0, 1, _deadline(), solutionHash, address(0), "x", "");
        vm.expectRevert(ProofQuest.InvalidTitle.selector);
        pq.createQuest{value: PRIZE}(
            address(0), PRIZE, 1, _deadline(), solutionHash, address(0), "", ""
        );
        vm.stopPrank();
    }

    function test_receiveRejectsStrayBnb() public {
        vm.prank(poster);
        (bool ok, bytes memory data) = address(pq).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(data), ProofQuest.IncorrectValue.selector);
    }

    function test_constructorRejectsZeroRegistry() public {
        address[] memory none = new address[](0);
        vm.expectRevert(ProofQuest.ZeroAddress.selector);
        new ProofQuest(address(0), owner, none);
    }

    // -------------------------------------------------------------------------
    // Gas snapshots
    // -------------------------------------------------------------------------

    function test_gasEstimates_createCommitReveal() public {
        uint256 gasCreate = gasleft();
        uint256 id = _createBnb(1, PRIZE);
        gasCreate = gasCreate - gasleft();

        bytes32 ch = _commitHash(ANSWER, alice, SALT_A);
        uint256 gasCommit = gasleft();
        vm.prank(alice);
        pq.commit(id, ch);
        gasCommit = gasCommit - gasleft();

        vm.roll(block.number + 1);

        uint256 gasReveal = gasleft();
        vm.prank(alice);
        pq.reveal(id, ANSWER, SALT_A, "");
        gasReveal = gasReveal - gasleft();

        console2.log("gas createQuest (BNB, 1 winner):", gasCreate);
        console2.log("gas commit:", gasCommit);
        console2.log("gas reveal (BNB payout):", gasReveal);
    }
}

contract ReentrantSolver {
    enum Mode {
        RevealAgain,
        None
    }

    ProofQuest public pq;
    uint256 public questId;
    bytes public answer;
    bytes32 public salt;
    Mode public mode;

    constructor(ProofQuest pq_) {
        pq = pq_;
    }

    function commit(uint256 id, bytes memory answer_, bytes32 salt_) external {
        questId = id;
        answer = answer_;
        salt = salt_;
        pq.commit(id, keccak256(abi.encode(answer_, address(this), salt_)));
    }

    function setAttack(uint256 id, bytes memory answer_, bytes32 salt_, Mode mode_) external {
        questId = id;
        answer = answer_;
        salt = salt_;
        mode = mode_;
    }

    function reveal() external {
        pq.reveal(questId, answer, salt, "");
    }

    receive() external payable {
        if (mode == Mode.RevealAgain) {
            pq.reveal(questId, answer, salt, "");
        }
    }
}

contract ReentrantPoster {
    ProofQuest public pq;
    uint256 public questId;
    bool public attacking;

    constructor(ProofQuest pq_) {
        pq = pq_;
    }

    function create(uint128 prize, uint32 winners, uint64 deadline, bytes32 solutionHash)
        external
        payable
        returns (uint256)
    {
        questId = pq.createQuest{value: msg.value}(
            address(0), prize, winners, deadline, solutionHash, address(0), "rp", ""
        );
        return questId;
    }

    function setAttack(uint256 id) external {
        questId = id;
        attacking = true;
    }

    function goRefund() external {
        pq.refund(questId);
    }

    receive() external payable {
        if (attacking) {
            pq.refund(questId);
        }
    }
}
