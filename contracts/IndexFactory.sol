// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./IndexVault.sol";

/// @title IndexFactory
/// @notice Deploys new, fully isolated IndexVault instances in a single transaction.
///         Implements Blueprint Section 3 ("submarine principle") and Section 8.1 Gate 1.
///
/// @dev ⚠️ PHASE 1 DRAFT FOR DEVELOPER REVIEW. Access control here (`onlyOwner`) is a
///      simple single-address owner for Phase 1 speed — this is the same "solo founder,
///      single key" tradeoff flagged in Blueprint Section 9/10 as a stopgap, not a
///      long-term answer. Before any real funds are involved, consider gating
///      `deployVault` behind a multisig here too, consistent with every vault's own
///      internal admin structure.
contract IndexFactory {
    address public owner;
    address[] public deployedVaults;

    event VaultDeployed(
        address indexed vaultAddress,
        string tokenName,
        string tokenSymbol,
        address indexed stablecoin,
        address indexed oracle
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Factory: not owner");
        _;
    }

    constructor(address _owner) {
        require(_owner != address(0), "Factory: zero owner");
        owner = _owner;
    }

    /// @notice Deploys a new isolated IndexVault. Each vault gets its own MultiSigTimelock
    ///         admin, its own token, and its own funds — a failure in one cannot touch another.
    /// @dev msg.value is forwarded to cover the HTS token-creation fee inside the vault's
    ///      constructor. ⚠️ REVIEW: confirm the correct HBAR amount required by the target
    ///      network before calling this in a real deployment script.
    /// @notice Grouped params for deployVault — avoids "stack too deep" at the call site
    ///         when constructing the VaultConfig struct passed to IndexVault.
    struct DeployParams {
        address stablecoin;
        address initialOracle;
        address founderWallet;
        address developerWallet;
        address reserveWallet;
        uint16 founderShareBps;
        uint16 developerShareBps;
        uint16 reserveShareBps;
        uint16 mintFeeBps;       // must fall within IndexVault's hard-coded 0.20%-2.00% bounds
        address[] multisigSigners;
        uint256 multisigThreshold;
        string tokenName;
        string tokenSymbol;
    }

    function deployVault(DeployParams calldata p) external payable onlyOwner returns (address vaultAddress) {
        IndexVault.VaultConfig memory cfg = IndexVault.VaultConfig({
            factory: address(this),
            stablecoin: p.stablecoin,
            initialOracle: p.initialOracle,
            founderWallet: p.founderWallet,
            developerWallet: p.developerWallet,
            reserveWallet: p.reserveWallet,
            founderShareBps: p.founderShareBps,
            developerShareBps: p.developerShareBps,
            reserveShareBps: p.reserveShareBps,
            mintFeeBps: p.mintFeeBps,
            signers: p.multisigSigners,
            threshold: p.multisigThreshold,
            tokenName: p.tokenName,
            tokenSymbol: p.tokenSymbol
        });

        IndexVault vault = new IndexVault{value: msg.value}(cfg);

        vaultAddress = address(vault);
        deployedVaults.push(vaultAddress);

        emit VaultDeployed(vaultAddress, p.tokenName, p.tokenSymbol, p.stablecoin, p.initialOracle);
    }

    function vaultCount() external view returns (uint256) {
        return deployedVaults.length;
    }

    function allVaults() external view returns (address[] memory) {
        return deployedVaults;
    }
}
