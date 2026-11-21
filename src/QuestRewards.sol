// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentID} from "./interfaces/IAgentID.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {Ownable2Step} from "./utils/Ownable2Step.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title QuestRewards
/// @notice Reward campaigns ("quests") for Agent ID holders, paid in one ERC-20
///         (USDT on BSC). Each campaign has its own budget and one of two modes:
///
///         - RANDOM: two-step claim (commit, then settle after a future block).
///           Tiers 0.05 (50%), 0.08 (20%), 0.12 (20%), 0.15 (5%), 0.20 (5%) whole
///           tokens. The max tier is reserved at commit so payouts are covered.
///         - FCFS (first come, first served): a fixed `fcfsAmount` paid in ONE
///           transaction to each of the first `maxClaims` valid claimers, until the
///           slots or the campaign budget run out.
///
///         PERMISSIONLESS: anyone (by default only Agent ID holders) can publish a
///         quest with {createQuest}, funding it in the same transaction (min budget,
///         default 1 token; no maximum). Each quest's funds are isolated and belong to its creator: only
///         the creator can withdraw the unreserved leftover (after the end, or while
///         the quest is paused/blocked). The platform owner can NOT withdraw quest
///         funds. Rewards are funded by quest creators. There is no yield, no
///         promised return, and nothing is guaranteed: when a quest's slots or budget
///         are used up, claims stop. No platform fee.
///
/// @dev Gating (both modes):
///      - Caller must hold an Agent ID (registry `balanceOf > 0`, non-empty `handleOf`).
///      - One claim per Agent ID per campaign (key = keccak256(lowercase handle)),
///        and one claim per address per campaign.
///      - The project server checks that the caller's X post quotes the campaign's
///        `targetPostId` and signs an EIP-712 `Voucher` bound to campaignId, handle
///        hash and caller. Each X post can be used once in total; each X account
///        once per campaign.
///
///      RANDOMNESS LIMITS (RANDOM mode): `blockhash(targetBlock)` is unknown when the
///      commit is sent, but the validator producing `targetBlock` could bias it. This
///      is acceptable only because rewards are tiny (max 0.20). If a commit is not
///      settled within 256 blocks after `targetBlock`, it settles at the LOWEST tier
///      (no re-roll). Mainnet upgrade path for anything of value: Chainlink VRF.
///
///      Creator permissions (only over their OWN quest):
///      - `setCampaignPaused`: pause / resume new claims on the quest.
///      - `setTargetPost`: set the X post to quote, ONLY before the quest's first claim.
///      - `withdrawCampaignLeftover`: withdraw the quest's funds NOT reserved for pending
///        RANDOM claims, only after `endTime`, or while the quest is paused or blocked,
///        or while the platform is globally paused.
///
///      Platform owner permissions (the ONLY admin surface, all disclosed):
///      - `pause` / `unpause`: stop or resume NEW claims on all quests (creators can
///        still withdraw their leftovers; pending RANDOM commits can still settle).
///      - `setQuestBlocked`: moderation, stop NEW claims on one quest (e.g. abusive or
///        brand-impersonating). Its creator can still withdraw the leftover.
///      - `setSigner`: choose the voucher signer. address(0) disables new claims. A
///        compromised signer can only let extra Agent ID holders claim once each.
///      - `setCreationConfig`: open/close quest creation, require creators to hold an
///        Agent ID or not, and set the minimum budget for new quests.
///      - `withdrawUnallocated`: withdraw tokens sent directly to the contract that
///        were never credited to any quest (never quest funds).
///      - `transferOwnership` / `acceptOwnership` / `renounceOwnership`.
///      The owner CANNOT withdraw or move any quest's funds. No upgrade proxy, no mint,
///      no fee, and reserved funds can never be withdrawn.
contract QuestRewards is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Mode {
        RANDOM,
        FCFS
    }

    uint64 public constant SETTLE_DELAY = 2;
    uint64 public constant BLOCKHASH_WINDOW = 256;
    uint32 public constant MAX_CLAIMS_LIMIT = 1_000_000;

    bytes32 public constant VOUCHER_TYPEHASH = keccak256(
        "Voucher(uint256 campaignId,bytes32 handleHash,address user,bytes32 xPostIdHash,bytes32 xAccountIdHash,uint256 deadline)"
    );
    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    string public constant EIP712_NAME = "ProofQuest QuestRewards";
    string public constant EIP712_VERSION = "1";
    bytes32 private constant _HASHED_NAME = keccak256(bytes(EIP712_NAME));
    bytes32 private constant _HASHED_VERSION = keccak256(bytes(EIP712_VERSION));
    uint256 private constant _HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    bytes32 private immutable _cachedDomainSeparator;
    uint256 private immutable _cachedChainId;

    IAgentID public immutable agentId;
    IERC20 public immutable token;
    uint8 public immutable tokenDecimals;

    uint256 public immutable tier0; // 0.05 (50%)
    uint256 public immutable tier1; // 0.08 (20%)
    uint256 public immutable tier2; // 0.12 (20%)
    uint256 public immutable tier3; // 0.15 (5%)
    uint256 public immutable tier4; // 0.20 (5%) = max, reserved on commit
    /// @notice Hard cap on a FCFS per-claim amount: 10 whole tokens. Limits damage from owner mistakes or a leaked signer.
    uint256 public immutable maxFcfsAmount;

    struct Campaign {
        Mode mode;
        bool paused;
        uint32 maxClaims;
        uint32 slotsUsed; // FCFS paid + RANDOM committed (pending or settled)
        uint32 settled; // claims paid out
        uint64 endTime; // 0 = no end
        uint256 fcfsAmount; // FCFS only, 0 for RANDOM
        uint256 balance; // credited funds minus payouts and withdrawals
        uint256 reserved; // RANDOM: tier4 per pending commit
        uint256 totalPaid;
        string targetPostId; // decimal X post ID that claimers must quote ("" = not set yet)
        string title;
    }

    struct Pending {
        uint64 targetBlock; // 0 = none
        bytes32 handleHash;
        string handle;
    }

    bool public paused;
    address public signer;
    uint256 public campaignCount;
    /// @notice Sum of all campaign balances (tokens owed to campaigns).
    uint256 public totalCampaignBalance;

    /// @notice Who published (and funded) each quest. Only they control it.
    mapping(uint256 => address) public creatorOf;
    /// @notice Owner moderation flag: blocks NEW claims on a quest (creator can still withdraw).
    mapping(uint256 => bool) public questBlocked;
    /// @notice Whether non-owner addresses can create quests.
    bool public creationOpen = true;
    /// @notice Whether a quest creator must hold an Agent ID (owner is exempt).
    bool public creatorNeedsAgentId = true;
    /// @notice Minimum initial budget for a new quest (token units). Default 5 tokens.
    uint256 public minBudget;

    mapping(uint256 => Campaign) private _campaigns;
    mapping(uint256 => mapping(address => Pending)) private _pending;
    mapping(uint256 => mapping(bytes32 => address)) public handlePendingBy;
    mapping(uint256 => mapping(bytes32 => bool)) public handleClaimed;
    mapping(uint256 => mapping(address => bool)) public addressClaimed;
    mapping(uint256 => mapping(bytes32 => uint256)) public rewardOfHandle;
    mapping(uint256 => mapping(bytes32 => bool)) public usedAccount; // per campaign
    mapping(bytes32 => bool) public usedPost; // global: one post, one claim

    event CampaignCreated(
        uint256 indexed id,
        Mode mode,
        uint256 fcfsAmount,
        uint32 maxClaims,
        uint64 endTime,
        string targetPostId,
        string title
    );
    event QuestCreated(uint256 indexed id, address indexed creator, uint256 budget);
    event QuestBlocked(uint256 indexed id, bool blocked);
    event CreationConfigUpdated(bool open, bool needsAgentId, uint256 minBudget);
    event CampaignFunded(uint256 indexed id, address indexed from, uint256 amount);
    event CampaignPaused(uint256 indexed id, bool paused);
    event TargetPostUpdated(uint256 indexed id, string targetPostId);
    event ClaimCommitted(
        uint256 indexed id,
        bytes32 indexed handleHash,
        string handle,
        address indexed user,
        uint64 targetBlock,
        bytes32 xPostIdHash,
        bytes32 xAccountIdHash
    );
    event Claimed(
        uint256 indexed id,
        bytes32 indexed handleHash,
        string handle,
        address indexed user,
        uint256 amount,
        Mode mode
    );
    event ClaimExpiredFallback(
        uint256 indexed id, bytes32 indexed handleHash, address indexed user
    );
    event LeftoverWithdrawn(uint256 indexed id, address indexed to, uint256 amount);
    event UnallocatedWithdrawn(address indexed to, uint256 amount);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error ZeroAddress();
    error BadDecimals();
    error IsPaused();
    error CampaignIsPaused();
    error UnknownCampaign();
    error CampaignEnded();
    error BadParams();
    error NoAgentId();
    error HandleAlreadyClaimed();
    error AddressAlreadyClaimed();
    error ClaimPending();
    error NoPendingClaim();
    error TooEarly();
    error NoSlotsLeft();
    error PoolInsufficient();
    error AmountTooHigh();
    error ZeroAmount();
    error SignerNotSet();
    error VoucherExpired();
    error InvalidSignature();
    error PostAlreadyUsed();
    error AccountAlreadyUsed();
    error AlreadyStarted();
    error NotCreator();
    error CreationClosed();
    error BudgetTooLow();
    error QuestIsBlocked();
    error StillActive();
    error CreatorCannotClaim();

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
        maxFcfsAmount = 1000 * cent;
        minBudget = 100 * cent; // 1 token (no maximum budget)

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    // ------------------------------------------------------------------ user

    /// @notice Claim in campaign `id`. FCFS pays `fcfsAmount` now. RANDOM records a
    ///         commit; call {settle} after `targetBlock` to receive the random tier.
    /// @return paid Amount paid now (0 for a RANDOM commit).
    function claim(
        uint256 id,
        bytes32 xPostIdHash,
        bytes32 xAccountIdHash,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256 paid) {
        Campaign storage c = _campaign(id);
        if (paused) revert IsPaused();
        if (c.paused) revert CampaignIsPaused();
        if (questBlocked[id]) revert QuestIsBlocked();
        if (c.endTime != 0 && block.timestamp > c.endTime) revert CampaignEnded();
        if (msg.sender == creatorOf[id]) revert CreatorCannotClaim();
        address signer_ = signer;
        if (signer_ == address(0)) revert SignerNotSet();
        if (block.timestamp > deadline) revert VoucherExpired();

        (bytes32 h, string memory handle) = _requireAgentId(msg.sender);
        if (addressClaimed[id][msg.sender]) revert AddressAlreadyClaimed();
        if (handleClaimed[id][h]) revert HandleAlreadyClaimed();
        if (_pending[id][msg.sender].targetBlock != 0 || handlePendingBy[id][h] != address(0)) {
            revert ClaimPending();
        }
        if (usedPost[xPostIdHash]) revert PostAlreadyUsed();
        if (usedAccount[id][xAccountIdHash]) revert AccountAlreadyUsed();
        if (c.slotsUsed >= c.maxClaims) revert NoSlotsLeft();

        bytes32 digest = voucherDigest(id, h, msg.sender, xPostIdHash, xAccountIdHash, deadline);
        if (_recover(digest, signature) != signer_) revert InvalidSignature();

        usedPost[xPostIdHash] = true;
        usedAccount[id][xAccountIdHash] = true;
        c.slotsUsed += 1;

        if (c.mode == Mode.FCFS) {
            uint256 amt = c.fcfsAmount;
            if (c.balance - c.reserved < amt) revert PoolInsufficient();
            handleClaimed[id][h] = true;
            addressClaimed[id][msg.sender] = true;
            rewardOfHandle[id][h] = amt;
            c.balance -= amt;
            c.totalPaid += amt;
            c.settled += 1;
            totalCampaignBalance -= amt;
            token.safeTransfer(msg.sender, amt);
            emit Claimed(id, h, handle, msg.sender, amt, Mode.FCFS);
            return amt;
        }

        if (c.balance - c.reserved < tier4) revert PoolInsufficient();
        uint64 target = uint64(block.number) + SETTLE_DELAY;
        c.reserved += tier4;
        handlePendingBy[id][h] = msg.sender;
        _pending[id][msg.sender] = Pending({targetBlock: target, handleHash: h, handle: handle});
        emit ClaimCommitted(id, h, handle, msg.sender, target, xPostIdHash, xAccountIdHash);
        return 0;
    }

    /// @notice RANDOM step 2: settle once `targetBlock` is mined. Pays msg.sender.
    function settle(uint256 id) external nonReentrant returns (uint256 amount) {
        Campaign storage c = _campaign(id);
        Pending memory p = _pending[id][msg.sender];
        if (p.targetBlock == 0) revert NoPendingClaim();
        if (block.number <= p.targetBlock) revert TooEarly();

        bytes32 bh = blockhash(p.targetBlock);
        if (bh == bytes32(0)) {
            amount = tier0;
            emit ClaimExpiredFallback(id, p.handleHash, msg.sender);
        } else {
            amount = tierFor(randomSeed(id, bh, msg.sender, p.handleHash));
        }

        delete _pending[id][msg.sender];
        delete handlePendingBy[id][p.handleHash];
        handleClaimed[id][p.handleHash] = true;
        addressClaimed[id][msg.sender] = true;
        rewardOfHandle[id][p.handleHash] = amount;
        c.reserved -= tier4;
        c.balance -= amount;
        c.totalPaid += amount;
        c.settled += 1;
        totalCampaignBalance -= amount;

        token.safeTransfer(msg.sender, amount);
        emit Claimed(id, p.handleHash, p.handle, msg.sender, amount, Mode.RANDOM);
    }

    /// @notice Top up quest `id` with `amount` tokens (pulled from msg.sender). Anyone may
    ///         fund; funds then belong to the quest and only its creator can withdraw leftovers.
    function fundCampaign(uint256 id, uint256 amount) external nonReentrant {
        _campaign(id);
        if (amount == 0) revert ZeroAmount();
        _pull(id, amount);
    }

    // --------------------------------------------------------------- creator

    /// @notice Publish a quest and fund it in one transaction. Pulls `budget` tokens from
    ///         msg.sender (approve exactly `budget` first). msg.sender becomes the creator.
    /// @param targetPostId decimal X post ID to quote ("" = set later, before the first claim).
    function createQuest(
        Mode mode,
        uint256 fcfsAmount,
        uint32 maxClaims,
        uint64 endTime,
        string calldata targetPostId,
        string calldata title,
        uint256 budget
    ) external nonReentrant returns (uint256 id) {
        bool isOwner = msg.sender == owner;
        if (!isOwner) {
            if (!creationOpen) revert CreationClosed();
            if (creatorNeedsAgentId) _requireAgentId(msg.sender);
        }
        if (maxClaims == 0 || maxClaims > MAX_CLAIMS_LIMIT) revert BadParams();
        if (mode == Mode.RANDOM ? fcfsAmount != 0 : fcfsAmount == 0) revert BadParams();
        if (fcfsAmount > maxFcfsAmount) revert BadParams();
        if (endTime != 0 && endTime <= block.timestamp) revert BadParams();
        if (bytes(title).length == 0 || bytes(title).length > 120) revert BadParams();
        // Empty = target post not announced yet (the voucher server refuses to sign).
        if (bytes(targetPostId).length != 0) _checkPostId(targetPostId);
        if (budget < minBudget) revert BudgetTooLow();

        id = ++campaignCount;
        Campaign storage c = _campaigns[id];
        c.mode = mode;
        c.maxClaims = maxClaims;
        c.endTime = endTime;
        c.fcfsAmount = fcfsAmount;
        c.targetPostId = targetPostId;
        c.title = title;
        creatorOf[id] = msg.sender;
        emit CampaignCreated(id, mode, fcfsAmount, maxClaims, endTime, targetPostId, title);

        uint256 received;
        if (budget != 0) received = _pull(id, budget);
        if (received < minBudget) revert BudgetTooLow(); // fee-on-transfer safety
        emit QuestCreated(id, msg.sender, received);
    }

    /// @notice Change the X post to quote. Creator only, and only before the first claim.
    function setTargetPost(uint256 id, string calldata targetPostId) external {
        Campaign storage c = _campaign(id);
        _onlyCreator(id);
        if (c.slotsUsed != 0) revert AlreadyStarted();
        _checkPostId(targetPostId);
        c.targetPostId = targetPostId;
        emit TargetPostUpdated(id, targetPostId);
    }

    /// @notice Pause / resume new claims on your own quest.
    function setCampaignPaused(uint256 id, bool p) external {
        Campaign storage c = _campaign(id);
        _onlyCreator(id);
        c.paused = p;
        emit CampaignPaused(id, p);
    }

    /// @notice Creator withdraws their quest's unreserved funds. Allowed after the end time,
    ///         or while the quest is paused or blocked, or while the platform is paused.
    function withdrawCampaignLeftover(uint256 id, uint256 amount, address to)
        external
        nonReentrant
    {
        Campaign storage c = _campaign(id);
        _onlyCreator(id);
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        bool ended = c.endTime != 0 && block.timestamp > c.endTime;
        if (!(ended || c.paused || questBlocked[id] || paused)) revert StillActive();
        if (amount > c.balance - c.reserved) revert AmountTooHigh();
        c.balance -= amount;
        totalCampaignBalance -= amount;
        token.safeTransfer(to, amount);
        emit LeftoverWithdrawn(id, to, amount);
    }

    // ----------------------------------------------------------------- owner

    /// @notice Moderation: block / unblock NEW claims on one quest. Cannot move its funds.
    function setQuestBlocked(uint256 id, bool b) external onlyOwner {
        _campaign(id);
        questBlocked[id] = b;
        emit QuestBlocked(id, b);
    }

    /// @notice Configure permissionless creation. `minBudget_` is capped at 1,000,000 tokens.
    function setCreationConfig(bool open, bool needsAgentId, uint256 minBudget_)
        external
        onlyOwner
    {
        if (minBudget_ > 1_000_000 * 10 ** uint256(tokenDecimals)) revert BadParams();
        creationOpen = open;
        creatorNeedsAgentId = needsAgentId;
        minBudget = minBudget_;
        emit CreationConfigUpdated(open, needsAgentId, minBudget_);
    }

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

    /// @notice Withdraw tokens held by the contract but not credited to any campaign.
    function withdrawUnallocated(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > unallocated()) revert AmountTooHigh();
        token.safeTransfer(to, amount);
        emit UnallocatedWithdrawn(to, amount);
    }

    // ----------------------------------------------------------------- views

    function getCampaign(uint256 id) external view returns (Campaign memory) {
        if (id == 0 || id > campaignCount) revert UnknownCampaign();
        return _campaigns[id];
    }

    /// @notice Funds of campaign `id` not reserved for pending RANDOM commits.
    function availableOf(uint256 id) public view returns (uint256) {
        Campaign storage c = _campaigns[id];
        return c.balance - c.reserved;
    }

    /// @notice How many more claims campaign `id` can accept right now
    ///         (min of free slots and what the unreserved budget covers).
    function remainingSlots(uint256 id) public view returns (uint256) {
        if (id == 0 || id > campaignCount) return 0;
        Campaign storage c = _campaigns[id];
        uint256 free = uint256(c.maxClaims) - c.slotsUsed;
        uint256 unit = c.mode == Mode.FCFS ? c.fcfsAmount : tier4;
        uint256 byBudget = (c.balance - c.reserved) / unit;
        return free < byBudget ? free : byBudget;
    }

    function unallocated() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        return bal > totalCampaignBalance ? bal - totalCampaignBalance : 0;
    }

    function tiers() external view returns (uint256[5] memory amounts, uint8[5] memory oddsPct) {
        amounts = [tier0, tier1, tier2, tier3, tier4];
        oddsPct = [uint8(50), 20, 20, 5, 5];
    }

    /// @notice Whether `user` can call {claim} on campaign `id` now, with a reason if not.
    ///         (X post / account checks happen on the voucher server and in {claim}.)
    function canClaim(uint256 id, address user)
        external
        view
        returns (bool ok, string memory reason)
    {
        if (id == 0 || id > campaignCount) return (false, "unknown campaign");
        Campaign storage c = _campaigns[id];
        if (paused) return (false, "paused");
        if (c.paused) return (false, "campaign paused");
        if (questBlocked[id]) return (false, "quest blocked");
        if (c.endTime != 0 && block.timestamp > c.endTime) return (false, "campaign ended");
        if (signer == address(0)) return (false, "signer not set");
        if (user == creatorOf[id]) return (false, "creator cannot claim own quest");
        (bool has, bytes32 h,) = _agentIdOf(user);
        if (!has) return (false, "no Agent ID");
        if (_pending[id][user].targetBlock != 0 || handlePendingBy[id][h] != address(0)) {
            return (false, "claim pending, call settle");
        }
        if (addressClaimed[id][user]) return (false, "address already claimed");
        if (handleClaimed[id][h]) return (false, "Agent ID already claimed");
        if (c.slotsUsed >= c.maxClaims) return (false, "no slots left");
        if (remainingSlots(id) == 0) return (false, "reward pool empty");
        return (true, "");
    }

    function pendingClaim(uint256 id, address user)
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
        Pending memory p = _pending[id][user];
        exists = p.targetBlock != 0;
        targetBlock = p.targetBlock;
        handleHash = p.handleHash;
        handle = p.handle;
        ready = exists && block.number > p.targetBlock;
        expired = exists && block.number > uint256(p.targetBlock) + BLOCKHASH_WINDOW;
    }

    function randomSeed(uint256 id, bytes32 bh, address user, bytes32 handleHash)
        public
        view
        returns (uint256)
    {
        return
            uint256(keccak256(abi.encode(bh, user, handleHash, id, address(this), block.chainid)));
    }

    function tierFor(uint256 seed) public view returns (uint256) {
        uint256 r = seed % 100;
        if (r < 50) return tier0;
        if (r < 70) return tier1;
        if (r < 90) return tier2;
        if (r < 95) return tier3;
        return tier4;
    }

    function isPostUsed(bytes32 xPostIdHash) external view returns (bool) {
        return usedPost[xPostIdHash];
    }

    function isAccountUsed(uint256 id, bytes32 xAccountIdHash) external view returns (bool) {
        return usedAccount[id][xAccountIdHash];
    }

    function hashVoucher(
        uint256 id,
        bytes32 handleHash,
        address user,
        bytes32 xPostIdHash,
        bytes32 xAccountIdHash,
        uint256 deadline
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                VOUCHER_TYPEHASH, id, handleHash, user, xPostIdHash, xAccountIdHash, deadline
            )
        );
    }

    function voucherDigest(
        uint256 id,
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
                hashVoucher(id, handleHash, user, xPostIdHash, xAccountIdHash, deadline)
            )
        );
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

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
            hex"0f",
            EIP712_NAME,
            EIP712_VERSION,
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }

    function handleKey(string memory handle) public pure returns (bytes32) {
        return keccak256(bytes(_lower(handle)));
    }

    // -------------------------------------------------------------- internal

    function _campaign(uint256 id) internal view returns (Campaign storage) {
        if (id == 0 || id > campaignCount) revert UnknownCampaign();
        return _campaigns[id];
    }

    function _onlyCreator(uint256 id) internal view {
        if (msg.sender != creatorOf[id]) revert NotCreator();
    }

    /// @dev Pull tokens into quest `id`; credits what actually arrived.
    function _pull(uint256 id, uint256 amount) internal returns (uint256 received) {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - before;
        _campaigns[id].balance += received;
        totalCampaignBalance += received;
        emit CampaignFunded(id, msg.sender, received);
    }

    function _checkPostId(string calldata s) internal pure {
        bytes calldata b = bytes(s);
        if (b.length == 0 || b.length > 25) revert BadParams();
        for (uint256 i; i < b.length; ++i) {
            if (b[i] < 0x30 || b[i] > 0x39) revert BadParams();
        }
    }

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
            abi.encode(
                _DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)
            )
        );
    }

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
