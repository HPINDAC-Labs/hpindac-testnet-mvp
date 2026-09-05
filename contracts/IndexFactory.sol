// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;
 
import "./IndexVault.sol";
import "./MultiSigTimelock.sol";
 
contract IndexFactory {
    MultiSigTimelock public immutable admin;
    address[] public deployedVaults;
 
    event VaultDeployed(
        address indexed vaultAddress,
        string tokenName,
        string tokenSymbol,
        address indexed stablecoin,
        address indexed oracle
    );
 
    modifier onlyAdmin() {
        require(msg.sender == address(admin), "Factory: not admin multisig");
        _;
    }
 
    constructor(address[] memory signers, uint256 threshold, bool startInBootstrap) {
        admin = new MultiSigTimelock(signers, threshold, startInBootstrap);
    }
 
    struct DeployParams {
        address stablecoin;
        address initialOracle;
        address founderWallet;
        address developerWallet;
        address reserveWallet;
        uint16 founderShareBps;
        uint16 developerShareBps;
        uint16 reserveShareBps;
        uint16 mintFeeBps;
        address[] multisigSigners;
        uint256 multisigThreshold;
        bool startInBootstrap;
        string tokenName;
        string tokenSymbol;
    }
 
    function deployVault(DeployParams calldata p) external payable onlyAdmin returns (address vaultAddress) {
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
            startInBootstrap: p.startInBootstrap,
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
 
