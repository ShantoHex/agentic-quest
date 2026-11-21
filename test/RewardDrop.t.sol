// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RewardDrop} from "../src/RewardDrop.sol";
import {MockAgentID} from "../src/mocks/MockAgentID.sol";
import {MockERC20, SilentERC20} from "../src/mocks/MockERC20.sol";
import {Ownable2Step} from "../src/utils/Ownable2Step.sol";
import {ReentrancyGuard} from "../src/utils/ReentrancyGuard.sol";

/// @dev Registry with fully settable answers (mixed case, reverts, shared handles).
contract FlexRegistry {
    mapping(address => uint256) public bal;
    mapping(address => string) public h;
    bool public revertHandle;

    function set(address a, uint256 b, string calldata s) external {
        bal[a] = b;
        h[a] = s;
    }

    function setRevert(bool r) external {
        revertHandle = r;
    }

    function balanceOf(address a) external view returns (uint256) {
        return bal[a];
    }

    function handleOf(address a) external view returns (string memory) {
        require(!revertHandle, "no id");
        return h[a];
    }

    function ownerOfHandle(string calldata) external pure returns (address) {
        return address(0);
    }
}

contract NoDecimals {}

contract RewardDropTest is Test {
    RewardDrop drop;
    MockAgentID reg;
    MockERC20 usdt;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address nobody = makeAddr("nobody");
    address signerAddr;
    uint256 signerPk;
    uint256 nonce_;

    struct V {
        bytes32 post;
        bytes32 acct;
        uint256 deadline;
        bytes sig;
    }

    uint256 constant E18 = 1e18;

    function setUp() public {
        vm.roll(1000);
        reg = new MockAgentID();
        usdt = new MockERC20("Test USDT", "USDT", 18);
        (signerAddr, signerPk) = makeAddrAndKey("voucher-signer");
        vm.warp(1_800_000_000);
        drop = new RewardDrop(address(reg), address(usdt), owner);
        vm.prank(owner);
        drop.setSigner(signerAddr);
        reg.mint(alice, "alice");
        reg.mint(bob, "bob");
        reg.mint(carol, "carol");
        usdt.mint(owner, 1_000 * E18);
        vm.startPrank(owner);
        usdt.approve(address(drop), type(uint256).max);
        drop.fund(100 * E18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------- helpers

    function _handleKeyOf(RewardDrop d, address u) internal view returns (bytes32) {
        try FlexRegistry(address(d.agentId())).handleOf(u) returns (string memory s) {
            return d.handleKey(s);
        } catch {
            return bytes32(0);
        }
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Fresh voucher (unique post + account) for `u`, signed by the configured signer.
    function _v(RewardDrop d, address u) internal returns (V memory v) {
        ++nonce_;
        v.post = keccak256(bytes(vm.toString(1_900_000_000_000_000_000 + nonce_)));
        v.acct = keccak256(bytes(vm.toString(4_400_000 + nonce_)));
        v.deadline = block.timestamp + 1 hours;
        v.sig = _sign(signerPk, d.voucherDigest(_handleKeyOf(d, u), u, v.post, v.acct, v.deadline));
    }

    function _commit(address u) internal returns (uint64 target) {
        {
            V memory v_ = _v(drop, u);
            vm.prank(u);
            drop.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        (, target,,,,) = drop.pendingClaim(u);
    }

    function _settle(address u, uint64 target, bytes32 bh) internal returns (uint256 amt) {
        vm.roll(uint256(target) + 1);
        vm.setBlockhash(target, bh);
        vm.prank(u);
        amt = drop.settleClaim();
    }

    // ---------------------------------------------------------- constructor / tiers

    function test_TiersFrom18Decimals() public view {
        (uint256[5] memory a, uint8[5] memory o) = drop.tiers();
        assertEq(a[0], 0.05e18);
        assertEq(a[1], 0.08e18);
        assertEq(a[2], 0.12e18);
        assertEq(a[3], 0.15e18);
        assertEq(a[4], 0.2e18);
        assertEq(uint256(o[0]) + o[1] + o[2] + o[3] + o[4], 100);
        assertEq(drop.tokenDecimals(), 18);
    }

    function test_TiersFrom6Decimals() public {
        MockERC20 t6 = new MockERC20("U6", "U6", 6);
        RewardDrop d = new RewardDrop(address(reg), address(t6), owner);
        vm.prank(owner);
        d.setSigner(signerAddr);
        (uint256[5] memory a,) = d.tiers();
        assertEq(a[0], 50_000);
        assertEq(a[4], 200_000);
    }

    function test_RevertWhen_TokenHasNoDecimals() public {
        NoDecimals nd = new NoDecimals();
        vm.expectRevert(RewardDrop.BadDecimals.selector);
        new RewardDrop(address(reg), address(nd), owner);
    }

    function test_RevertWhen_ZeroAddresses() public {
        vm.expectRevert(RewardDrop.ZeroAddress.selector);
        new RewardDrop(address(0), address(usdt), owner);
        vm.expectRevert(RewardDrop.ZeroAddress.selector);
        new RewardDrop(address(reg), address(0), owner);
    }

    // ---------------------------------------------------------- gating

    function test_RevertWhen_NoAgentId() public {
        {
            V memory v_ = _v(drop, nobody);
            vm.prank(nobody);
            vm.expectRevert(RewardDrop.NoAgentId.selector);
            drop.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        (bool ok, string memory why) = drop.canClaim(nobody);
        assertFalse(ok);
        assertEq(why, "no Agent ID");
    }

    function test_Gating_BalanceButEmptyHandle_AndRevertingHandleOf() public {
        FlexRegistry fr = new FlexRegistry();
        RewardDrop d = new RewardDrop(address(fr), address(usdt), owner);
        vm.prank(owner);
        d.setSigner(signerAddr);
        vm.prank(owner);
        usdt.transfer(address(d), 10 * E18);

        fr.set(alice, 1, ""); // balance but empty handle (mainnet returns "")
        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            vm.expectRevert(RewardDrop.NoAgentId.selector);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }

        fr.set(alice, 0, "alice"); // handle but zero balance
        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            vm.expectRevert(RewardDrop.NoAgentId.selector);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }

        fr.set(alice, 1, "alice");
        fr.setRevert(true); // reverting handleOf is treated as "no Agent ID"
        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            vm.expectRevert(RewardDrop.NoAgentId.selector);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        (bool ok,) = d.canClaim(alice);
        assertFalse(ok);
    }

    function test_CanClaim_HappyPath() public view {
        (bool ok, string memory why) = drop.canClaim(alice);
        assertTrue(ok);
        assertEq(why, "");
    }

    // ---------------------------------------------------------- full flow

    function test_CommitThenSettle_PaysAndEmits() public {
        uint256 before = usdt.balanceOf(alice);
        bytes32 h = keccak256("alice");
        V memory v = _v(drop, alice);
        vm.expectEmit(true, true, false, true);
        emit RewardDrop.ClaimCommitted(h, "alice", alice, uint64(block.number) + 2, v.post, v.acct);
        vm.prank(alice);
        drop.commitClaim(v.post, v.acct, v.deadline, v.sig);
        (, uint64 target,,,,) = drop.pendingClaim(alice);
        assertTrue(drop.isPostUsed(v.post));
        assertTrue(drop.isAccountUsed(v.acct));
        assertEq(target, 1002);
        assertEq(drop.totalReserved(), 0.2e18);
        assertEq(drop.availablePool(), 100e18 - 0.2e18);

        (bool ex,,,, bool ready, bool expired) = drop.pendingClaim(alice);
        assertTrue(ex);
        assertFalse(ready);
        assertFalse(expired);

        bytes32 bh = keccak256("block");
        uint256 expected = drop.tierFor(drop.randomSeed(bh, alice, h));
        vm.roll(target + 1);
        vm.setBlockhash(target, bh);
        vm.expectEmit(true, true, false, true);
        emit RewardDrop.Claimed(h, "alice", alice, expected);
        vm.prank(alice);
        uint256 amt = drop.settleClaim();

        assertEq(amt, expected);
        assertEq(usdt.balanceOf(alice) - before, amt);
        assertEq(drop.totalReserved(), 0);
        assertEq(drop.totalPaid(), amt);
        assertEq(drop.claimCount(), 1);
        assertTrue(drop.handleClaimed(h));
        assertTrue(drop.addressClaimed(alice));
        assertEq(drop.rewardOfHandle(h), amt);
        assertEq(usdt.balanceOf(address(drop)), 100e18 - amt);
    }

    function test_RevertWhen_SettleTooEarly() public {
        uint64 target = _commit(alice);
        vm.prank(alice);
        vm.expectRevert(RewardDrop.TooEarly.selector);
        drop.settleClaim();
        vm.roll(target); // still not > target
        vm.prank(alice);
        vm.expectRevert(RewardDrop.TooEarly.selector);
        drop.settleClaim();
    }

    function test_RevertWhen_SettleWithoutCommit() public {
        vm.prank(alice);
        vm.expectRevert(RewardDrop.NoPendingClaim.selector);
        drop.settleClaim();
    }

    // ---------------------------------------------------------- double claims

    function test_RevertWhen_DoubleCommit() public {
        _commit(alice);
        {
            V memory v_ = _v(drop, alice);
            vm.prank(alice);
            vm.expectRevert(RewardDrop.ClaimPending.selector);
            drop.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
    }

    function test_RevertWhen_ClaimAgainAfterSettle() public {
        uint64 t = _commit(alice);
        _settle(alice, t, keccak256("x"));
        {
            V memory v_ = _v(drop, alice);
            vm.prank(alice);
            vm.expectRevert(RewardDrop.AddressAlreadyClaimed.selector);
            drop.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        (bool ok, string memory why) = drop.canClaim(alice);
        assertFalse(ok);
        assertEq(why, "address already claimed");
    }

    /// Same Agent ID showing up at a new address (e.g. registry migration or a
    /// case variant) must not claim twice: keyed by keccak256(lowercase handle).
    function test_RevertWhen_SameHandleNewAddress_CaseInsensitive() public {
        FlexRegistry fr = new FlexRegistry();
        RewardDrop d = new RewardDrop(address(fr), address(usdt), owner);
        vm.prank(owner);
        d.setSigner(signerAddr);
        vm.prank(owner);
        usdt.transfer(address(d), 10 * E18);
        fr.set(alice, 1, "Shanto");
        fr.set(bob, 1, "shanto");
        fr.set(carol, 1, "SHANTO");

        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        // pending handle blocks a parallel commit from another address
        {
            V memory v_ = _v(d, bob);
            vm.prank(bob);
            vm.expectRevert(RewardDrop.ClaimPending.selector);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }

        vm.roll(block.number + 3);
        vm.setBlockhash(block.number - 1, keccak256("z"));
        vm.prank(alice);
        d.settleClaim();

        {
            V memory v_ = _v(d, carol);
            vm.prank(carol);
            vm.expectRevert(RewardDrop.HandleAlreadyClaimed.selector);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        (bool ok, string memory why) = d.canClaim(bob);
        assertFalse(ok);
        assertEq(why, "Agent ID already claimed");
        assertTrue(d.handleClaimed(d.handleKey("sHaNtO")));
    }

    /// Address that claimed, later gets a different handle: still blocked.
    function test_RevertWhen_AddressClaimsWithSecondHandle() public {
        FlexRegistry fr = new FlexRegistry();
        RewardDrop d = new RewardDrop(address(fr), address(usdt), owner);
        vm.prank(owner);
        d.setSigner(signerAddr);
        vm.prank(owner);
        usdt.transfer(address(d), 10 * E18);
        fr.set(alice, 1, "one");
        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        vm.roll(block.number + 3);
        vm.prank(alice);
        d.settleClaim();
        fr.set(alice, 1, "two");
        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            vm.expectRevert(RewardDrop.AddressAlreadyClaimed.selector);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
    }

    // ---------------------------------------------------------- pool / reserve

    function test_RevertWhen_PoolBelowMaxTier() public {
        RewardDrop d = new RewardDrop(address(reg), address(usdt), owner);
        vm.prank(owner);
        d.setSigner(signerAddr);
        vm.prank(owner);
        usdt.transfer(address(d), 0.2e18 - 1);
        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            vm.expectRevert(RewardDrop.PoolInsufficient.selector);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        (bool ok, string memory why) = d.canClaim(alice);
        assertFalse(ok);
        assertEq(why, "reward pool empty");
    }

    function test_ReserveBlocksSecondClaimWhenOnlyOneMaxTierFunded() public {
        RewardDrop d = new RewardDrop(address(reg), address(usdt), owner);
        vm.prank(owner);
        d.setSigner(signerAddr);
        vm.prank(owner);
        usdt.transfer(address(d), 0.3e18); // covers one reservation only
        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        assertEq(d.availablePool(), 0.1e18);
        {
            V memory v_ = _v(d, bob);
            vm.prank(bob);
            vm.expectRevert(RewardDrop.PoolInsufficient.selector);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }

        // alice settles; whatever she gets, the pool stays solvent
        vm.roll(block.number + 3);
        vm.setBlockhash(block.number - 1, keccak256("q"));
        vm.prank(alice);
        uint256 amt = d.settleClaim();
        assertEq(d.totalReserved(), 0);
        assertEq(usdt.balanceOf(address(d)), 0.3e18 - amt);
    }

    function test_ManyClaimsPoolNeverInsolvent() public {
        RewardDrop d = new RewardDrop(address(reg), address(usdt), owner);
        vm.prank(owner);
        d.setSigner(signerAddr);
        vm.prank(owner);
        usdt.transfer(address(d), 5e18);
        uint256 paid;
        for (uint256 i; i < 40; ++i) {
            address u = address(uint160(0x10000 + i));
            reg.mint(u, string(abi.encodePacked("u", vm.toString(i))));
            if (d.availablePool() < 0.2e18) {
                {
                    V memory v_ = _v(d, u);
                    vm.prank(u);
                    vm.expectRevert(RewardDrop.PoolInsufficient.selector);
                    d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
                }
                continue;
            }
            {
                V memory v_ = _v(d, u);
                vm.prank(u);
                d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
            }
            (, uint64 t,,,,) = d.pendingClaim(u);
            vm.roll(uint256(t) + 1);
            vm.setBlockhash(t, keccak256(abi.encode("bh", i)));
            vm.prank(u);
            paid += d.settleClaim();
            assertGe(usdt.balanceOf(address(d)), d.totalReserved());
        }
        assertEq(d.totalPaid(), paid);
        assertEq(usdt.balanceOf(address(d)), 5e18 - paid);
    }

    // ---------------------------------------------------------- distribution

    function testFuzz_TierDistributionMatchesOdds(uint256 salt) public view {
        uint256 n = 4000;
        uint256[5] memory c;
        (uint256[5] memory a,) = drop.tiers();
        for (uint256 i; i < n; ++i) {
            uint256 amt = drop.tierFor(
                drop.randomSeed(keccak256(abi.encode(salt, i)), alice, keccak256("alice"))
            );
            for (uint256 k; k < 5; ++k) {
                if (amt == a[k]) {
                    ++c[k];
                    break;
                }
            }
        }
        // expected 2000 / 800 / 800 / 200 / 200; allow ~5 sigma
        assertApproxEqAbs(c[0], 2000, 160);
        assertApproxEqAbs(c[1], 800, 130);
        assertApproxEqAbs(c[2], 800, 130);
        assertApproxEqAbs(c[3], 200, 70);
        assertApproxEqAbs(c[4], 200, 70);
        assertEq(c[0] + c[1] + c[2] + c[3] + c[4], n);
    }

    function test_TierBoundaries() public view {
        assertEq(drop.tierFor(0), 0.05e18);
        assertEq(drop.tierFor(49), 0.05e18);
        assertEq(drop.tierFor(50), 0.08e18);
        assertEq(drop.tierFor(69), 0.08e18);
        assertEq(drop.tierFor(70), 0.12e18);
        assertEq(drop.tierFor(89), 0.12e18);
        assertEq(drop.tierFor(90), 0.15e18);
        assertEq(drop.tierFor(94), 0.15e18);
        assertEq(drop.tierFor(95), 0.2e18);
        assertEq(drop.tierFor(99), 0.2e18);
        assertEq(drop.tierFor(199), 0.2e18);
    }

    function testFuzz_SettlePaysAValidTier(bytes32 bh) public {
        vm.assume(bh != bytes32(0));
        uint64 t = _commit(alice);
        uint256 amt = _settle(alice, t, bh);
        assertTrue(
            amt == 0.05e18 || amt == 0.08e18 || amt == 0.12e18 || amt == 0.15e18
                || amt == 0.2e18
        );
    }

    // ---------------------------------------------------------- blockhash expiry

    function test_ExpiredCommitSettlesAtLowestTier() public {
        uint64 t = _commit(alice);
        vm.roll(uint256(t) + 257);
        (,,,, bool ready, bool expired) = drop.pendingClaim(alice);
        assertTrue(ready);
        assertTrue(expired);
        vm.expectEmit(true, true, false, false);
        emit RewardDrop.ClaimExpiredFallback(keccak256("alice"), alice);
        vm.prank(alice);
        uint256 amt = drop.settleClaim();
        assertEq(amt, 0.05e18);
        assertEq(drop.totalReserved(), 0);
        // cannot re-roll afterwards
        {
            V memory v_ = _v(drop, alice);
            vm.prank(alice);
            vm.expectRevert(RewardDrop.AddressAlreadyClaimed.selector);
            drop.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
    }

    function test_ExpiredCommitCannotRecommit() public {
        uint64 t = _commit(alice);
        vm.roll(uint256(t) + 1000);
        {
            V memory v_ = _v(drop, alice);
            vm.prank(alice);
            vm.expectRevert(RewardDrop.ClaimPending.selector);
            drop.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
    }

    // ---------------------------------------------------------- pause

    function test_PauseBlocksCommitButNotSettle() public {
        uint64 t = _commit(alice);
        vm.prank(owner);
        drop.pause();
        assertTrue(drop.paused());
        {
            V memory v_ = _v(drop, bob);
            vm.prank(bob);
            vm.expectRevert(RewardDrop.IsPaused.selector);
            drop.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        (bool ok, string memory why) = drop.canClaim(bob);
        assertFalse(ok);
        assertEq(why, "paused");
        // pending claim still settles while paused
        _settle(alice, t, keccak256("p"));
        vm.prank(owner);
        drop.unpause();
        {
            V memory v_ = _v(drop, bob);
            vm.prank(bob);
            drop.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
    }

    function test_RevertWhen_NonOwnerPausesOrWithdraws() public {
        vm.startPrank(alice);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        drop.pause();
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        drop.unpause();
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        drop.withdrawLeftover(1, alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------- withdraw

    function test_WithdrawLimitedToUnreserved() public {
        _commit(alice);
        _commit(bob);
        uint256 avail = drop.availablePool();
        assertEq(avail, 100e18 - 0.4e18);
        vm.prank(owner);
        vm.expectRevert(RewardDrop.AmountTooHigh.selector);
        drop.withdrawLeftover(avail + 1, owner);

        uint256 before = usdt.balanceOf(owner);
        vm.expectEmit(true, false, false, true);
        emit RewardDrop.LeftoverWithdrawn(owner, avail);
        vm.prank(owner);
        drop.withdrawLeftover(avail, owner);
        assertEq(usdt.balanceOf(owner) - before, avail);
        assertEq(drop.availablePool(), 0);
        assertEq(usdt.balanceOf(address(drop)), 0.4e18);

        // reserved users still get paid in full
        (, uint64 ta,,,,) = drop.pendingClaim(alice);
        (, uint64 tb,,,,) = drop.pendingClaim(bob);
        _settle(alice, ta, keccak256("a"));
        vm.roll(uint256(tb) + 1);
        vm.setBlockhash(tb, keccak256("b"));
        vm.prank(bob);
        drop.settleClaim();
        assertEq(drop.totalReserved(), 0);
        assertEq(usdt.balanceOf(address(drop)) + drop.totalPaid(), 0.4e18);
    }

    function test_RevertWhen_WithdrawZeroOrToZero() public {
        vm.startPrank(owner);
        vm.expectRevert(RewardDrop.ZeroAmount.selector);
        drop.withdrawLeftover(0, owner);
        vm.expectRevert(RewardDrop.ZeroAddress.selector);
        drop.withdrawLeftover(1, address(0));
        vm.stopPrank();
    }

    function test_FundEmitsAndZeroReverts() public {
        vm.expectEmit(true, false, false, true);
        emit RewardDrop.Funded(owner, 1e18);
        vm.prank(owner);
        drop.fund(1e18);
        vm.prank(owner);
        vm.expectRevert(RewardDrop.ZeroAmount.selector);
        drop.fund(0);
        assertEq(drop.availablePool(), 101e18);
    }

    // ---------------------------------------------------------- ownership

    function test_OwnershipTwoStep() public {
        vm.prank(owner);
        drop.transferOwnership(alice);
        assertEq(drop.owner(), owner);
        vm.prank(alice);
        drop.acceptOwnership();
        assertEq(drop.owner(), alice);
        vm.prank(alice);
        drop.pause();
        assertTrue(drop.paused());
    }

    // ---------------------------------------------------------- token quirks

    function test_SilentUsdtStyleToken() public {
        SilentERC20 s = new SilentERC20();
        RewardDrop d = new RewardDrop(address(reg), address(s), owner);
        vm.prank(owner);
        d.setSigner(signerAddr);
        s.mint(address(d), 1e18);
        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        vm.roll(block.number + 3);
        vm.prank(alice);
        uint256 amt = d.settleClaim();
        assertEq(s.balanceOf(alice), amt);
    }

    function test_RevertWhen_TokenReentersSettle() public {
        MockERC20 evil = new MockERC20("E", "E", 18);
        RewardDrop d = new RewardDrop(address(reg), address(evil), owner);
        vm.prank(owner);
        d.setSigner(signerAddr);
        evil.mint(address(d), 10e18);
        {
            V memory v_ = _v(d, alice);
            vm.prank(alice);
            d.commitClaim(v_.post, v_.acct, v_.deadline, v_.sig);
        }
        evil.setReenter(address(d), abi.encodeCall(RewardDrop.settleClaim, ()));
        vm.roll(block.number + 3);
        vm.prank(alice);
        vm.expectRevert(); // reentrant settle bubbles up as "reenter failed"
        d.settleClaim();
        assertEq(evil.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------- vouchers (EIP-712)

    function test_Voucher_DomainAndDigestMatchManualEip712() public view {
        bytes32 ds = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("ProofQuest RewardDrop"),
                keccak256("1"),
                block.chainid,
                address(drop)
            )
        );
        assertEq(drop.DOMAIN_SEPARATOR(), ds);
        bytes32 th = keccak256(
            "Voucher(bytes32 handleHash,address user,bytes32 xPostIdHash,bytes32 xAccountIdHash,uint256 deadline)"
        );
        assertEq(drop.VOUCHER_TYPEHASH(), th);
        bytes32 post = keccak256(bytes("1858000000000000001"));
        bytes32 acct = keccak256(bytes("44196397"));
        bytes32 sh = keccak256(abi.encode(th, keccak256("alice"), alice, post, acct, uint256(123)));
        assertEq(drop.hashVoucher(keccak256("alice"), alice, post, acct, 123), sh);
        assertEq(
            drop.voucherDigest(keccak256("alice"), alice, post, acct, 123),
            keccak256(abi.encodePacked("\x19\x01", ds, sh))
        );
        (bytes1 fields, string memory name, string memory version, uint256 cid, address vc,
            bytes32 salt, uint256[] memory ext) = drop.eip712Domain();
        assertEq(fields, bytes1(0x0f));
        assertEq(name, "ProofQuest RewardDrop");
        assertEq(version, "1");
        assertEq(cid, block.chainid);
        assertEq(vc, address(drop));
        assertEq(salt, bytes32(0));
        assertEq(ext.length, 0);
    }

    function test_Voucher_Valid() public {
        uint64 t = _commit(alice);
        assertGt(t, 0);
        assertEq(drop.totalReserved(), 0.2e18);
    }

    function test_RevertWhen_Voucher_WrongSigner() public {
        (, uint256 badPk) = makeAddrAndKey("attacker");
        V memory v = _v(drop, alice);
        v.sig = _sign(badPk, drop.voucherDigest(keccak256("alice"), alice, v.post, v.acct, v.deadline));
        vm.prank(alice);
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, v.acct, v.deadline, v.sig);
    }

    function test_RevertWhen_Voucher_Expired() public {
        V memory v = _v(drop, alice);
        vm.warp(v.deadline + 1);
        vm.prank(alice);
        vm.expectRevert(RewardDrop.VoucherExpired.selector);
        drop.commitClaim(v.post, v.acct, v.deadline, v.sig);
    }

    function test_Voucher_ValidAtExactDeadline() public {
        V memory v = _v(drop, alice);
        vm.warp(v.deadline);
        vm.prank(alice);
        drop.commitClaim(v.post, v.acct, v.deadline, v.sig);
    }

    function test_RevertWhen_Voucher_TamperedFields() public {
        V memory v = _v(drop, alice);
        vm.startPrank(alice);
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, v.acct, v.deadline + 1, v.sig);
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(keccak256("other post"), v.acct, v.deadline, v.sig);
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, keccak256("other acct"), v.deadline, v.sig);
        vm.stopPrank();
    }

    function test_RevertWhen_Voucher_ForAnotherUser() public {
        V memory v = _v(drop, alice); // signed for alice + alice's handle
        vm.prank(bob);
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, v.acct, v.deadline, v.sig);
    }

    function test_RevertWhen_Voucher_RightUserWrongHandle() public {
        // signed for alice's address but bob's handle hash
        V memory v = _v(drop, alice);
        v.sig = _sign(signerPk, drop.voucherDigest(keccak256("bob"), alice, v.post, v.acct, v.deadline));
        vm.prank(alice);
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, v.acct, v.deadline, v.sig);
    }

    function test_RevertWhen_Voucher_PostReused() public {
        V memory va = _v(drop, alice);
        vm.prank(alice);
        drop.commitClaim(va.post, va.acct, va.deadline, va.sig);
        bytes32 acct2 = keccak256(bytes("999"));
        bytes memory sig = _sign(
            signerPk, drop.voucherDigest(keccak256("bob"), bob, va.post, acct2, va.deadline)
        );
        vm.prank(bob);
        vm.expectRevert(RewardDrop.PostAlreadyUsed.selector);
        drop.commitClaim(va.post, acct2, va.deadline, sig);
    }

    function test_RevertWhen_Voucher_AccountReused() public {
        V memory va = _v(drop, alice);
        vm.prank(alice);
        drop.commitClaim(va.post, va.acct, va.deadline, va.sig);
        bytes32 post2 = keccak256(bytes("1858999"));
        bytes memory sig = _sign(
            signerPk, drop.voucherDigest(keccak256("bob"), bob, post2, va.acct, va.deadline)
        );
        vm.prank(bob);
        vm.expectRevert(RewardDrop.AccountAlreadyUsed.selector);
        drop.commitClaim(post2, va.acct, va.deadline, sig);
    }

    function test_RevertWhen_Voucher_MalleableHighS() public {
        V memory v = _v(drop, alice);
        bytes32 digest = drop.voucherDigest(keccak256("alice"), alice, v.post, v.acct, v.deadline);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 s2 = bytes32(n - uint256(s));
        uint8 v2 = vv == 27 ? 28 : 27;
        // sanity: the malleated signature recovers to the same signer
        assertEq(ecrecover(digest, v2, r, s2), signerAddr);
        vm.prank(alice);
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, v.acct, v.deadline, abi.encodePacked(r, s2, v2));
        // original low-s signature still works
        vm.prank(alice);
        drop.commitClaim(v.post, v.acct, v.deadline, abi.encodePacked(r, s, vv));
    }

    function test_RevertWhen_Voucher_BadLengthOrV() public {
        V memory v = _v(drop, alice);
        vm.startPrank(alice);
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, v.acct, v.deadline, bytes.concat(v.sig, hex"00"));
        bytes memory bad = v.sig;
        bad[64] = 0x1d; // v = 29
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, v.acct, v.deadline, bad);
        vm.stopPrank();
    }

    function test_RevertWhen_SignerUnset() public {
        RewardDrop d = new RewardDrop(address(reg), address(usdt), owner);
        vm.prank(owner);
        usdt.transfer(address(d), 1e18);
        V memory v = _v(d, alice);
        vm.prank(alice);
        vm.expectRevert(RewardDrop.SignerNotSet.selector);
        d.commitClaim(v.post, v.acct, v.deadline, v.sig);
        (bool ok, string memory why) = d.canClaim(alice);
        assertFalse(ok);
        assertEq(why, "signer not set");

        // unsetting on a live contract also stops commits
        vm.prank(owner);
        drop.setSigner(address(0));
        V memory v2 = _v(drop, alice);
        vm.prank(alice);
        vm.expectRevert(RewardDrop.SignerNotSet.selector);
        drop.commitClaim(v2.post, v2.acct, v2.deadline, v2.sig);
    }

    function test_SetSigner_OwnerOnlyAndEmits() public {
        vm.prank(alice);
        vm.expectRevert(Ownable2Step.Unauthorized.selector);
        drop.setSigner(alice);

        address ns = makeAddr("newSigner");
        vm.expectEmit(true, true, false, false);
        emit RewardDrop.SignerUpdated(signerAddr, ns);
        vm.prank(owner);
        drop.setSigner(ns);
        assertEq(drop.signer(), ns);

        // old signer's vouchers no longer work
        V memory v = _v(drop, alice);
        vm.prank(alice);
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, v.acct, v.deadline, v.sig);
    }

    function test_FailedCommitDoesNotBurnPostOrAccount() public {
        V memory v = _v(drop, alice);
        vm.prank(bob); // wrong user -> revert, nothing marked
        vm.expectRevert(RewardDrop.InvalidSignature.selector);
        drop.commitClaim(v.post, v.acct, v.deadline, v.sig);
        assertFalse(drop.isPostUsed(v.post));
        assertFalse(drop.isAccountUsed(v.acct));
        vm.prank(alice);
        drop.commitClaim(v.post, v.acct, v.deadline, v.sig);
    }
}
