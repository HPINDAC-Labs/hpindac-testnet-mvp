// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title IHederaTokenService
/// @notice Minimal interface to Hedera's native Token Service precompile at address 0x167.
/// @dev This mirrors the subset of the official Hedera System Contract interface
///      (see hashgraph/hedera-smart-contracts on GitHub) needed for Phase 1: creating a
///      fungible index token, minting on deposit, and burning on redemption.
///      ⚠️ PROFESSIONAL REVIEW REQUIRED: verify this matches the exact interface version
///      of the Hedera network/SDK version being targeted before deployment. Hedera
///      periodically extends this interface; using a stale or incomplete version can
///      cause silent call failures.
interface IHederaTokenService {
    struct KeyValue {
        bool inheritAccountKey;
        address contractId;
        bytes ed25519;
        bytes ECDSA_secp256k1;
        address delegatableContractId;
    }

    struct TokenKey {
        uint256 keyType;
        KeyValue key;
    }

    struct Expiry {
        int64 second;
        address autoRenewAccount;
        int64 autoRenewPeriod;
    }

    struct HederaToken {
        string name;
        string symbol;
        address treasury;
        string memo;
        bool tokenSupplyType; // true = FINITE, false = INFINITE
        int64 maxSupply;
        bool freezeDefault;
        TokenKey[] tokenKeys;
        Expiry expiry;
    }

    /// @notice Creates a new fungible HTS token. Requires HBAR sent with the call
    ///         to cover the network's token creation fee.
    function createFungibleToken(
        HederaToken memory token,
        int64 initialTotalSupply,
        int32 decimals
    ) external payable returns (int64 responseCode, address tokenAddress);

    /// @notice Mints additional supply of an existing fungible HTS token to the token's treasury.
    function mintToken(
        address token,
        int64 amount,
        bytes[] memory metadata
    ) external returns (int64 responseCode, int64 newTotalSupply, int64[] memory serialNumbers);

    /// @notice Burns fungible HTS tokens held by the token's treasury.
    function burnToken(
        address token,
        int64 amount,
        int64[] memory serialNumbers
    ) external returns (int64 responseCode, int64 newTotalSupply);

    /// @notice Associates this contract (or another account) with a token so it can hold/transfer it.
    function associateToken(address account, address token) external returns (int64 responseCode);

    /// @notice Transfers fungible HTS tokens between two accounts.
    function transferToken(
        address token,
        address sender,
        address receiver,
        int64 amount
    ) external returns (int64 responseCode);
}
