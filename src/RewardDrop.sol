// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentID} from "./interfaces/IAgentID.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {Ownable2Step} from "./utils/Ownable2Step.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title RewardDrop
/// @notice Every Agent ID holder can claim exactly ONE random reward in a single
///         ERC-20 (USDT on BSC). Tiers: 0.05 (50%), 0.08 (20%), 0.12 (20%),
///         0.15 (5%), 0.20 (5%) whole tokens. Expected value 0.0825 per claim.
///         Rewards are funded by the owner; there is no yield or promised return.
///
/// @dev Flow (the user signs both transactions themselves):
///      0. Off-chain, the project's server checks that the user's X post quotes the
///         project post and signs an EIP-712 `Voucher` with the `signer` key.
///      1. `commitClaim(xPostIdHash, xAccountIdHash, deadline, signature)` checks
///         the Agent ID gate and the voucher, burns the X post and X account
///         (each usable once), records
///         `targetBlock = block.number + SETTLE_DELAY` and reserves the max tier
///         from the pool so the payout is always covered.
///      2. After `targetBlock` is mined, `settleClaim()` derives randomness from
///         `keccak256(blockhash(targetBlock), user, handleHash, this, chainid)`,
///         pays the tier and releases the rest of the reservation.
///
///      One claim per Agent ID, keyed by `keccak256(lowercase(handle))`, and also
///      one claim per address.
///
///      RANDOMNESS LIMITS (read this):
///      - `blockhash(targetBlock)` is unknown when the commit is sent, so the
///        user cannot pick a winning block. But the validator that produces
///        `targetBlock` can see/compute the outcome and could withhold or reorder
///        that block to bias it. On BSC the validator set is small. This is
///        acceptable ONLY because rewards are tiny (max 0.20 USDT).
///      - `blockhash` is only available for the last 256 blocks. If the user does
///        not settle within 256 blocks after `targetBlock`, the claim settles
///        deterministically at the LOWEST tier (0.05). This removes any incentive
///        to let a bad roll expire and retry; there is no re-commit.
///      - block.timestamp / prevrandao are NOT used.
///      - Mainnet upgrade path for anything of value: Chainlink VRF v2.5 on BSC.
///
///      Owner permissions (the ONLY admin surface):
///      - `setSigner(address)`: choose the voucher signer. While it is
///        address(0) no new commits are possible. A compromised signer can only
///        let extra Agent ID holders claim once each; it cannot touch funds.
///      - `pause` / `unpause`: stop or resume NEW commits. Pending commits can
///        always be settled, even while paused.
///      - `withdrawLeftover(amount, to)`: withdraw funds NOT reserved for pending
///        claims (`availablePool()`). Reserved funds can never be withdrawn.
///      - `transferOwnership` / `acceptOwnership` / `renounceOwnership`.
///      No upgrade proxy, no mint, no fee, no way to touch reserved funds.
contract RewardDrop is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Blocks between commit and the block whose hash is used.
    uint64 public constant SETTLE_DELAY = 2;
    /// @notice blockhash() window on the EVM.
    uint64 public constant BLOCKHASH_WINDOW = 256;

    /// @notice EIP-712 voucher type.
    bytes32 public constant VOUCHER_TYPEHASH = keccak256(
        "Voucher(bytes32 handleHash,address user,bytes32 xPostIdHash,bytes32 xAccountIdHash,uint256 deadline)"
    );
    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    string public constant EIP712_NAME = "ProofQuest RewardDrop";
    string public constant EIP712_VERSION = "1";
    bytes32 private constant _HASHED_NAME = keccak256(bytes(EIP712_NAME));
    bytes32 private constant _HASHED_VERSION = keccak256(bytes(EIP712_VERSION));
    /// @dev secp256k1n / 2 (EIP-2 low-s rule).
    uint256 private constant _HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    bytes32 private immutable _cachedDomainSeparator;
    uint256 private immutable _cachedChainId;

    IAgentID public immutable agentId;
    IERC20 public immutable token;
    uint8 public immutable tokenDecimals;

    uint256 public immutable tier0; // 0.05  (50%)
    uint256 public immutable tier1; // 0.08  (20%)
    uint256 public immutable tier2; // 0.12  (20%)
    uint256 public immutable tier3; // 0.15  (5%)
    uint256 public immutable tier4; // 0.20  (5%) = max, reserved on commit

    struct Pending {
        uint64 targetBlock; // 0 = none
        bytes32 handleHash;
        string handle;
    }

    bool public paused;
    address public signer;
    uint256 public totalReserved;
    uint256 public totalPaid;
    uint256 public claimCount;

    mapping(address => Pending) private _pending;
    mapping(bytes32 => bool) public handleClaimed; // settled
    mapping(bytes32 => address) public handlePendingBy; // committed, not settled
    mapping(address => bool) public addressClaimed; // settled
    mapping(bytes32 => uint256) public rewardOfHandle;
    mapping(bytes32 => bool) public usedPost; // keccak256(bytes(postIdString))
    mapping(bytes32 => bool) public usedAccount; // keccak256(bytes(numericXUserIdString))

    event ClaimCommitted(
        bytes32 indexed handleHash,
        string handle,
        address indexed user,
        uint64 targetBlock,
        bytes32 xPostIdHash,
        bytes32 xAccountIdHash
    );
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event Claimed(bytes32 indexed agentId, string handle, address indexed user, uint256 amount);
    event ClaimExpiredFallback(bytes32 indexed handleHash, address indexed user);
    event Funded(address indexed from, uint256 amount);
    event LeftoverWithdrawn(address indexed to, uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error ZeroAddress();
    error BadDecimals();
    error IsPaused();
    error NoAgentId();
    error HandleAlreadyClaimed();
    error AddressAlreadyClaimed();
    error ClaimPending();
    error NoPendingClaim();
    error TooEarly();
    error PoolInsufficient();
    error AmountTooHigh();
    error ZeroAmount();
    error SignerNotSet();
    error VoucherExpired();
    error InvalidSignature();
    error PostAlreadyUsed();
    error AccountAlreadyUsed();

    constructor(address agentId_, address token_, address owner_) Ownable2Step(owner_) {
        if (agentId_ == address(0) || token_ == address(0)) revert ZeroAddress();
        agentId = IAgentID(agentId_);
        token = IERC20(token_);

        (bool ok, bytes memory ret) = token_.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32) revert BadDecimals();
        uint256 dec = abi.decode(ret, (uint256));
        if (dec < 2 || dec > 36) revert BadDecimals();
        tokenDecimals = uint8(dec);

        uint256 cent = 10 ** (dec - 2);
        tier0 = 5 * cent;
        tier1 = 8 * cent;
        tier2 = 12 * cent;
        tier3 = 15 * cent;
        tier4 = 20 * cent;

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    // ------------------------------------------------------------------ user

    /// @notice Step 1: verify the X-quote voucher, reserve the max tier and lock
    ///         in a future block.
    /// @param xPostIdHash    keccak256(bytes(postIdString)), e.g. keccak256("1858...").
    /// @param xAccountIdHash keccak256(bytes(numericXUserIdString)), e.g. keccak256("4412...").
    /// @param deadline       Unix seconds; the voucher is invalid after it.
    /// @param signature      65-byte EIP-712 signature (r, s, v) by `signer`.
    function commitClaim(
        bytes32 xPostIdHash,
        bytes32 xAccountIdHash,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        if (paused) revert IsPaused();
        address signer_ = signer;
        if (signer_ == address(0)) revert SignerNotSet();
        if (block.timestamp > deadline) revert VoucherExpired();
        (bytes32 h, string memory handle) = _requireAgentId(msg.sender);
        if (addressClaimed[msg.sender]) revert AddressAlreadyClaimed();
        if (handleClaimed[h]) revert HandleAlreadyClaimed();
        if (_pending[msg.sender].targetBlock != 0 || handlePendingBy[h] != address(0)) {
            revert ClaimPending();
        }
        if (usedPost[xPostIdHash]) revert PostAlreadyUsed();
        if (usedAccount[xAccountIdHash]) revert AccountAlreadyUsed();

        // handleHash and user are bound to the caller: a voucher for anyone
        // else produces a different digest and fails recovery.
        bytes32 digest = voucherDigest(h, msg.sender, xPostIdHash, xAccountIdHash, deadline);
        if (_recover(digest, signature) != signer_) revert InvalidSignature();

        if (availablePool() < tier4) revert PoolInsufficient();

        uint64 target = uint64(block.number) + SETTLE_DELAY;
        usedPost[xPostIdHash] = true;
        usedAccount[xAccountIdHash] = true;
        totalReserved += tier4;
        handlePendingBy[h] = msg.sender;
        _pending[msg.sender] = Pending({targetBlock: target, handleHash: h, handle: handle});

        emit ClaimCommitted(h, handle, msg.sender, target, xPostIdHash, xAccountIdHash);
    }

    /// @notice Step 2: settle once `targetBlock` is mined. Pays msg.sender.
    function settleClaim() external nonReentrant returns (uint256 amount) {
        Pending memory p = _pending[msg.sender];
        if (p.targetBlock == 0) revert NoPendingClaim();
        if (block.number <= p.targetBlock) revert TooEarly();

        bytes32 bh = blockhash(p.targetBlock);
        if (bh == bytes32(0)) {
            // > 256 blocks old: deterministic lowest tier (see NatSpec).
            amount = tier0;
            emit ClaimExpiredFallback(p.handleHash, msg.sender);
        } else {
            amount = tierFor(randomSeed(bh, msg.sender, p.handleHash));
        }

        // effects
        delete _pending[msg.sender];
        delete handlePendingBy[p.handleHash];
        handleClaimed[p.handleHash] = true;
        addressClaimed[msg.sender] = true;
        rewardOfHandle[p.handleHash] = amount;
        totalReserved -= tier4;
        totalPaid += amount;
        ++claimCount;

        // interaction
        token.safeTransfer(msg.sender, amount);
        emit Claimed(p.handleHash, p.handle, msg.sender, amount);
    }

    /// @notice Optional helper: pull `amount` from msg.sender into the pool.
    ///         Plain token transfers to this contract also count as funding.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    // ----------------------------------------------------------------- owner

    /// @notice Set the voucher signer. address(0) disables new commits.
    function setSigner(address newSigner) external onlyOwner {
        emit SignerUpdated(signer, newSigner);
        signer = newSigner;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Withdraw unreserved funds only.
    function withdrawLeftover(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > availablePool()) revert AmountTooHigh();
        token.safeTransfer(to, amount);
        emit LeftoverWithdrawn(to, amount);
    }

    // ----------------------------------------------------------------- views

    /// @notice Token balance minus amounts reserved for pending claims.
    function availablePool() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        return bal > totalReserved ? bal - totalReserved : 0;
    }

    /// @notice Tier amounts (token units) and odds in percent.
    function tiers() external view returns (uint256[5] memory amounts, uint8[5] memory oddsPct) {
        amounts = [tier0, tier1, tier2, tier3, tier4];
        oddsPct = [uint8(50), 20, 20, 5, 5];
    }

    /// @notice Whether `user` can call {commitClaim} now, with a reason if not.
    function canClaim(address user) external view returns (bool ok, string memory reason) {
        if (paused) return (false, "paused");
        if (signer == address(0)) return (false, "signer not set");
        (bool has, bytes32 h,) = _agentIdOf(user);
        if (!has) return (false, "no Agent ID");
        if (_pending[user].targetBlock != 0 || handlePendingBy[h] != address(0)) {
            return (false, "claim pending, call settleClaim");
        }
        if (addressClaimed[user]) return (false, "address already claimed");
        if (handleClaimed[h]) return (false, "Agent ID already claimed");
        if (availablePool() < tier4) return (false, "reward pool empty");
        return (true, "");
    }

    /// @notice Pending commit of `user`.
    /// @return exists      A commit is pending.
    /// @return targetBlock Block whose hash decides the reward.
    /// @return handleHash  keccak256(lowercase handle).
    /// @return handle      The handle at commit time.
    /// @return ready       settleClaim() can be called now.
    /// @return expired     Past the 256-block window: settles at the lowest tier.
    function pendingClaim(address user)
        external
        view
        returns (
            bool exists,
            uint64 targetBlock,
            bytes32 handleHash,
            string memory handle,
            bool ready,
            bool expired
        )
    {
        Pending memory p = _pending[user];
        exists = p.targetBlock != 0;
        targetBlock = p.targetBlock;
        handleHash = p.handleHash;
        handle = p.handle;
        ready = exists && block.number > p.targetBlock;
        expired = exists && block.number > uint256(p.targetBlock) + BLOCKHASH_WINDOW;
    }

    /// @notice Seed used for a given block hash, user and handle hash.
    function randomSeed(bytes32 bh, address user, bytes32 handleHash)
        public
        view
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(bh, user, handleHash, address(this), block.chainid)));
    }

    /// @notice Map a seed to a tier amount: r = seed % 100.
    function tierFor(uint256 seed) public view returns (uint256) {
        uint256 r = seed % 100;
        if (r < 50) return tier0;
        if (r < 70) return tier1;
        if (r < 90) return tier2;
        if (r < 95) return tier3;
        return tier4;
    }

    /// @notice True if this X post (keccak256(bytes(postIdString))) was already used.
    function isPostUsed(bytes32 xPostIdHash) external view returns (bool) {
        return usedPost[xPostIdHash];
    }

    /// @notice True if this X account (keccak256(bytes(numericXUserIdString))) was already used.
    function isAccountUsed(bytes32 xAccountIdHash) external view returns (bool) {
        return usedAccount[xAccountIdHash];
    }

    /// @notice EIP-712 struct hash of a voucher.
    function hashVoucher(
        bytes32 handleHash,
        address user,
        bytes32 xPostIdHash,
        bytes32 xAccountIdHash,
        uint256 deadline
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(VOUCHER_TYPEHASH, handleHash, user, xPostIdHash, xAccountIdHash, deadline)
        );
    }

    /// @notice Full EIP-712 digest the signer must sign.
    function voucherDigest(
        bytes32 handleHash,
        address user,
        bytes32 xPostIdHash,
        bytes32 xAccountIdHash,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                hashVoucher(handleHash, user, xPostIdHash, xAccountIdHash, deadline)
            )
        );
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    /// @notice ERC-5267 domain description.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            hex"0f", EIP712_NAME, EIP712_VERSION, block.chainid, address(this), bytes32(0),
            new uint256[](0)
        );
    }

    /// @notice keccak256 of the lowercased handle (the per-Agent-ID claim key).
    function handleKey(string memory handle) public pure returns (bytes32) {
        return keccak256(bytes(_lower(handle)));
    }

    // -------------------------------------------------------------- internal

    function _requireAgentId(address user) internal view returns (bytes32 h, string memory handle) {
        bool has;
        (has, h, handle) = _agentIdOf(user);
        if (!has) revert NoAgentId();
    }

    function _agentIdOf(address user)
        internal
        view
        returns (bool has, bytes32 h, string memory handle)
    {
        try agentId.balanceOf(user) returns (uint256 bal) {
            if (bal == 0) return (false, bytes32(0), "");
        } catch {
            return (false, bytes32(0), "");
        }
        try agentId.handleOf(user) returns (string memory s) {
            if (bytes(s).length == 0) return (false, bytes32(0), "");
            handle = _lower(s);
        } catch {
            return (false, bytes32(0), "");
        }
        return (true, keccak256(bytes(handle)), handle);
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this))
        );
    }

    /// @dev ECDSA recover with EIP-2 low-s and v in {27, 28}. Only 65-byte signatures.
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s_;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s_ := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (uint256(s_) > _HALF_N) revert InvalidSignature();
        if (v != 27 && v != 28) revert InvalidSignature();
        address rec = ecrecover(digest, v, r, s_);
        if (rec == address(0)) revert InvalidSignature();
        return rec;
    }

    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            out[i] = (c >= 0x41 && c <= 0x5a) ? bytes1(uint8(c) + 32) : c;
        }
        return string(out);
    }
}
