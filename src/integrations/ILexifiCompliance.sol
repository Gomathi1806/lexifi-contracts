// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILexifiCompliance
/// @notice Single-call compliance check interface for third-party hook integrations.
/// @dev This is the interface Aqua0's V4Adapter (or any external hook) calls.
///      One external call in beforeSwap — returns pass/fail + tier info.
///      The adapter behind this interface routes to the correct Lexifi policy
///      for the given pool and handles all verification logic internally.
interface ILexifiCompliance {
    /// @notice Check whether a user is compliant for a specific pool operation
    /// @param poolId The Uniswap V4 pool identifier (bytes32)
    /// @param user The wallet address being checked
    /// @param operation 0=swap, 1=addLiquidity
    /// @param amount The transaction amount
    /// @return allowed True if the user passes compliance
    /// @return userTier The user's verified access tier (0=denied, 1=retail, 2=accredited, 3=institutional)
    /// @return requiredTier The minimum tier required for this operation
    /// @return reason Human-readable denial reason (empty if allowed)
    function checkCompliance(
        bytes32 poolId,
        address user,
        uint8 operation,
        uint256 amount
    ) external view returns (
        bool allowed,
        uint8 userTier,
        uint8 requiredTier,
        string memory reason
    );

    /// @notice Check if a pool has a compliance policy registered
    /// @param poolId The pool to check
    /// @return True if the pool has an active compliance policy
    function hasPolicy(bytes32 poolId) external view returns (bool);
}
