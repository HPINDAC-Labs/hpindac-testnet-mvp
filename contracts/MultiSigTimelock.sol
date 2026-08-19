// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title MultiSigTimelock
/// @notice A minimal N-of-M multisig with a mandatory time delay before execution.
///         Implements Blueprint Section 4.1 / 4.3: no single key controls sensitive
///         vault actions (e.g., changing the oracle price-feed pointer), and every
///         approved change must wait out a delay before it takes effect.
/// @dev ⚠️ PROFESSIONAL REVIEW REQUIRED before any mainnet use. This is a Phase 1
///      reference implementation, not an audited multisig library. Consider battle-tested
///      alternatives (e.g., Gnosis Safe equivalents) once real funds are involved —
///      this contract exists so Phase 1 testnet work does not have to wait on that decision.
contract MultiSigTimelock {
    // --- Config (immutable after deployment; signer set changes would need a redeploy) ---
    address[] public signers;
    mapping(address => bool) public isSigner;
    uint256 public immutable threshold;          // number of approvals required
    uint256 public constant TIMELOCK_DELAY = 24 hours;

    // --- Proposal state ---
    struct Proposal {
        address target;
        bytes data;
        uint256 approvalCount;
        uint256 eta;          // 0 until threshold is reached; then execution earliest-time
        bool executed;
    }

    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => mapping(address => bool)) private approvedBy;
    uint256 public proposalCount;

    event ProposalCreated(uint256 indexed id, address indexed proposer, address target);
    event ProposalApproved(uint256 indexed id, address indexed signer, uint256 approvals);
    event ProposalQueued(uint256 indexed id, uint256 eta);
    event ProposalExecuted(uint256 indexed id);

    modifier onlySigner() {
        require(isSigner[msg.sender], "MultiSig: not a signer");
        _;
    }

    constructor(address[] memory _signers, uint256 _threshold) {
        require(_signers.length >= _threshold && _threshold > 0, "MultiSig: bad threshold");
        for (uint256 i = 0; i < _signers.length; i++) {
            require(_signers[i] != address(0), "MultiSig: zero signer");
            require(!isSigner[_signers[i]], "MultiSig: duplicate signer");
            isSigner[_signers[i]] = true;
            signers.push(_signers[i]);
        }
        threshold = _threshold;
    }

    /// @notice Propose a sensitive action (e.g., IndexVault.setOracle(newOracle)).
    /// @param target The contract the action will be executed against (typically the vault).
    /// @param data The abi-encoded function call to execute once approved and timelocked.
    function propose(address target, bytes calldata data) external onlySigner returns (uint256 id) {
        id = proposalCount++;
        Proposal storage p = proposals[id];
        p.target = target;
        p.data = data;
        emit ProposalCreated(id, msg.sender, target);
        _approve(id);
    }

    /// @notice Approve an existing proposal. Once threshold is reached, the timelock begins.
    function approve(uint256 id) external onlySigner {
        require(proposals[id].target != address(0), "MultiSig: unknown proposal");
        require(!proposals[id].executed, "MultiSig: already executed");
        _approve(id);
    }

    function _approve(uint256 id) internal {
        require(!approvedBy[id][msg.sender], "MultiSig: already approved");
        approvedBy[id][msg.sender] = true;
        Proposal storage p = proposals[id];
        p.approvalCount += 1;
        emit ProposalApproved(id, msg.sender, p.approvalCount);

        if (p.approvalCount == threshold && p.eta == 0) {
            p.eta = block.timestamp + TIMELOCK_DELAY;
            emit ProposalQueued(id, p.eta);
        }
    }

    /// @notice Execute a proposal once threshold approvals are met AND the timelock has elapsed.
    ///         Callable by any signer — no single party can front-run or block execution
    ///         once it's legitimately queued.
    function execute(uint256 id) external onlySigner {
        Proposal storage p = proposals[id];
        require(p.eta != 0, "MultiSig: not queued");
        require(block.timestamp >= p.eta, "MultiSig: timelock not elapsed");
        require(!p.executed, "MultiSig: already executed");

        p.executed = true;
        (bool ok, ) = p.target.call(p.data);
        require(ok, "MultiSig: execution failed");
        emit ProposalExecuted(id);
    }

    function signerCount() external view returns (uint256) {
        return signers.length;
    }
}
