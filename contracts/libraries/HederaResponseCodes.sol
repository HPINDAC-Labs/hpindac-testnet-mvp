// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title HederaResponseCodes
/// @notice Subset of Hedera's precompile response codes relevant to this project.
///         Full list: hashgraph/hedera-smart-contracts HederaResponseCodes.sol
library HederaResponseCodes {
    int64 internal constant SUCCESS = 22;
    int64 internal constant INVALID_TOKEN_ID = 167;
    int64 internal constant INSUFFICIENT_TOKEN_BALANCE = 178;
    int64 internal constant TOKEN_NOT_ASSOCIATED_TO_ACCOUNT = 184;
    int64 internal constant ACCOUNT_FROZEN_FOR_TOKEN = 185;
}
