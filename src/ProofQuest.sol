// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentID} from "./interfaces/IAgentID.sol";
import {IQuestVerifier} from "./interfaces/IQuestVerifier.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {Ownable2Step} from "./utils/Ownable2Step.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title ProofQuest
/// @notice A poster (Agent ID holder) locks a prize against an objectively
///         verifiable check. Qualifying Agent IDs are paid automatically to
///         `ownerOfHandle(handleOf(solver))`.
///
///         Supported quest kinds:
///         (a) Hash-preimage: commit/reveal of a secret (`keccak256(answer)`).
///             Commit is `keccak256(abi.encode(answer, solver, salt))`.
///             A 1-block delay and a "no new commits after first reveal" rule
///             prevent mempool front-running.
///         (b) Optional `IQuestVerifier` for a "proof of interaction" check.
///             Hash + verifier may be combined; verifier-only uses {attempt}.
///
/// @dev Owner permissions (the ONLY admin surface — please read):
///      - `addPrizeToken` / `removePrizeToken`: allow or disallow tokens for
///        *new* quests. Existing quests are unaffected. Native BNB
///        (`address(0)`) is always allowed and cannot be removed.
///      - `transferOwnership` / `acceptOwnership` / `renounceOwnership`.
///      The owner CANNOT mint tokens, pause the contract, change a live
///      quest, seize prizes, or withdraw user funds. There is no upgrade
///      proxy and no project token.
contract ProofQuest is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant MAX_WINNERS_CAP = 100;
    uint256 public constant MAX_TITLE_BYTES = 128;
    uint256 public constant MAX_URI_BYTES = 256;

    IAgentID public immutable agentId;

    struct Quest {
        address poster;
        address token; // address(0) = native BNB
        address verifier; // address(0) = no external verifier
        bytes32 solutionHash; // bytes32(0) = verifier-only
        uint128 prizePerWinner;
        uint128 remainingPrize;
        uint64 deadline;
        uint64 firstRevealBlock; // 0 = no successful hash-reveal yet
        uint32 maxWinners;
        uint32 winnerCount;
        string title;
        string metadataURI;
        string posterHandle;
    }

    struct Commit {
        bytes32 commitHash;
        uint64 blockNumber;
    }

    uint256 public questCount;

    mapping(uint256 => Quest) private _quests;
    mapping(uint256 => mapping(address => Commit)) public commits;
    mapping(uint256 => mapping(bytes32 => bool)) public wonByHandle;
    mapping(uint256 => string[]) private _winnerHandles;
    mapping(bytes32 => uint256) public winsByHandleHash;
    mapping(bytes32 => mapping(address => uint256)) public earningsByHandleHash;
    mapping(address => bool) public isPrizeToken;

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
    event PrizeTokenUpdated(address indexed token, bool allowed);

    error NotAgentIdHolder();
    error AgentIdMismatch();
    error InvalidDeadline();
    error InvalidMaxWinners();
    error InvalidPrize();
    error InvalidQuestSpec();
    error InvalidTitle();
    error InvalidMetadataURI();
    error TokenNotAllowed();
    error IncorrectValue();
    error QuestNotFound();
    error QuestExpired();
    error QuestNotExpired();
    error QuestFull();
    error AlreadyWon();
    error CommitsClosed();
    error NoCommit();
    error SameBlockReveal();
    error LateCommit();
    error BadCommit();
    error WrongSolution();
    error VerifierRejected();
    error NothingToRefund();
    error HashQuestRequired();
    error VerifierQuestRequired();
    error NativeTokenLocked();
    error ZeroAddress();

    constructor(address agentId_, address initialOwner, address[] memory initialTokens)
        Ownable2Step(initialOwner)
    {
        if (agentId_ == address(0)) revert ZeroAddress();
        agentId = IAgentID(agentId_);
        isPrizeToken[address(0)] = true;
        emit PrizeTokenUpdated(address(0), true);
        for (uint256 i; i < initialTokens.length; ++i) {
            address token = initialTokens[i];
            if (token == address(0)) revert NativeTokenLocked();
            if (!isPrizeToken[token]) {
                isPrizeToken[token] = true;
                emit PrizeTokenUpdated(token, true);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Owner: prize-token whitelist only
    // -------------------------------------------------------------------------

    /// @notice Allow `token` as a prize asset for *new* quests.
    function addPrizeToken(address token) external onlyOwner {
        if (token == address(0)) revert NativeTokenLocked();
        isPrizeToken[token] = true;
        emit PrizeTokenUpdated(token, true);
    }

    /// @notice Disallow `token` for *new* quests. Live quests are unaffected.
    function removePrizeToken(address token) external onlyOwner {
        if (token == address(0)) revert NativeTokenLocked();
        isPrizeToken[token] = false;
        emit PrizeTokenUpdated(token, false);
    }

    // -------------------------------------------------------------------------
    // Quest lifecycle
    // -------------------------------------------------------------------------

    /// @notice Lock a prize and open a quest. Native BNB is `token = address(0)`
    ///         and must be sent as `msg.value == prizePerWinner * maxWinners`.
    ///         For ERC-20, approve this contract for the total first; `msg.value`
    ///         must be 0.
    /// @param solutionHash keccak256(answer bytes); zero for verifier-only quests.
    /// @param verifier     IQuestVerifier, or address(0) for hash-only quests.
    function createQuest(
        address token,
        uint128 prizePerWinner,
        uint32 maxWinners,
        uint64 deadline,
        bytes32 solutionHash,
        address verifier,
        string calldata title,
        string calldata metadataURI
    ) external payable nonReentrant returns (uint256 questId) {
        string memory posterHandle = _requireAgentId(msg.sender);
        if (deadline <= block.timestamp) revert InvalidDeadline();
        if (maxWinners == 0 || maxWinners > MAX_WINNERS_CAP) revert InvalidMaxWinners();
        if (prizePerWinner == 0) revert InvalidPrize();
        if (solutionHash == bytes32(0) && verifier == address(0)) revert InvalidQuestSpec();
        if (bytes(title).length == 0 || bytes(title).length > MAX_TITLE_BYTES) {
            revert InvalidTitle();
        }
        if (bytes(metadataURI).length > MAX_URI_BYTES) revert InvalidMetadataURI();
        if (!isPrizeToken[token]) revert TokenNotAllowed();

        uint256 total = uint256(prizePerWinner) * uint256(maxWinners);
        _pull(token, msg.sender, total);

        questId = ++questCount;
        Quest storage q = _quests[questId];
        q.poster = msg.sender;
        q.token = token;
        q.verifier = verifier;
        q.solutionHash = solutionHash;
        q.prizePerWinner = prizePerWinner;
        q.remainingPrize = uint128(total);
        q.deadline = deadline;
        q.maxWinners = maxWinners;
        q.title = title;
        q.metadataURI = metadataURI;
        q.posterHandle = posterHandle;

        emit QuestCreated(
            questId,
            msg.sender,
            posterHandle,
            token,
            prizePerWinner,
            maxWinners,
            deadline,
            solutionHash,
            verifier,
            title,
            metadataURI
        );
    }

    /// @notice Commit a hash-preimage solution. May be overwritten until the
    ///         first successful reveal, after which new commits are rejected.
    /// @param commitHash keccak256(abi.encode(answer, msg.sender, salt))
    function commit(uint256 questId, bytes32 commitHash) external nonReentrant {
        string memory handle = _requireAgentId(msg.sender);
        Quest storage q = _liveQuest(questId);
        if (q.solutionHash == bytes32(0)) revert HashQuestRequired();
        if (q.firstRevealBlock != 0) revert CommitsClosed();
        if (commitHash == bytes32(0)) revert BadCommit();

        bytes32 hHash = keccak256(bytes(handle));
        if (wonByHandle[questId][hHash]) revert AlreadyWon();

        commits[questId][msg.sender] =
            Commit({commitHash: commitHash, blockNumber: uint64(block.number)});
        emit Committed(questId, msg.sender, handle, commitHash);
    }

    /// @notice Reveal a previously committed answer. Pays `prizePerWinner` to
    ///         `ownerOfHandle(handleOf(msg.sender))` if the answer is correct.
    ///         If a verifier is also set, `verifierProof` must pass it.
    function reveal(
        uint256 questId,
        bytes calldata answer,
        bytes32 salt,
        bytes calldata verifierProof
    ) external nonReentrant {
        string memory handle = _requireAgentId(msg.sender);
        Quest storage q = _liveQuest(questId);
        if (q.solutionHash == bytes32(0)) revert HashQuestRequired();

        bytes32 hHash = keccak256(bytes(handle));
        if (wonByHandle[questId][hHash]) revert AlreadyWon();

        Commit memory c = commits[questId][msg.sender];
        if (c.commitHash == bytes32(0)) revert NoCommit();
        if (c.blockNumber >= block.number) revert SameBlockReveal();
        if (q.firstRevealBlock != 0 && c.blockNumber >= q.firstRevealBlock) revert LateCommit();
        if (keccak256(abi.encode(answer, msg.sender, salt)) != c.commitHash) revert BadCommit();
        if (keccak256(answer) != q.solutionHash) revert WrongSolution();

        if (q.verifier != address(0)) {
            if (!IQuestVerifier(q.verifier).verify(questId, msg.sender, verifierProof)) {
                revert VerifierRejected();
            }
        }

        if (q.firstRevealBlock == 0) {
            q.firstRevealBlock = uint64(block.number);
        }
        _award(questId, q, handle, hHash);
    }

    /// @notice Attempt a verifier-only quest (no solution hash). Not used for
    ///         hash-preimage quests — use {commit} / {reveal} instead.
    function attempt(uint256 questId, bytes calldata proof) external nonReentrant {
        string memory handle = _requireAgentId(msg.sender);
        Quest storage q = _liveQuest(questId);
        if (q.solutionHash != bytes32(0)) revert VerifierQuestRequired();
        if (q.verifier == address(0)) revert InvalidQuestSpec();

        bytes32 hHash = keccak256(bytes(handle));
        if (wonByHandle[questId][hHash]) revert AlreadyWon();

        if (!IQuestVerifier(q.verifier).verify(questId, msg.sender, proof)) {
            revert VerifierRejected();
        }
        _award(questId, q, handle, hHash);
    }

    /// @notice After the deadline, send any unclaimed prize back to the poster.
    ///         Anyone may trigger it; funds always go to the original poster.
    function refund(uint256 questId) external nonReentrant {
        Quest storage q = _existing(questId);
        if (block.timestamp < q.deadline) revert QuestNotExpired();
        uint256 amount = q.remainingPrize;
        if (amount == 0) revert NothingToRefund();
        q.remainingPrize = 0;
        emit Refunded(questId, q.poster, q.token, amount);
        _pay(q.token, q.poster, amount);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getQuest(uint256 questId) external view returns (Quest memory) {
        if (questId == 0 || questId > questCount) revert QuestNotFound();
        return _quests[questId];
    }

    function questWinners(uint256 questId) external view returns (string[] memory) {
        if (questId == 0 || questId > questCount) revert QuestNotFound();
        return _winnerHandles[questId];
    }

    /// @notice Leaderboard entry keyed by handle (lowercase, no `.ai`).
    function winsOf(string calldata handle) external view returns (uint256) {
        return winsByHandleHash[keccak256(bytes(handle))];
    }

    /// @notice Cumulative prize won by `handle` in `token` (address(0) = BNB).
    function earningsOf(string calldata handle, address token) external view returns (uint256) {
        return earningsByHandleHash[keccak256(bytes(handle))][token];
    }

    function hasWonQuest(uint256 questId, string calldata handle) external view returns (bool) {
        return wonByHandle[questId][keccak256(bytes(handle))];
    }

    function getCommit(uint256 questId, address solver) external view returns (Commit memory) {
        return commits[questId][solver];
    }

    function hasAgentId(address account) external view returns (bool ok, string memory handle) {
        handle = agentId.handleOf(account);
        ok = agentId.balanceOf(account) > 0 && bytes(handle).length != 0
            && agentId.ownerOfHandle(handle) == account;
    }

    function computeSolutionHash(bytes calldata answer) external pure returns (bytes32) {
        return keccak256(answer);
    }

    function computeCommitHash(bytes calldata answer, address solver, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(answer, solver, salt));
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _requireAgentId(address account) internal view returns (string memory handle) {
        if (agentId.balanceOf(account) == 0) revert NotAgentIdHolder();
        handle = agentId.handleOf(account);
        if (bytes(handle).length == 0) revert NotAgentIdHolder();
        if (agentId.ownerOfHandle(handle) != account) revert AgentIdMismatch();
    }

    function _existing(uint256 questId) internal view returns (Quest storage q) {
        if (questId == 0 || questId > questCount) revert QuestNotFound();
        q = _quests[questId];
    }

    function _liveQuest(uint256 questId) internal view returns (Quest storage q) {
        q = _existing(questId);
        if (block.timestamp >= q.deadline) revert QuestExpired();
        if (q.winnerCount >= q.maxWinners) revert QuestFull();
    }

    /// @dev Checks-effects-interactions: all state is written before payment.
    function _award(uint256 questId, Quest storage q, string memory handle, bytes32 hHash)
        internal
    {
        wonByHandle[questId][hHash] = true;
        q.winnerCount += 1;
        uint128 amount = q.prizePerWinner;
        q.remainingPrize -= amount;
        _winnerHandles[questId].push(handle);
        winsByHandleHash[hHash] += 1;
        earningsByHandleHash[hHash][q.token] += amount;
        delete commits[questId][msg.sender];

        emit Won(questId, msg.sender, handle, q.token, amount, q.winnerCount);

        address payTo = agentId.ownerOfHandle(handle);
        if (payTo == address(0)) revert AgentIdMismatch();
        _pay(q.token, payTo, amount);
    }

    function _pull(address token, address from, uint256 amount) internal {
        if (token == address(0)) {
            if (msg.value != amount) revert IncorrectValue();
        } else {
            if (msg.value != 0) revert IncorrectValue();
            IERC20(token).safeTransferFrom(from, address(this), amount);
        }
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    receive() external payable {
        revert IncorrectValue();
    }
}
