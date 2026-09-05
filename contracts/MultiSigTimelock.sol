// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;
 
/// @title MultiSigTimelock
/// @notice N-of-M multisig featuring an irreversible Bootstrap Mode.
/// Allows 0-delay execution during initial system setup and locks into a
/// mandatory 24-hour timelock once Bootstrap Mode is exited.
contract MultiSigTimelock {
    address[] public signers;
    mapping(address => bool) public isSigner;
    uint256 public threshold;
    uint256 public constant STANDARD_TIMELOCK_DELAY = 24 hours;
    uint256 public timelockDelay;
    bool public isBootstrapMode;
 
    struct Proposal {
        address target;
        bytes data;
        uint256 approvalCount;
        uint256 eta;
        bool executed;
    }
 
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public approvedBy;
    uint256 public proposalCount;
 
    event ProposalCreated(uint256 indexed id, address indexed proposer, address target);
    event ProposalApproved(uint256 indexed id, address indexed signer, uint256 approvals);
    event ProposalQueued(uint256 indexed id, uint256 eta);
    event ProposalExecuted(uint256 indexed id);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdUpdated(uint256 newThreshold);
    event BootstrapModeExited(uint256 permanentTimelockDelay);
 
    modifier onlySigner() {
        require(isSigner[msg.sender], "MultiSig: not a signer");
        _;
    }
 
    modifier onlySelf() {
        require(msg.sender == address(this), "MultiSig: caller must be timelock");
        _;
    }
 
    constructor(address[] memory _signers, uint256 _threshold, bool _startInBootstrap) {
        require(_signers.length >= _threshold && _threshold > 0, "MultiSig: bad threshold");
        for (uint256 i = 0; i < _signers.length; i++) {
            require(_signers[i] != address(0), "MultiSig: zero signer");
            require(!isSigner[_signers[i]], "MultiSig: duplicate signer");
            isSigner[_signers[i]] = true;
            signers.push(_signers[i]);
        }
        threshold = _threshold;
 
        if (_startInBootstrap) {
            isBootstrapMode = true;
            timelockDelay = 0;
        } else {
            isBootstrapMode = false;
            timelockDelay = STANDARD_TIMELOCK_DELAY;
        }
    }
 
    function propose(address target, bytes calldata data) external onlySigner returns (uint256 id) {
        require(target != address(0), "MultiSig: zero target");
        id = proposalCount++;
        Proposal storage p = proposals[id];
        p.target = target;
        p.data = data;
        emit ProposalCreated(id, msg.sender, target);
        _approve(id);
    }
 
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
            p.eta = block.timestamp + timelockDelay;
            emit ProposalQueued(id, p.eta);
        }
    }
 
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
 
    function exitBootstrapMode() external {
        require(isSigner[msg.sender] || msg.sender == address(this), "MultiSig: unauthorized");
        require(isBootstrapMode, "MultiSig: already exited bootstrap mode");
        isBootstrapMode = false;
        timelockDelay = STANDARD_TIMELOCK_DELAY;
        emit BootstrapModeExited(timelockDelay);
    }
 
    function addSigner(address newSigner) external onlySelf {
        require(newSigner != address(0), "MultiSig: zero address");
        require(!isSigner[newSigner], "MultiSig: already signer");
        isSigner[newSigner] = true;
        signers.push(newSigner);
        emit SignerAdded(newSigner);
    }
 
    function removeSigner(address oldSigner) external onlySelf {
        require(isSigner[oldSigner], "MultiSig: not signer");
        require(signers.length - 1 >= threshold, "MultiSig: signers below threshold");
        isSigner[oldSigner] = false;
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == oldSigner) {
                signers[i] = signers[signers.length - 1];
                signers.pop();
                break;
            }
        }
        emit SignerRemoved(oldSigner);
    }
 
    function updateThreshold(uint256 newThreshold) external onlySelf {
        require(newThreshold > 0 && signers.length >= newThreshold, "MultiSig: invalid threshold");
        threshold = newThreshold;
        emit ThresholdUpdated(newThreshold);
    }
 
    function signerCount() external view returns (uint256) {
        return signers.length;
    }
}

