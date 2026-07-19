// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title ILexifiPolicy
/// @notice Interface that DEX operators implement to define per-pool compliance rules.
/// @dev Each pool can have a different policy contract. The Lexifi hook calls this
///      during beforeSwap/beforeAddLiquidity to determine if a user is authorized.
interface ILexifiPolicy {
    /// @notice Compliance tiers returned by checkAccess
    enum AccessLevel {
        DENIED,       // 0 - User cannot interact
        RETAIL,       // 1 - Basic KYC (e.g. Coinbase Verified Account)
        ACCREDITED,   // 2 - Enhanced verification (e.g. Country + Accredited Investor)
        INSTITUTIONAL // 3 - Full institutional verification (e.g. Business + Country)
    }

    /// @notice Check whether a user can interact with a specific pool
    /// @param poolId The Uniswap V4 pool identifier
    /// @param user The wallet address being checked
    /// @param operation The hook point: 0=swap, 1=addLiquidity, 2=removeLiquidity
    /// @param amount The transaction amount in token0 terms (for threshold-based policies)
    /// @return level The user's access level
    /// @return reason Human-readable reason if denied (empty if allowed)
    function checkAccess(
        PoolId poolId,
        address user,
        uint8 operation,
        uint256 amount
    ) external view returns (AccessLevel level, string memory reason);

    /// @notice Minimum access level required for each operation on this pool
    /// @param poolId The pool to query
    /// @param operation 0=swap, 1=addLiquidity, 2=removeLiquidity
    /// @return The minimum AccessLevel required
    function minimumLevel(
        PoolId poolId,
        uint8 operation
    ) external view returns (AccessLevel);

    /// @notice Returns the policy name for audit/display purposes
    function policyName() external view returns (string memory);

    /// @notice Returns the policy version
    function policyVersion() external view returns (uint256);
}
