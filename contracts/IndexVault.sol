// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./interfaces/IHederaTokenService.sol";
import "./libraries/HederaResponseCodes.sol";
import "./MultiSigTimelock.sol";

/// @title IndexVault
/// @notice A single, isolated index vault: accepts stablecoin deposits, mints an HTS
///         index token against a tracked NAV, and burns tokens on redemption, applying
///         an immutable fee split. Implements Blueprint Sections 3, 4, and 8.1 Gate 1.
///
/// @dev ⚠️ THIS IS A PHASE 1 DRAFT FOR DEVELOPER REVIEW, NOT AN AUDITED CONTRACT.
///      Do not deploy with real funds before:
///        1. An independent security audit (Blueprint Section 4.5 / 8.1 Gate 2)
///        2. A qualified Solidity/Hedera developer has reviewed HTS call patterns,
///           decimal/precision handling, and reentrancy protections below
///        3. Testnet validation of every Section 4 security property, including a
///           simulated Bonzo-style oracle attack (Blueprint Section 7, success criteria)
contract IndexVault {
    // ============ Immutable core logic (Blueprint Section 4.4 — cannot change, ever) ============

    address public immutable factory;
    address public immutable stablecoin;        // HTS stablecoin used for deposits (e.g., USDC/HCHF on Hedera)
    address public indexToken;                  // HTS token representing vault shares; set once at init

    uint16 public constant REDEMPTION_FEE_BPS = 1200; // 12.00% immutable, in basis points (10000 = 100%)

    // --- Minting fee: protocol-wide safe bounds are hard-coded and can never be exceeded.
    // Each vault chooses its own rate within these bounds, once, at deployment — immutable
    // thereafter for that specific vault. This mirrors the same "bounded flexibility"
    // philosophy already used for the oracle pointer (Section 4.1 of the Blueprint).
    uint16 public constant MIN_MINT_FEE_BPS = 20;   // 0.20% floor, protocol-wide, hard-coded
    uint16 public constant MAX_MINT_FEE_BPS = 200;  // 2.00% ceiling, protocol-wide, hard-coded
    uint16 public immutable mintFeeBps;              // this vault's chosen rate, fixed forever once set

    address public immutable founderWallet;
    address public immutable developerWallet;
    address public immutable reserveWallet;

    // Fee split of the 12% redemption fee — must sum to 10000 (100%)
    uint16 public immutable founderShareBps;
    uint16 public immutable developerShareBps;
    uint16 public immutable reserveShareBps;

    // ============ Mutable-only-via-multisig-timelock component (Blueprint Section 4.4 / 4.1) ============

    address public oracle;                       // authorized off-chain NAV updater
    MultiSigTimelock public immutable admin;      // the only entity allowed to call setOracle()

    // ============ NAV / security state ============

    uint256 public navPrice;                      // basket value per 1 index token, 1e8 fixed-point
    uint256 public lastNavUpdateTimestamp;
    uint256 public constant MAX_DEVIATION_BPS = 500;        // 5% max single-update price move (Section 4.1)
    uint256 public constant NAV_STALENESS_THRESHOLD = 1 hours; // Section 4.2 — stale NAV triggers pause
    uint256 public constant PRICE_PRECISION = 1e8;

    bool public paused;

    // ============ Simple reentrancy guard ============
    // ⚠️ REVIEW: consider swapping for a battle-tested implementation (e.g., OpenZeppelin
    // ReentrancyGuard) once the project's dependency setup is finalized by the developer.
    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "Vault: reentrant call");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        require(!paused, "Vault: paused");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "Vault: not oracle");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == address(admin), "Vault: not admin multisig");
        _;
    }

    event Deposited(address indexed user, uint64 stablecoinAmount, uint64 indexTokensMinted, uint256 navUsed);
    event Redeemed(address indexed user, uint64 indexTokensBurned, uint64 grossPayout, uint64 fee, uint64 netPayout);
    event NavUpdated(uint256 oldNav, uint256 newNav, uint256 timestamp);
    event CircuitBreakerTripped(string reason);
    event Paused(address indexed by, string reason);
    event Unpaused(address indexed by);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    /// @notice Grouped constructor params to avoid "stack too deep" and to keep the
    ///         deployment call in IndexFactory readable. See IndexFactory.deployVault().
    struct VaultConfig {
        address factory;
        address stablecoin;
        address initialOracle;
        address founderWallet;
        address developerWallet;
        address reserveWallet;
        uint16 founderShareBps;
        uint16 developerShareBps;
        uint16 reserveShareBps;
        uint16 mintFeeBps;       // this vault's chosen minting fee, must fall within the hard-coded protocol bounds
        address[] signers;      // multisig signer set for this vault's admin (Section 4.3)
        uint256 threshold;      // approvals required for sensitive actions (e.g., 2-of-3)
        string tokenName;
        string tokenSymbol;
    }

    constructor(VaultConfig memory cfg) payable {
        require(
            uint256(cfg.founderShareBps) + cfg.developerShareBps + cfg.reserveShareBps == 10000,
            "Vault: fee shares must sum to 100%"
        );
        require(
            cfg.mintFeeBps >= MIN_MINT_FEE_BPS && cfg.mintFeeBps <= MAX_MINT_FEE_BPS,
            "Vault: mint fee outside protocol-allowed range"
        );

        mintFeeBps = cfg.mintFeeBps;

        factory = cfg.factory;
        stablecoin = cfg.stablecoin;
        oracle = cfg.initialOracle;
        founderWallet = cfg.founderWallet;
        developerWallet = cfg.developerWallet;
        reserveWallet = cfg.reserveWallet;
        founderShareBps = cfg.founderShareBps;
        developerShareBps = cfg.developerShareBps;
        reserveShareBps = cfg.reserveShareBps;

        admin = new MultiSigTimelock(cfg.signers, cfg.threshold);

        // NAV starts at 1:1 with the deposit stablecoin until the oracle pushes a real value.
        navPrice = PRICE_PRECISION;
        lastNavUpdateTimestamp = block.timestamp;

        _createIndexToken(cfg.tokenName, cfg.tokenSymbol);
    }

    // ============ Token creation (HTS precompile, Blueprint Section 3) ============

    function _createIndexToken(string memory name, string memory symbol) internal {
        // ⚠️ REVIEW: HederaToken struct requires a full key configuration (supply key,
        // admin key, etc.) — the empty TokenKey[] below is a placeholder. A real deployment
        // needs an explicit supply key (likely this contract itself) so mint/burn succeed,
        // and a decision on whether an admin key exists at all (an admin key on the token
        // itself could undermine the "immutable core logic" property — recommend NONE,
        // relying instead on this contract's own immutable mint/burn logic).
        IHederaTokenService.HederaToken memory token;
        token.name = name;
        token.symbol = symbol;
        token.treasury = address(this);
        token.tokenSupplyType = false; // INFINITE — supply is governed by this contract's logic, not a cap
        token.expiry = IHederaTokenService.Expiry({
            second: 0,
            autoRenewAccount: address(this),
            autoRenewPeriod: 7776000 // ~90 days, HTS requires an auto-renew period
        });

        (int64 responseCode, address tokenAddress) = IHederaTokenService(address(0x167))
            .createFungibleToken{value: msg.value}(token, 0, 8);

        require(responseCode == HederaResponseCodes.SUCCESS, "Vault: token creation failed");
        indexToken = tokenAddress;
    }

    // ============ Deposit / Mint (Blueprint Section 3 — immutable logic) ============

    /// @param stablecoinAmount Amount of stablecoin the user is depositing.
    /// @dev ⚠️ REVIEW: assumes the user has already associated with `stablecoin` and
    ///      `indexToken`, and that the necessary HTS allowance/approval step (Hedera's
    ///      equivalent of ERC-20 approve) has been completed before calling deposit().
    ///      Exact allowance mechanics should be confirmed against the target Hedera SDK
    ///      version and wired into the frontend flow.
    function deposit(uint64 stablecoinAmount) external nonReentrant whenNotPaused {
        require(stablecoinAmount > 0, "Vault: zero deposit");
        _checkNavFreshness();

        int64 pullResult = IHederaTokenService(address(0x167)).transferToken(
            stablecoin, msg.sender, address(this), int64(stablecoinAmount)
        );
        require(pullResult == HederaResponseCodes.SUCCESS, "Vault: stablecoin transfer failed");

        // Minting fee applied on entry, before conversion to index tokens.
        uint256 mintFee = (uint256(stablecoinAmount) * mintFeeBps) / 10000;
        uint256 netDepositValue = uint256(stablecoinAmount) - mintFee;

        // mintAmount = netDepositValue * PRICE_PRECISION / navPrice
        uint256 mintAmount = (netDepositValue * PRICE_PRECISION) / navPrice;
        require(mintAmount > 0 && mintAmount <= uint256(uint64(type(int64).max)), "Vault: invalid mint amount");

        bytes[] memory emptyMetadata = new bytes[](0);
        (int64 mintCode, , ) = IHederaTokenService(address(0x167)).mintToken(
            indexToken, int64(uint64(mintAmount)), emptyMetadata
        );
        require(mintCode == HederaResponseCodes.SUCCESS, "Vault: mint failed");

        int64 sendResult = IHederaTokenService(address(0x167)).transferToken(
            indexToken, address(this), msg.sender, int64(uint64(mintAmount))
        );
        require(sendResult == HederaResponseCodes.SUCCESS, "Vault: index token transfer failed");

        if (mintFee > 0) {
            _distributeFee(mintFee);
        }

        emit Deposited(msg.sender, stablecoinAmount, uint64(mintAmount), navPrice);
    }

    // ============ Redeem / Burn + immutable fee split (Blueprint Section 3, 5) ============

    function redeem(uint64 indexTokenAmount) external nonReentrant whenNotPaused {
        require(indexTokenAmount > 0, "Vault: zero redemption");
        _checkNavFreshness();

        int64 pullResult = IHederaTokenService(address(0x167)).transferToken(
            indexToken, msg.sender, address(this), int64(indexTokenAmount)
        );
        require(pullResult == HederaResponseCodes.SUCCESS, "Vault: index token transfer failed");

        int64[] memory emptySerials = new int64[](0);
        (int64 burnCode, ) = IHederaTokenService(address(0x167)).burnToken(
            indexToken, int64(indexTokenAmount), emptySerials
        );
        require(burnCode == HederaResponseCodes.SUCCESS, "Vault: burn failed");

        uint256 grossPayout = (uint256(indexTokenAmount) * navPrice) / PRICE_PRECISION;
        uint256 fee = (grossPayout * REDEMPTION_FEE_BPS) / 10000;
        uint256 netPayout = grossPayout - fee;

        require(netPayout <= uint256(uint64(type(int64).max)), "Vault: payout overflow");

        _sendStablecoin(msg.sender, netPayout);
        _distributeFee(fee);

        emit Redeemed(
            msg.sender, indexTokenAmount, uint64(grossPayout), uint64(fee), uint64(netPayout)
        );
    }

    function _sendStablecoin(address to, uint256 amount) internal {
        if (amount == 0) return;
        int64 result = IHederaTokenService(address(0x167)).transferToken(
            stablecoin, address(this), to, int64(uint64(amount))
        );
        require(result == HederaResponseCodes.SUCCESS, "Vault: payout transfer failed");
    }

    function _distributeFee(uint256 fee) internal {
        if (fee == 0) return;
        uint256 founderCut = (fee * founderShareBps) / 10000;
        uint256 developerCut = (fee * developerShareBps) / 10000;
        uint256 reserveCut = fee - founderCut - developerCut; // remainder avoids rounding dust loss

        _sendStablecoin(founderWallet, founderCut);
        _sendStablecoin(developerWallet, developerCut);
        _sendStablecoin(reserveWallet, reserveCut);
    }

    // ============ NAV updates + circuit breakers (Blueprint Section 4.1, 4.2) ============

    /// @notice Called by the authorized off-chain oracle process to push a new NAV.
    ///         Enforces the deviation limit that is the core Bonzo-exploit defense.
    function updateNav(uint256 newNav) external onlyOracle {
        require(newNav > 0, "Vault: invalid NAV");

        uint256 diff = newNav > navPrice ? newNav - navPrice : navPrice - newNav;
        uint256 deviationBps = (diff * 10000) / navPrice;

        if (deviationBps > MAX_DEVIATION_BPS) {
            // Bonzo-style anomaly: reject the update AND halt the vault rather than silently
            // ignoring it — a rejected-but-unpaused vault could still be probed repeatedly.
            paused = true;
            emit CircuitBreakerTripped("NAV deviation exceeds threshold");
            emit Paused(msg.sender, "NAV deviation exceeds threshold");
            return;
        }

        uint256 oldNav = navPrice;
        navPrice = newNav;
        lastNavUpdateTimestamp = block.timestamp;
        emit NavUpdated(oldNav, newNav, block.timestamp);
    }

    function _checkNavFreshness() internal {
        if (block.timestamp - lastNavUpdateTimestamp > NAV_STALENESS_THRESHOLD) {
            paused = true;
            emit CircuitBreakerTripped("NAV stale");
            emit Paused(address(this), "NAV stale");
            revert("Vault: NAV stale, vault paused");
        }
    }

    /// @notice View helper for off-chain monitoring / the pilot-stage dashboard (Section 8.1 Gate 3).
    function solvencyCheck(uint256 totalIndexTokenSupply, uint256 stablecoinBalance)
        external
        view
        returns (bool solvent, uint256 requiredBalance)
    {
        requiredBalance = (totalIndexTokenSupply * navPrice) / PRICE_PRECISION;
        solvent = stablecoinBalance >= requiredBalance;
    }

    // ============ Admin actions — all gated by the multisig+timelock, never a single key ============

    /// @notice Change the authorized oracle address. Callable ONLY by this vault's own
    ///         MultiSigTimelock, after approval threshold + 24h delay (Blueprint Section 4.1).
    function setOracle(address newOracle) external onlyAdmin {
        require(newOracle != address(0), "Vault: zero oracle");
        address old = oracle;
        oracle = newOracle;
        emit OracleUpdated(old, newOracle);
    }

    /// @notice Emergency pause — intentionally fast and low-friction (Blueprint Section 4.3),
    ///         but restricted to the multisig so it can't be abused by a single compromised key.
    function emergencyPause(string calldata reason) external onlyAdmin {
        paused = true;
        emit Paused(msg.sender, reason);
    }

    /// @notice Unpausing is a deliberate, reviewed action — never automatic — since resuming
    ///         after a real incident should follow a human root-cause check (Blueprint Section 4.5).
    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }
}
