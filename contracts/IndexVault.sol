// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;
 
import "./interfaces/IHederaTokenService.sol";
import "./libraries/HederaResponseCodes.sol";
import "./MultiSigTimelock.sol";
 
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}
 
contract IndexVault {
    address public immutable factory;
    address public immutable stablecoin;
    address public indexToken;
 
    uint16 public constant REDEMPTION_FEE_BPS = 1200;
    uint16 public constant MIN_MINT_FEE_BPS = 20;
    uint16 public constant MAX_MINT_FEE_BPS = 200;
    uint16 public immutable mintFeeBps;
 
    address public immutable founderWallet;
    address public immutable developerWallet;
    address public immutable reserveWallet;
 
    uint16 public immutable founderShareBps;
    uint16 public immutable developerShareBps;
    uint16 public immutable reserveShareBps;
 
    address public oracle;
    MultiSigTimelock public immutable admin;
 
    uint256 public navPrice;
    uint256 public lastNavUpdateTimestamp;
    uint256 public constant MAX_DEVIATION_BPS = 500;
    uint256 public constant NAV_STALENESS_THRESHOLD = 1 hours;
    uint256 public constant PRICE_PRECISION = 1e8;
 
    bool public paused;
 
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;
 
    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
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
        uint16 mintFeeBps;
        address[] signers;
        uint256 threshold;
        bool startInBootstrap;
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
        require(cfg.factory != address(0), "Vault: zero factory");
        require(cfg.stablecoin != address(0), "Vault: zero stablecoin");
        require(cfg.initialOracle != address(0), "Vault: zero oracle");
        require(cfg.founderWallet != address(0), "Vault: zero founder wallet");
        require(cfg.developerWallet != address(0), "Vault: zero developer wallet");
        require(cfg.reserveWallet != address(0), "Vault: zero reserve wallet");
 
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
 
        admin = new MultiSigTimelock(cfg.signers, cfg.threshold, cfg.startInBootstrap);
 
        navPrice = PRICE_PRECISION;
        lastNavUpdateTimestamp = block.timestamp;
 
        _createIndexToken(cfg.tokenName, cfg.tokenSymbol);
    }
 
    function _createIndexToken(string memory name, string memory symbol) internal {
        IHederaTokenService.HederaToken memory token;
        token.name = name;
        token.symbol = symbol;
        token.treasury = address(this);
        token.tokenSupplyType = false;
        token.expiry = IHederaTokenService.Expiry({
            second: 0,
            autoRenewAccount: address(this),
            autoRenewPeriod: 7776000
        });
 
        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](1);
        keys[0] = IHederaTokenService.TokenKey({
            keyType: 16,
            key: IHederaTokenService.KeyValue({
                inheritAccountKey: false,
                contractId: address(this),
                ed25519: "",
                ECDSA_secp256k1: "",
                delegatableContractId: address(0)
            })
        });
        token.tokenKeys = keys;
 
        (int64 responseCode, address tokenAddress) = IHederaTokenService(address(0x167))
            .createFungibleToken{value: msg.value}(token, 0, 8);
 
        require(responseCode == HederaResponseCodes.SUCCESS, "Vault: token creation failed");
        indexToken = tokenAddress;
    }
 
    function deposit(uint64 stablecoinAmount) external nonReentrant whenNotPaused {
        require(stablecoinAmount > 0, "Vault: zero deposit");
        _checkNavFreshness();
 
        int64 pullResult = IHederaTokenService(address(0x167)).transferToken(
            stablecoin, msg.sender, address(this), int64(stablecoinAmount)
        );
        require(pullResult == HederaResponseCodes.SUCCESS, "Vault: stablecoin transfer failed");
 
        uint256 mintFee = (uint256(stablecoinAmount) * mintFeeBps) / 10000;
        uint256 netDepositValue = uint256(stablecoinAmount) - mintFee;
 
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
 
        emit Redeemed(msg.sender, indexTokenAmount, uint64(grossPayout), uint64(fee), uint64(netPayout));
    }
 
    function _sendStablecoin(address to, uint256 amount) internal {
        if (amount == 0) return;
        require(amount <= uint256(uint64(type(int64).max)), "Vault: transfer overflow");
        int64 result = IHederaTokenService(address(0x167)).transferToken(
            stablecoin, address(this), to, int64(uint64(amount))
        );
        require(result == HederaResponseCodes.SUCCESS, "Vault: payout transfer failed");
    }
 
    function _distributeFee(uint256 fee) internal {
        if (fee == 0) return;
        uint256 founderCut = (fee * founderShareBps) / 10000;
        uint256 developerCut = (fee * developerShareBps) / 10000;
        uint256 reserveCut = fee - founderCut - developerCut;
 
        _sendStablecoin(founderWallet, founderCut);
        _sendStablecoin(developerWallet, developerCut);
        _sendStablecoin(reserveWallet, reserveCut);
    }
 
    function updateNav(uint256 newNav) external onlyOracle {
        require(newNav > 0, "Vault: invalid NAV");
 
        uint256 diff = newNav > navPrice ? newNav - navPrice : navPrice - newNav;
        uint256 deviationBps = (diff * 10000) / navPrice;
 
        if (deviationBps > MAX_DEVIATION_BPS) {
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
 
    function _checkNavFreshness() internal view {
        if (block.timestamp - lastNavUpdateTimestamp > NAV_STALENESS_THRESHOLD) {
            revert("Vault: NAV stale, vault paused");
        }
    }
 
    function pauseIfStale() external {
        require(!paused, "Vault: already paused");
        require(
            block.timestamp - lastNavUpdateTimestamp > NAV_STALENESS_THRESHOLD,
            "Vault: NAV not stale"
        );
        paused = true;
        emit CircuitBreakerTripped("NAV stale");
        emit Paused(msg.sender, "NAV stale");
    }
 
    function solvencyCheck() external view returns (bool solvent, uint256 requiredBalance, uint256 actualBalance) {
        uint256 totalIndexTokenSupply = IERC20Minimal(indexToken).totalSupply();
        actualBalance = IERC20Minimal(stablecoin).balanceOf(address(this));
        requiredBalance = (totalIndexTokenSupply * navPrice) / PRICE_PRECISION;
        solvent = actualBalance >= requiredBalance;
    }
 
    function setOracle(address newOracle) external onlyAdmin {
        require(newOracle != address(0), "Vault: zero oracle");
        address old = oracle;
        oracle = newOracle;
        emit OracleUpdated(old, newOracle);
    }
 
    function emergencyPause(string calldata reason) external onlyAdmin {
        paused = true;
        emit Paused(msg.sender, reason);
    }
 
    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }
}
 
